import AppKit
import BentoCore
import SwiftUI

/// Renders one `WorkspaceGroup` leaf inside the pane grid: a self-contained
/// [sidebar | terminal | editor-if-open] unit. The sidebar shows the file
/// tree of the workspace's currently-tracked `currentCwd`; clicking a file
/// opens it in the workspace's own editor pane (created on demand).
///
/// Layout is built on two real `NSSplitView`s wrapped in an
/// `NSViewRepresentable` so the user gets native divider dragging:
///
///   ┌───────────────────────────────────────────────────────┐
///   │ sidebar │ terminal area               │  editor (opt) │
///   │         │  ┌──────────────────────┐   │               │
///   │         │  │ TerminalPaneView     │   │  EditorPane   │
///   │         │  └──────────────────────┘   │               │
///   │         │  ┌──────────────────────┐   │               │
///   │         │  │ CommandBarView slot  │   │               │
///   │         │  └──────────────────────┘   │               │
///   └───────────────────────────────────────────────────────┘
///
/// - The outer split is horizontal: `sidebar | (terminal-area | editor?)`.
/// - The inner split is also horizontal between the terminal column and
///   the editor column. The editor column is only added to the split when
///   `workspace.openEditorPath != nil`; the split rebuilds on flip.
/// - The terminal column itself is a vertical stack (terminal on top,
///   command bar slot pinned to the bottom). The command bar is a slim
///   placeholder for now — the orchestrator will swap it for the real
///   `CommandBarView` once that surface lands.
///
/// `currentCwd` is read straight from the model. OSC 7 plumbing from the
/// broker bridge up to here is a follow-up: when the orchestrator wires
/// it, it will call `onCwdChanged(newPath)` which the parent controller
/// uses to mutate `workspace.currentCwd`. The sidebar re-renders any time
/// the workspace value changes via SwiftUI's normal diffing.
struct WorkspaceGroupView: View {
    let theme: ThemeSpec
    let paneID: PaneID
    let workspace: WorkspaceGroup
    let fileMap: PaneFileMap
    let agentClient: AgentClient
    let onOpenFile: (URL) -> Void
    let onCwdChanged: (String) -> Void

    init(
        theme: ThemeSpec,
        paneID: PaneID,
        workspace: WorkspaceGroup,
        fileMap: PaneFileMap,
        agentClient: AgentClient,
        onOpenFile: @escaping (URL) -> Void = { _ in },
        onCwdChanged: @escaping (String) -> Void = { _ in }
    ) {
        self.theme = theme
        self.paneID = paneID
        self.workspace = workspace
        self.fileMap = fileMap
        self.agentClient = agentClient
        self.onOpenFile = onOpenFile
        self.onCwdChanged = onCwdChanged
    }

    var body: some View {
        WorkspaceSplitRepresentable(
            theme: theme,
            paneID: paneID,
            workspace: workspace,
            fileMap: fileMap,
            agentClient: agentClient,
            onOpenFile: onOpenFile,
            onCwdChanged: onCwdChanged
        )
        .background(Color(hex: theme.chrome.border.hex))
    }
}

// MARK: - NSSplitView wrapper

/// Hosts the workspace's two `NSSplitView`s. The split tree is rebuilt on
/// SwiftUI updates whenever a structural change happens (sidebar width,
/// editor presence, paneID change) — but each subpane is wrapped in its
/// own cached `NSHostingController` so the underlying terminal PTY and
/// editor text view survive re-renders intact.
private struct WorkspaceSplitRepresentable: NSViewRepresentable {
    let theme: ThemeSpec
    let paneID: PaneID
    let workspace: WorkspaceGroup
    let fileMap: PaneFileMap
    let agentClient: AgentClient
    let onOpenFile: (URL) -> Void
    let onCwdChanged: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WorkspaceContainerView {
        let view = WorkspaceContainerView()
        view.coordinator = context.coordinator
        view.apply(
            theme: theme,
            paneID: paneID,
            workspace: workspace,
            fileMap: fileMap,
            agentClient: agentClient,
            onOpenFile: onOpenFile,
            onCwdChanged: onCwdChanged
        )
        return view
    }

    func updateNSView(_ nsView: WorkspaceContainerView, context: Context) {
        nsView.coordinator = context.coordinator
        nsView.apply(
            theme: theme,
            paneID: paneID,
            workspace: workspace,
            fileMap: fileMap,
            agentClient: agentClient,
            onOpenFile: onOpenFile,
            onCwdChanged: onCwdChanged
        )
    }

    /// Caches the SwiftUI hosting controllers for the three subpanes
    /// (sidebar, terminal, editor) across re-renders. Without this cache,
    /// every model mutation would tear down and rebuild the broker-backed
    /// terminal view and the STTextView, losing scroll position, focus,
    /// and any in-flight PTY draws.
    @MainActor
    final class Coordinator {
        var sidebarHost: NSHostingController<AnyView>?
        var terminalHost: NSHostingController<AnyView>?
        var editorHost: NSHostingController<AnyView>?
        /// The last paneID this coordinator served. If it changes (e.g. the
        /// pane was replaced), we throw the caches away so the new pane's
        /// terminal isn't bound to the stale broker session.
        var lastPaneID: PaneID?
    }
}

/// Top-level NSView for the workspace. Owns the outer (horizontal) split
/// view and rebuilds the inner split whenever `openEditorPath` flips
/// between nil and set. Subviews are cached so the inner rebuild doesn't
/// destroy live PTY / editor state.
@MainActor
private final class WorkspaceContainerView: NSView {
    weak var coordinator: WorkspaceSplitRepresentable.Coordinator?

    private var outerSplit: BentoWorkspaceSplitView?
    private var sidebarContainer: NSView?
    private var rightContainer: NSView?
    private var innerSplit: BentoWorkspaceSplitView?
    private var terminalColumn: NSView?
    private var editorColumn: NSView?
    private var commandBarHost: NSView?

    private var currentWorkspace: WorkspaceGroup?
    private var hasEditorColumn: Bool = false
    private var pendingSidebarPosition: CGFloat?
    private var pendingEditorPosition: CGFloat?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WorkspaceContainerView does not support NSCoder")
    }

    func apply(
        theme: ThemeSpec,
        paneID: PaneID,
        workspace: WorkspaceGroup,
        fileMap: PaneFileMap,
        agentClient: AgentClient,
        onOpenFile: @escaping (URL) -> Void,
        onCwdChanged: @escaping (String) -> Void
    ) {
        // If the pane identity changes, throw away cached hosts so we
        // don't reattach the previous pane's terminal/editor here.
        if coordinator?.lastPaneID != paneID {
            coordinator?.sidebarHost = nil
            coordinator?.terminalHost = nil
            coordinator?.editorHost = nil
            coordinator?.lastPaneID = paneID
        }

        let needsRebuild = outerSplit == nil
            || hasEditorColumn != (workspace.openEditorPath != nil)

        layer?.backgroundColor = NSColor(hex: theme.chrome.border.hex).cgColor

        if needsRebuild {
            rebuildTree(
                theme: theme,
                paneID: paneID,
                workspace: workspace,
                fileMap: fileMap,
                agentClient: agentClient,
                onOpenFile: onOpenFile,
                onCwdChanged: onCwdChanged
            )
        } else {
            // Cheap path: just refresh the bound SwiftUI roots so theme /
            // workspace changes propagate without rebuilding NSSplitViews.
            refreshHostedRoots(
                theme: theme,
                paneID: paneID,
                workspace: workspace,
                fileMap: fileMap,
                agentClient: agentClient,
                onOpenFile: onOpenFile,
                onCwdChanged: onCwdChanged
            )
        }

        currentWorkspace = workspace
        hasEditorColumn = (workspace.openEditorPath != nil)
    }

    // MARK: - Rebuild

    private func rebuildTree(
        theme: ThemeSpec,
        paneID: PaneID,
        workspace: WorkspaceGroup,
        fileMap: PaneFileMap,
        agentClient: AgentClient,
        onOpenFile: @escaping (URL) -> Void,
        onCwdChanged: @escaping (String) -> Void
    ) {
        // Strip old subviews. The hosting controllers themselves live on
        // the coordinator so their underlying NSViews can be re-inserted
        // into the freshly built containers.
        subviews.forEach { $0.removeFromSuperview() }

        // Sidebar
        let sidebarHost = hostSidebar(
            theme: theme,
            workspace: workspace,
            onOpenFile: onOpenFile
        )
        let sidebarPane = NSView()
        sidebarPane.translatesAutoresizingMaskIntoConstraints = false
        sidebarPane.wantsLayer = true
        sidebarPane.layer?.backgroundColor = NSColor(hex: theme.chrome.background.hex).cgColor
        embed(sidebarHost.view, in: sidebarPane)
        sidebarContainer = sidebarPane

        // Terminal column (terminal on top + command bar slot at bottom).
        let terminalHost = hostTerminal(
            theme: theme,
            paneID: paneID,
            workspace: workspace,
            agentClient: agentClient,
            onCwdChanged: onCwdChanged
        )
        let terminalPane = NSView()
        terminalPane.translatesAutoresizingMaskIntoConstraints = false
        terminalPane.wantsLayer = true
        terminalPane.layer?.backgroundColor = NSColor(hex: theme.terminal.background.hex).cgColor
        let commandBar = makeCommandBar(
            theme: theme,
            paneID: paneID,
            agentClient: agentClient
        )
        embedTerminalColumn(terminalHost.view, commandBar: commandBar, in: terminalPane)
        terminalColumn = terminalPane
        commandBarHost = commandBar

        // Build right container: either just the terminal column, or an
        // inner split (terminal | editor).
        let right: NSView
        if workspace.openEditorPath != nil {
            let editorHost = hostEditor(
                theme: theme,
                paneID: paneID,
                fileMap: fileMap
            )
            let editorPane = NSView()
            editorPane.translatesAutoresizingMaskIntoConstraints = false
            editorPane.wantsLayer = true
            editorPane.layer?.backgroundColor = NSColor(hex: theme.chrome.panel.hex).cgColor
            embed(editorHost.view, in: editorPane)
            editorColumn = editorPane

            let inner = BentoWorkspaceSplitView()
            inner.isVertical = true // vertical divider == side by side
            inner.dividerStyle = .thin
            inner.translatesAutoresizingMaskIntoConstraints = false
            inner.addArrangedSubview(terminalPane)
            inner.addArrangedSubview(editorPane)
            innerSplit = inner
            right = inner
            pendingEditorPosition = workspace.editorWidth
        } else {
            innerSplit = nil
            editorColumn = nil
            right = terminalPane
            pendingEditorPosition = nil
        }
        rightContainer = right

        // Outer split: sidebar | right.
        let outer = BentoWorkspaceSplitView()
        outer.isVertical = true
        outer.dividerStyle = .thin
        outer.translatesAutoresizingMaskIntoConstraints = false
        outer.addArrangedSubview(sidebarPane)
        outer.addArrangedSubview(right)
        outerSplit = outer
        pendingSidebarPosition = workspace.sidebarWidth

        // Pin outer split to fill self.
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // Apply initial divider positions on the next runloop hop so the
        // split has laid out and `bounds` is non-zero.
        DispatchQueue.main.async { [weak self] in
            self?.applyPendingDividers()
        }
    }

    private func applyPendingDividers() {
        if let outer = outerSplit,
           let sidebarPos = pendingSidebarPosition,
           outer.arrangedSubviews.count == 2,
           outer.bounds.width > 0 {
            let target = max(120, min(sidebarPos, outer.bounds.width - 200))
            outer.setPosition(target, ofDividerAt: 0)
            pendingSidebarPosition = nil
        }
        if let inner = innerSplit,
           let editorPos = pendingEditorPosition,
           inner.arrangedSubviews.count == 2,
           inner.bounds.width > 0 {
            // editor occupies the right side; divider sits at total - editorWidth.
            let target = max(160, min(inner.bounds.width - editorPos, inner.bounds.width - 160))
            inner.setPosition(target, ofDividerAt: 0)
            pendingEditorPosition = nil
        }
    }

    override func layout() {
        super.layout()
        // If we're laid out with non-zero bounds and divider placement is
        // still pending (the deferred dispatch lost the race with layout),
        // apply it now.
        if pendingSidebarPosition != nil || pendingEditorPosition != nil {
            applyPendingDividers()
        }
    }

    // MARK: - Refresh (no structural change)

    private func refreshHostedRoots(
        theme: ThemeSpec,
        paneID: PaneID,
        workspace: WorkspaceGroup,
        fileMap: PaneFileMap,
        agentClient: AgentClient,
        onOpenFile: @escaping (URL) -> Void,
        onCwdChanged: @escaping (String) -> Void
    ) {
        coordinator?.sidebarHost?.rootView = AnyView(
            sidebarView(theme: theme, workspace: workspace, onOpenFile: onOpenFile)
        )
        coordinator?.terminalHost?.rootView = AnyView(
            terminalView(
                theme: theme,
                paneID: paneID,
                workspace: workspace,
                agentClient: agentClient,
                onCwdChanged: onCwdChanged
            )
        )
        if workspace.openEditorPath != nil {
            coordinator?.editorHost?.rootView = AnyView(
                editorView(theme: theme, paneID: paneID, fileMap: fileMap)
            )
        }
    }

    // MARK: - Hosting helpers

    private func hostSidebar(
        theme: ThemeSpec,
        workspace: WorkspaceGroup,
        onOpenFile: @escaping (URL) -> Void
    ) -> NSHostingController<AnyView> {
        let root = AnyView(sidebarView(theme: theme, workspace: workspace, onOpenFile: onOpenFile))
        if let existing = coordinator?.sidebarHost {
            existing.rootView = root
            return existing
        }
        let host = NSHostingController(rootView: root)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        coordinator?.sidebarHost = host
        return host
    }

    private func hostTerminal(
        theme: ThemeSpec,
        paneID: PaneID,
        workspace: WorkspaceGroup,
        agentClient: AgentClient,
        onCwdChanged: @escaping (String) -> Void
    ) -> NSHostingController<AnyView> {
        let root = AnyView(
            terminalView(
                theme: theme,
                paneID: paneID,
                workspace: workspace,
                agentClient: agentClient,
                onCwdChanged: onCwdChanged
            )
        )
        if let existing = coordinator?.terminalHost {
            existing.rootView = root
            return existing
        }
        let host = NSHostingController(rootView: root)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        coordinator?.terminalHost = host
        return host
    }

    private func hostEditor(
        theme: ThemeSpec,
        paneID: PaneID,
        fileMap: PaneFileMap
    ) -> NSHostingController<AnyView> {
        let root = AnyView(editorView(theme: theme, paneID: paneID, fileMap: fileMap))
        if let existing = coordinator?.editorHost {
            existing.rootView = root
            return existing
        }
        let host = NSHostingController(rootView: root)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        coordinator?.editorHost = host
        return host
    }

    // MARK: - SwiftUI subviews

    @ViewBuilder
    private func sidebarView(
        theme: ThemeSpec,
        workspace: WorkspaceGroup,
        onOpenFile: @escaping (URL) -> Void
    ) -> some View {
        WorkspaceSidebarView(
            theme: theme,
            currentCwd: workspace.currentCwd,
            onOpenFile: onOpenFile
        )
    }

    @ViewBuilder
    private func terminalView(
        theme: ThemeSpec,
        paneID: PaneID,
        workspace: WorkspaceGroup,
        agentClient: AgentClient,
        onCwdChanged: @escaping (String) -> Void
    ) -> some View {
        // The broker keys panes by `paneID` and survives across UI
        // rebuilds, so `cwd` only matters at first spawn. We pass
        // `currentCwd` (which equals `initialCwd` at first spawn) so a
        // restored snapshot lands the user back at the last-known cwd.
        TerminalPaneView(
            theme: theme,
            paneID: paneID,
            cwd: workspace.currentCwd,
            command: workspace.terminalCommand,
            agentClient: agentClient,
            onCwdChanged: onCwdChanged
        )
    }

    @ViewBuilder
    private func editorView(
        theme: ThemeSpec,
        paneID: PaneID,
        fileMap: PaneFileMap
    ) -> some View {
        EditorPaneView(theme: theme, paneID: paneID, fileMap: fileMap)
    }

    // MARK: - Layout helpers

    private func embed(_ child: NSView, in parent: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        ])
    }

    /// Stacks `terminal` on top of `commandBar` inside `parent`. The
    /// command bar pins to the bottom with its intrinsic height; the
    /// terminal fills the remaining space.
    private func embedTerminalColumn(_ terminal: NSView, commandBar: NSView, in parent: NSView) {
        terminal.translatesAutoresizingMaskIntoConstraints = false
        commandBar.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(terminal)
        parent.addSubview(commandBar)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: parent.topAnchor),
            terminal.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            terminal.bottomAnchor.constraint(equalTo: commandBar.topAnchor),
            commandBar.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            commandBar.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            commandBar.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }

    /// Slim 0-height placeholder for the command bar. Another agent owns
    /// `CommandBarView`; the orchestrator will swap this rect for the
    /// real surface once it lands. Keeping a placeholder NSView (rather
    /// than just an empty constraint) means the orchestrator can install
    /// the real bar with a single `replaceSubview` without surgery on
    /// this file's layout constraints.
    /// Build the Warp-style command bar at the bottom of the terminal
    /// column. Each workspace has its own per-pane `CommandHistory` (held
    /// on the coordinator) so Up/Down arrows walk a per-shell history.
    /// On submit, the typed text + a trailing newline is written into the
    /// broker pane via `AgentClient.writeInput`.
    private func makeCommandBar(
        theme: ThemeSpec,
        paneID: PaneID,
        agentClient: AgentClient
    ) -> NSView {
        let bar = CommandBarView(
            theme: theme,
            onSubmit: { text in
                // Append a trailing newline so the shell treats the line as
                // submitted. Empty submissions still send a newline (matches
                // a bare Return at a real prompt).
                let payload = text + "\n"
                let data = Data(payload.utf8)
                Task { try? await agentClient.writeInput(paneID: paneID, data: data) }
            }
        )
        let host = NSHostingController(rootView: bar)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        return host.view
    }
}

// MARK: - Themed split view

/// `NSSplitView` subclass that paints a 1-px divider in the chrome border
/// colour so the workspace reads as one coherent surface rather than three
/// disconnected boxes. Matches the look of `PaneGridView`'s split.
private final class BentoWorkspaceSplitView: NSSplitView {
    override var dividerColor: NSColor {
        NSColor.black.withAlphaComponent(0.35)
    }

    override var dividerThickness: CGFloat { 1 }
}

// MARK: - Sidebar (workspace-scoped)

/// File-tree sidebar for one workspace. Scans `currentCwd` lazily inside
/// `task(id:)` so the I/O happens off the main view body, and falls back
/// to a friendly empty state if the path doesn't exist (or the scan
/// throws — e.g. permission denied on the workspace root).
private struct WorkspaceSidebarView: View {
    let theme: ThemeSpec
    let currentCwd: String
    let onOpenFile: (URL) -> Void

    @State private var tree: ProjectFileTree?
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header
                if let tree {
                    ForEach(tree.children) { node in
                        FileTreeRow(node: node, theme: theme, onOpenFile: onOpenFile)
                    }
                } else if let loadError {
                    Text(loadError)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
                        .padding(.top, 4)
                } else {
                    Text("Loading…")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(hex: theme.chrome.background.hex))
        .task(id: currentCwd) {
            await loadTree(for: currentCwd)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("WORKSPACE")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
                .padding(.top, 14)
            Text(displayName(for: currentCwd))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(hex: theme.chrome.text.hex))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(currentCwd)
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
                .lineLimit(1)
                .truncationMode(.head)
        }
    }

    private func displayName(for path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1
            ? String(path.dropLast())
            : path
        let last = (trimmed as NSString).lastPathComponent
        return last.isEmpty ? "/" : last
    }

    private func loadTree(for cwd: String) async {
        // ProjectFileTree.scan is synchronous file I/O; hop off the main
        // actor for the scan, then publish back. Catching is important —
        // a missing or unreadable cwd shouldn't take the workspace down.
        let url = URL(fileURLWithPath: cwd)
        do {
            let scanned = try await Task.detached(priority: .userInitiated) {
                try ProjectFileTree.scan(root: url, maxDepth: 3)
            }.value
            await MainActor.run {
                self.tree = scanned
                self.loadError = nil
            }
        } catch {
            await MainActor.run {
                self.tree = nil
                self.loadError = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }
}

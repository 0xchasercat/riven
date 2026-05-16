import AppKit
import BentoCore
import SwiftUI

/// Renders one `WorkspaceGroup` leaf inside the pane grid: a self-contained
/// [sidebar | terminal | editor-if-open] unit. The sidebar shows the file
/// tree of the workspace's currently-tracked `currentCwd`; clicking a file
/// opens it in the workspace's own editor pane (created on demand).
///
/// Layout is built on two real `NSSplitView`s wrapped in an
/// `NSViewRepresentable` so the user gets native divider dragging. Each
/// column reads as a distinct surface (sidebar = `chrome.panel`,
/// terminal = `terminal.background`, editor = blended editor surface) but
/// they share the same hairline dividers and section headers so the three
/// areas feel like one coherent workspace.
///
///   ┌───────────────────────────────────────────────────────┐
///   │ FILES   …/cwd │ TerminalPaneView   │ EDITING  foo.swift │
///   │ ──────────────┼────────────────────┼────────────────── │
///   │  ▸ src        │ ┌────────────────┐ │  …editor body…    │
///   │  ▸ Tests      │ │  terminal grid │ │                    │
///   │               │ └────────────────┘ │                    │
///   │               │ ──── hairline ──── │                    │
///   │               │ ░ command bar  ░░░ │                    │
///   └───────────────────────────────────────────────────────┘
///
/// - The outer split is horizontal: `sidebar | (terminal-area | editor?)`.
/// - The inner split is also horizontal between the terminal column and
///   the editor column. The editor column is only added to the split when
///   `workspace.openEditorPath != nil`; the split rebuilds on flip.
/// - The terminal column itself is a vertical stack (terminal on top,
///   a hairline + the `CommandBarView` wrapped in a thin elevated band
///   pinned to the bottom). The command bar reads as part of the
///   terminal experience rather than a tacked-on widget.
///
/// `currentCwd` is read straight from the model. OSC 7 plumbing from the
/// broker bridge up to here lands in `onCwdChanged` and the parent
/// controller mutates `workspace.currentCwd`. The sidebar animates the
/// file-list refresh with `BentoMotion.pane` so `cd`-driven re-renders
/// feel smooth rather than jarring.
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
        onCwdChanged: @escaping (String) -> Void = { _ in },
        onCloseEditor: @escaping () -> Void = { }
    ) {
        // The editor close action is forwarded via NotificationCenter
        // (`bentoCloseEditor`) so it doesn't have to thread through six
        // layers of NSSplitView / NSHostingController plumbing inside
        // the workspace view. We accept the parameter for API symmetry
        // with the orchestrator but route through notifications.
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
        // The split-view background bleeds through the 1pt divider strips,
        // so colour it with the hairline token to match the in-view
        // dividers and section underlines.
        .background(Color(hex: theme.chrome.hairline.hex))
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
    private var lastSidebarState: WorkspaceSidebarState?
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

        layer?.backgroundColor = NSColor(hex: theme.chrome.hairline.hex).cgColor

        // Sidebar-state changes don't need a full tree rebuild — the
        // tree is intact, we just want the divider to snap to the new
        // collapsed/expanded width. Queue a position update.
        if lastSidebarState != workspace.sidebarState {
            pendingSidebarPosition = workspace.sidebarState == .collapsed
                ? 140
                : workspace.sidebarWidth
            lastSidebarState = workspace.sidebarState
            DispatchQueue.main.async { [weak self] in
                self?.applyPendingDividers()
            }
        }

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
        sidebarPane.layer?.backgroundColor = NSColor(hex: theme.chrome.panel.hex).cgColor
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
        embedTerminalColumn(terminalHost.view, commandBar: commandBar, in: terminalPane, theme: theme)
        terminalColumn = terminalPane
        commandBarHost = commandBar

        // Build right container: either just the terminal column, or an
        // inner split (terminal | editor).
        let right: NSView
        if workspace.openEditorPath != nil {
            let editorHost = hostEditor(
                theme: theme,
                paneID: paneID,
                workspace: workspace,
                fileMap: fileMap
            )
            let editorPane = NSView()
            editorPane.translatesAutoresizingMaskIntoConstraints = false
            editorPane.wantsLayer = true
            editorPane.layer?.backgroundColor = NSColor(hex: theme.chrome.panel.hex).cgColor
            embed(editorHost.view, in: editorPane)
            editorColumn = editorPane

            let inner = BentoWorkspaceSplitView(theme: theme)
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
        let outer = BentoWorkspaceSplitView(theme: theme)
        outer.isVertical = true
        outer.dividerStyle = .thin
        outer.translatesAutoresizingMaskIntoConstraints = false
        outer.addArrangedSubview(sidebarPane)
        outer.addArrangedSubview(right)
        outerSplit = outer
        // Collapsed sidebar = narrow strip (~140 pt — enough for top-level
        // names without burning real estate). Expanded = the user's saved
        // width. Both are applied via setPosition after layout.
        pendingSidebarPosition = workspace.sidebarState == .collapsed
            ? 140
            : workspace.sidebarWidth

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
            // Allow a narrow minimum (~100) so the collapsed strip can
            // actually sit at ~140 pt. The previous min of 160 forced the
            // divider open even when the user collapsed.
            let target = max(100, min(sidebarPos, outer.bounds.width - 240))
            outer.setPosition(target, ofDividerAt: 0)
            pendingSidebarPosition = nil
        }
        if let inner = innerSplit,
           let editorPos = pendingEditorPosition,
           inner.arrangedSubviews.count == 2,
           inner.bounds.width > 0 {
            // editor occupies the right side; divider sits at total - editorWidth.
            let target = max(200, min(inner.bounds.width - editorPos, inner.bounds.width - 200))
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
                editorView(theme: theme, paneID: paneID, workspace: workspace, fileMap: fileMap)
            )
        }
        // Refresh divider colour on themed split views in case the theme
        // changed since the last layout pass.
        outerSplit?.theme = theme
        innerSplit?.theme = theme
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
        workspace: WorkspaceGroup,
        fileMap: PaneFileMap
    ) -> NSHostingController<AnyView> {
        let root = AnyView(editorView(theme: theme, paneID: paneID, workspace: workspace, fileMap: fileMap))
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
            // Sidebar is pinned to the workspace's root — it does NOT
            // follow OSC 7. `cd` in the shell still updates the status
            // breadcrumb but doesn't yank the file viewer to a new path.
            currentCwd: workspace.initialCwd,
            activePath: workspace.openEditorPath,
            isCollapsed: workspace.sidebarState == .collapsed,
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
        workspace: WorkspaceGroup,
        fileMap: PaneFileMap
    ) -> some View {
        WorkspaceEditorColumn(
            theme: theme,
            paneID: paneID,
            openPath: workspace.openEditorPath,
            fileMap: fileMap
        )
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

    /// Stacks `terminal` on top of `commandBar` inside `parent`, separated
    /// by a 1pt hairline so the command bar reads as a deliberate input
    /// strip rather than being flush against the terminal grid.
    private func embedTerminalColumn(
        _ terminal: NSView,
        commandBar: NSView,
        in parent: NSView,
        theme: ThemeSpec
    ) {
        terminal.translatesAutoresizingMaskIntoConstraints = false
        commandBar.translatesAutoresizingMaskIntoConstraints = false

        let hairline = NSView()
        hairline.translatesAutoresizingMaskIntoConstraints = false
        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = NSColor(hex: theme.chrome.hairline.hex).cgColor

        parent.addSubview(terminal)
        parent.addSubview(hairline)
        parent.addSubview(commandBar)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: parent.topAnchor),
            terminal.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            terminal.bottomAnchor.constraint(equalTo: hairline.topAnchor),

            hairline.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: commandBar.topAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),

            commandBar.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            commandBar.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            commandBar.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }

    /// Build the Warp-style command bar at the bottom of the terminal
    /// column. The bar itself is hosted inside a thin `elevated`-coloured
    /// band so it visually pops as the input area without competing with
    /// the terminal grid above.
    /// On submit, the typed text + a trailing newline is written into the
    /// broker pane via `AgentClient.writeInput`.
    private func makeCommandBar(
        theme: ThemeSpec,
        paneID: PaneID,
        agentClient: AgentClient
    ) -> NSView {
        let bar = CommandBarBand(
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

// MARK: - Command bar band

/// Wraps `CommandBarView` in a thin `chrome.elevated`-coloured band so it
/// reads as the workspace's dedicated input strip rather than sitting
/// flush against the terminal grid.
private struct CommandBarBand: View {
    let theme: ThemeSpec
    let onSubmit: (String) -> Void

    var body: some View {
        CommandBarView(theme: theme, onSubmit: onSubmit)
            .padding(.vertical, BentoSpacing.xxs)
            .padding(.horizontal, BentoSpacing.xxs)
            .background(Color(hex: theme.chrome.elevated.hex))
    }
}

// MARK: - Themed split view

/// `NSSplitView` subclass that paints a 1-px divider in the chrome
/// hairline colour so the workspace reads as one coherent surface rather
/// than three disconnected boxes. The colour follows the active theme so
/// switching themes mid-session repaints the divider too.
private final class BentoWorkspaceSplitView: NSSplitView {
    var theme: ThemeSpec {
        didSet { needsDisplay = true }
    }

    init(theme: ThemeSpec) {
        self.theme = theme
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BentoWorkspaceSplitView does not support NSCoder")
    }

    override var dividerColor: NSColor {
        NSColor(hex: theme.chrome.hairline.hex)
    }

    override var dividerThickness: CGFloat { 1 }
}

// MARK: - Sidebar (workspace-scoped)

/// File-tree sidebar for one workspace. Scans `currentCwd` lazily inside
/// `task(id:)` so the I/O happens off the main view body, and falls back
/// to a friendly empty state if the path doesn't exist (or the scan
/// throws — e.g. permission denied on the workspace root).
///
/// Header on top (`FILES` + middle-truncated cwd), file list below with
/// hover/active states, all painted on `chrome.panel`. The cwd-driven
/// refresh animates via `BentoMotion.pane` so `cd`-in-the-shell feels
/// smooth rather than a hard cut.
private struct WorkspaceSidebarView: View {
    let theme: ThemeSpec
    let currentCwd: String
    let activePath: String?
    let isCollapsed: Bool
    let onOpenFile: (URL) -> Void

    @State private var tree: ProjectFileTree?
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline(theme: theme)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    contentBody
                }
                .padding(.horizontal, BentoSpacing.s)
                .padding(.vertical, BentoSpacing.s)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .animation(BentoMotion.pane, value: tree)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(hex: theme.chrome.panel.hex))
        .task(id: currentCwd) {
            await loadTree(for: currentCwd)
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        if let tree {
            if tree.children.isEmpty {
                emptyState
            } else if isCollapsed {
                // Collapsed: top-level entries only, no expand chevrons,
                // tighter rows. Enough visual context to know what's in
                // the workspace without burning horizontal real estate.
                ForEach(tree.children) { node in
                    CollapsedSidebarRow(
                        node: node,
                        theme: theme,
                        activePath: activePath,
                        onOpenFile: onOpenFile
                    )
                }
            } else {
                ForEach(tree.children) { node in
                    WorkspaceFileRow(
                        node: node,
                        theme: theme,
                        depth: 0,
                        activePath: activePath,
                        onOpenFile: onOpenFile
                    )
                }
            }
        } else if let loadError {
            Text(loadError)
                .font(BentoType.mono(BentoType.small))
                .foregroundStyle(Color(hex: theme.chrome.tertiaryText.hex))
                .padding(.top, BentoSpacing.xs)
        } else {
            Text("Loading…")
                .font(BentoType.mono(BentoType.small))
                .foregroundStyle(Color(hex: theme.chrome.tertiaryText.hex))
                .padding(.top, BentoSpacing.xs)
        }
    }

    private var emptyState: some View {
        HStack {
            Spacer(minLength: 0)
            Text("(empty)")
                .font(BentoType.mono(BentoType.small))
                .foregroundStyle(Color(hex: theme.chrome.tertiaryText.hex))
            Spacer(minLength: 0)
        }
        .padding(.vertical, BentoSpacing.l)
    }

    /// 36 pt sticky-feeling header. When expanded: `FILES` label + cwd
    /// breadcrumb + toggle. When collapsed: just a toggle button so the
    /// narrow strip stays usable. Toggle posts `bentoToggleSidebar` and
    /// the controller flips the workspace's `sidebarState`.
    private var header: some View {
        HStack(spacing: BentoSpacing.s) {
            if !isCollapsed {
                SectionLabel(theme: theme, "FILES")
                Spacer(minLength: BentoSpacing.s)
                Text(breadcrumb(for: currentCwd))
                    .font(BentoType.mono(BentoType.small))
                    .foregroundStyle(Color(hex: theme.chrome.accent.hex).opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Spacer(minLength: 0)
            }
            SidebarToggleButton(theme: theme, isCollapsed: isCollapsed)
        }
        .padding(.horizontal, BentoSpacing.s)
        .frame(height: 36)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Renders the cwd as a tilde-prefixed breadcrumb if it lives under
    /// `$HOME`, falling back to the raw absolute path otherwise. The
    /// truncation mode handles ellipsising the middle when the column is
    /// narrow.
    private func breadcrumb(for path: String) -> String {
        let home = NSString(string: NSHomeDirectory()).expandingTildeInPath
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~/" + String(path.dropFirst(home.count + 1))
        }
        return path
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

// MARK: - Sidebar toggle button

/// Chevron button at the top of the workspace sidebar that flips between
/// collapsed (narrow strip) and expanded (full tree). Posts a notification
/// the controller listens for — keeps the SwiftUI tree free of yet
/// another callback parameter to thread.
private struct SidebarToggleButton: View {
    let theme: ThemeSpec
    let isCollapsed: Bool

    @State private var isHovered = false

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .bentoToggleSidebar, object: nil)
        } label: {
            Text(isCollapsed ? "›" : "‹")
                .font(BentoType.chrome(15, weight: .semibold))
                .foregroundStyle(Color(hex: isHovered
                    ? theme.chrome.text.hex
                    : theme.chrome.tertiaryText.hex))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: BentoRadius.small, style: .continuous)
                        .fill(Color(hex: theme.chrome.accentSoft.hex)
                            .opacity(isHovered ? 1 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovered = $0 }
        .help(isCollapsed ? "Expand sidebar" : "Collapse sidebar")
        .animation(BentoMotion.hover, value: isHovered)
    }
}

// MARK: - Collapsed sidebar row

/// Row used in the collapsed sidebar state. Shows the first letter (or
/// first 4 chars) of the directory/file name, vertically centered. Clicking
/// a file still opens it; clicking a directory expands the sidebar.
private struct CollapsedSidebarRow: View {
    let node: ProjectFileTree
    let theme: ThemeSpec
    let activePath: String?
    let onOpenFile: (URL) -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            switch node.kind {
            case .file:
                onOpenFile(URL(fileURLWithPath: node.path))
            case .directory:
                // Expand the sidebar so the user can drill in. Posting the
                // toggle treats the collapsed click as a request to see more.
                NotificationCenter.default.post(name: .bentoToggleSidebar, object: nil)
            }
        } label: {
            HStack(spacing: BentoSpacing.xs) {
                Text(node.kind == .directory ? "▸" : " ")
                    .font(BentoType.mono(BentoType.caption))
                    .foregroundStyle(Color(hex: theme.chrome.tertiaryText.hex))
                Text(node.name)
                    .font(BentoType.mono(BentoType.caption,
                        weight: node.kind == .directory ? .semibold : .regular))
                    .foregroundStyle(Color(hex: isActive
                        ? theme.chrome.accent.hex
                        : theme.chrome.dimText.hex))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, BentoSpacing.xs)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: BentoRadius.small, style: .continuous)
                    .fill(rowBackground)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovered = $0 }
        .animation(BentoMotion.hover, value: isHovered)
    }

    private var isActive: Bool {
        guard let activePath else { return false }
        return activePath == node.path
    }

    private var rowBackground: Color {
        if isActive || isHovered {
            return Color(hex: theme.chrome.accentSoft.hex)
        }
        return Color.clear
    }
}

// MARK: - Sidebar row

/// One row in the workspace sidebar's file tree. Owns its expand/collapse
/// state, paints a hover / active background using the design system's
/// `accentSoft` slot, and indents children by `BentoSpacing.m` per depth
/// level so nesting reads cleanly without horizontal scroll.
private struct WorkspaceFileRow: View {
    let node: ProjectFileTree
    let theme: ThemeSpec
    let depth: Int
    let activePath: String?
    let onOpenFile: (URL) -> Void

    @State private var isExpanded: Bool = true
    @State private var isHovering: Bool = false

    private var isActive: Bool {
        node.kind == .file && activePath == node.path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BentoSpacing.xxs) {
            row
            if isExpanded, !node.children.isEmpty {
                ForEach(node.children) { child in
                    WorkspaceFileRow(
                        node: child,
                        theme: theme,
                        depth: depth + 1,
                        activePath: activePath,
                        onOpenFile: onOpenFile
                    )
                }
            }
        }
    }

    private var row: some View {
        HStack(spacing: BentoSpacing.xs) {
            disclosure
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(Color(hex: foregroundHex))
        }
        .font(BentoType.mono(BentoType.body, weight: node.kind == .directory ? .medium : .regular))
        .padding(.leading, indent)
        .padding(.trailing, BentoSpacing.xs)
        .frame(height: 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: BentoRadius.small, style: .continuous)
                .fill(rowBackground)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(BentoMotion.hover) {
                isHovering = hovering
            }
        }
        .onTapGesture {
            switch node.kind {
            case .directory:
                withAnimation(BentoMotion.standard) { isExpanded.toggle() }
            case .file:
                onOpenFile(URL(fileURLWithPath: node.path))
            }
        }
    }

    private var disclosure: some View {
        Text(disclosureGlyph)
            .font(BentoType.mono(BentoType.caption))
            .foregroundStyle(Color(hex: theme.chrome.tertiaryText.hex))
            .frame(width: 10, alignment: .leading)
    }

    private var disclosureGlyph: String {
        switch node.kind {
        case .directory: return isExpanded ? "v" : ">"
        case .file: return " "
        }
    }

    /// Per-depth indent. `BentoSpacing.m` (12 pt) per level matches the
    /// spec — deep enough to read as nesting, narrow enough that a 220 pt
    /// sidebar can show ~4 levels before truncation kicks in.
    private var indent: CGFloat {
        BentoSpacing.s + CGFloat(depth) * BentoSpacing.m
    }

    private var foregroundHex: String {
        if isActive { return theme.chrome.accent.hex }
        switch node.kind {
        case .directory: return theme.chrome.text.hex
        case .file: return theme.chrome.dimText.hex
        }
    }

    private var rowBackground: Color {
        if isActive || isHovering {
            return Color(hex: theme.chrome.accentSoft.hex)
        }
        return Color.clear
    }
}

// MARK: - Editor column

/// Editor sub-surface shown to the right of the terminal column when
/// `workspace.openEditorPath` is non-nil. Adds a 32 pt header
/// (`EDITING` + the file's `lastPathComponent`) and a hairline above the
/// `EditorPaneView` body so the editor reads as a deliberate sibling of
/// the terminal and sidebar surfaces rather than a bare text box.
private struct WorkspaceEditorColumn: View {
    let theme: ThemeSpec
    let paneID: PaneID
    let openPath: String?
    let fileMap: PaneFileMap

    @State private var isCloseHovered = false

    /// Close action: posts a notification the orchestrator listens for and
    /// translates into `BentoRootController.closeFocusedEditor()`. We use
    /// notifications instead of a callback parameter because plumbing one
    /// through `WorkspaceContainerView` / `rebuildTree` / `hostEditor` /
    /// `editorView` would require six layers of parameter additions for a
    /// single click handler.
    private func onClose() {
        NotificationCenter.default.post(name: .bentoCloseEditor, object: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline(theme: theme)
            EditorPaneView(theme: theme, paneID: paneID, fileMap: fileMap)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: theme.chrome.panel.hex))
    }

    private var header: some View {
        HStack(spacing: BentoSpacing.s) {
            SectionLabel(theme: theme, "EDITING")
            Spacer(minLength: BentoSpacing.s)
            Text(fileName)
                .font(BentoType.mono(BentoType.small, weight: .medium))
                .foregroundStyle(Color(hex: theme.chrome.text.hex))
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: onClose) {
                Text("×")
                    .font(BentoType.chrome(13, weight: .medium))
                    .foregroundStyle(Color(hex: isCloseHovered
                        ? theme.chrome.text.hex
                        : theme.chrome.tertiaryText.hex))
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: BentoRadius.small, style: .continuous)
                            .fill(Color(hex: theme.chrome.accentSoft.hex)
                                .opacity(isCloseHovered ? 1 : 0))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .onHover { isCloseHovered = $0 }
            .help("Close editor (the file stays on disk)")
            .animation(BentoMotion.hover, value: isCloseHovered)
        }
        .padding(.horizontal, BentoSpacing.m)
        .frame(height: 32)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `lastPathComponent` of `openEditorPath` — never the full path, per
    /// the spec. The full path is implied by the sidebar's breadcrumb and
    /// active-row highlight, so the editor header stays terse.
    private var fileName: String {
        guard let openPath, !openPath.isEmpty else { return "—" }
        return URL(fileURLWithPath: openPath).lastPathComponent
    }
}

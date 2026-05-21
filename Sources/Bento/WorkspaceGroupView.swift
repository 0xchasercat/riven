import AppKit
import BentoCore
import SwiftUI

/// Renders one `WorkspaceGroup` leaf inside the pane grid: a self-contained
/// `[sidebar | (inner-tab-strip + focused-tab-content)]` unit. The sidebar
/// shows the file tree of the workspace's root cwd; clicking a file opens
/// it as an editor tab (appended to the inner tab strip, focused).
///
/// Layout is built on one real `NSSplitView` wrapped in an
/// `NSViewRepresentable` so the user gets native divider dragging on the
/// sidebar boundary. The right side is a single hosted SwiftUI column
/// that switches between terminal and editor based on the focused tab's
/// `kind`. Terminal tabs also render the warp-style command bar pinned
/// to the bottom; editor tabs stretch the full vertical area.
///
///   ┌────────────────────────────────────────────────────┐
///   │ FILES   …/cwd │ [shell] [foo.swift] [bar.md]    +  │
///   │ ──────────────┼────────────────────────────────── │
///   │  ▸ src        │  …terminal OR editor body…         │
///   │  ▸ Tests      │                                    │
///   │               │ ──── hairline ──── (terminal only) │
///   │               │ ░ command bar  ░░░ (terminal only) │
///   └────────────────────────────────────────────────────┘
///
/// - The outer split is horizontal: `sidebar | tab-area`.
/// - The tab area itself is a vertical stack (tab strip on top, focused
///   tab content beneath, command bar pinned to the bottom for terminal
///   tabs).
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
    /// Bumped each time the agent client is replaced (initial connect /
    /// watchdog respawn). Stamped into terminal tab `.id(...)` so the
    /// BrokeredTerminalView is rebuilt against the fresh client.
    let brokerEpoch: Int
    /// Which key submits the command bar. Threaded down from the root
    /// so the user's palette-toggle takes effect immediately on every
    /// live command bar.
    let submitMode: CommandBarView.SubmitMode
    /// Set of surface ids that currently have unsaved editor changes.
    /// Threaded down so the InnerTabStrip can render a "•" prefix
    /// without having to reach for the controller via env.
    let dirtySurfaces: Set<SurfaceID>
    /// H-2: editor surfaces whose file vanished underneath the open
    /// buffer. Threaded down to InnerTabStrip ("(missing)" suffix)
    /// and EditorTabContent → EditorToolbar (Save disabled).
    let vanishedSurfaces: Set<SurfaceID>
    let onOpenFile: (URL) -> Void
    let onCwdChanged: (String) -> Void

    init(
        theme: ThemeSpec,
        paneID: PaneID,
        workspace: WorkspaceGroup,
        fileMap: PaneFileMap,
        agentClient: AgentClient,
        brokerEpoch: Int = 0,
        submitMode: CommandBarView.SubmitMode = .enterIsNewline,
        dirtySurfaces: Set<SurfaceID> = [],
        vanishedSurfaces: Set<SurfaceID> = [],
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
        self.brokerEpoch = brokerEpoch
        self.submitMode = submitMode
        self.dirtySurfaces = dirtySurfaces
        self.vanishedSurfaces = vanishedSurfaces
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
            brokerEpoch: brokerEpoch,
            submitMode: submitMode,
            dirtySurfaces: dirtySurfaces,
            vanishedSurfaces: vanishedSurfaces,
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

/// Hosts the workspace's `NSSplitView` (sidebar | tab-area). The tab-area
/// SwiftUI root is rebuilt on focused-tab transitions so each tab gets a
/// fresh BrokeredTerminalView / EditorPaneView pointed at its own surface
/// — but the cached `NSHostingController`s on the coordinator survive
/// re-renders so the underlying terminal PTY / editor text view aren't
/// torn down on every model mutation.
private struct WorkspaceSplitRepresentable: NSViewRepresentable {
    let theme: ThemeSpec
    let paneID: PaneID
    let workspace: WorkspaceGroup
    let fileMap: PaneFileMap
    let agentClient: AgentClient
    let brokerEpoch: Int
    let submitMode: CommandBarView.SubmitMode
    let dirtySurfaces: Set<SurfaceID>
    let vanishedSurfaces: Set<SurfaceID>
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
            brokerEpoch: brokerEpoch,
            submitMode: submitMode,
            dirtySurfaces: dirtySurfaces,
            vanishedSurfaces: vanishedSurfaces,
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
            brokerEpoch: brokerEpoch,
            submitMode: submitMode,
            dirtySurfaces: dirtySurfaces,
            vanishedSurfaces: vanishedSurfaces,
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
        /// Hosting controller for the right-hand tab area (tab strip +
        /// focused tab content + optional command bar). Rebuilt when the
        /// focused tab changes — this keeps the terminal PTY / editor
        /// text view from being torn down on unrelated updates.
        var tabAreaHost: NSHostingController<AnyView>?
        /// The last paneID this coordinator served. If it changes (e.g. the
        /// pane was replaced), we throw the caches away so the new pane's
        /// terminal isn't bound to the stale broker session.
        var lastPaneID: PaneID?
    }
}

/// Top-level NSView for the workspace. Owns the outer (horizontal) split
/// view between the sidebar and the tab-area. The tab-area itself is a
/// single hosted SwiftUI column that swaps content on focused-tab
/// transitions; subviews are cached so unrelated re-renders don't destroy
/// live PTY / editor state.
@MainActor
private final class WorkspaceContainerView: NSView {
    weak var coordinator: WorkspaceSplitRepresentable.Coordinator?

    private var outerSplit: BentoWorkspaceSplitView?
    private var sidebarContainer: NSView?
    private var tabArea: NSView?

    private var currentWorkspace: WorkspaceGroup?
    private var lastSidebarState: WorkspaceSidebarState?
    /// Rebuild the tab area when the user switches inner tabs so each
    /// tab gets its own BrokeredTerminalView / EditorPaneView pointed at
    /// its own surface. Tracked here so `apply` can detect transitions.
    private var lastFocusedTabID: TabID?
    /// Force a tab-area rebuild when the broker is respawned so the
    /// cached `tabAreaHost`'s SwiftUI subtree gets fresh BrokeredTerminal
    /// instances pointed at the new agent client.
    private var lastBrokerEpoch: Int?
    private var pendingSidebarPosition: CGFloat?

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
        brokerEpoch: Int,
        submitMode: CommandBarView.SubmitMode,
        dirtySurfaces: Set<SurfaceID>,
        vanishedSurfaces: Set<SurfaceID>,
        onOpenFile: @escaping (URL) -> Void,
        onCwdChanged: @escaping (String) -> Void
    ) {
        // If the pane identity changes, throw away cached hosts so we
        // don't reattach the previous pane's surfaces here.
        if coordinator?.lastPaneID != paneID {
            coordinator?.sidebarHost = nil
            coordinator?.tabAreaHost = nil
            coordinator?.lastPaneID = paneID
        }

        let focusedTabChanged = lastFocusedTabID != nil
            && lastFocusedTabID != workspace.focusedTabID
        // Broker respawn invalidates the cached host so a fresh
        // BrokeredTerminalView is built against the new agent client.
        let brokerEpochChanged = lastBrokerEpoch != nil
            && lastBrokerEpoch != brokerEpoch
        let needsRebuild = outerSplit == nil
            || focusedTabChanged
            || brokerEpochChanged
        if focusedTabChanged || brokerEpochChanged {
            coordinator?.tabAreaHost = nil
        }
        lastFocusedTabID = workspace.focusedTabID
        lastBrokerEpoch = brokerEpoch

        layer?.backgroundColor = NSColor(hex: theme.chrome.hairline.hex).cgColor

        // Sidebar-state changes don't need a full tree rebuild — the
        // tree is intact, we just want the divider to snap to the new
        // collapsed/expanded width. Queue a position update.
        if lastSidebarState != workspace.sidebarState {
            pendingSidebarPosition = WorkspaceContainerView.sidebarWidth(
                state: workspace.sidebarState,
                expanded: workspace.sidebarWidth
            )
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
                brokerEpoch: brokerEpoch,
                submitMode: submitMode,
                dirtySurfaces: dirtySurfaces,
                vanishedSurfaces: vanishedSurfaces,
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
                brokerEpoch: brokerEpoch,
                submitMode: submitMode,
                dirtySurfaces: dirtySurfaces,
                vanishedSurfaces: vanishedSurfaces,
                onOpenFile: onOpenFile,
                onCwdChanged: onCwdChanged
            )
        }

        currentWorkspace = workspace
    }

    // MARK: - Rebuild

    private func rebuildTree(
        theme: ThemeSpec,
        paneID: PaneID,
        workspace: WorkspaceGroup,
        fileMap: PaneFileMap,
        agentClient: AgentClient,
        brokerEpoch: Int,
        submitMode: CommandBarView.SubmitMode,
        dirtySurfaces: Set<SurfaceID>,
        vanishedSurfaces: Set<SurfaceID>,
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

        // Tab area — a single hosted SwiftUI column carrying the inner
        // tab strip, the focused tab's content (terminal or editor),
        // and (for terminal tabs) the warp-style command bar pinned at
        // the bottom. SwiftUI handles the per-kind layout so we don't
        // need a second NSSplitView here.
        let tabHost = hostTabArea(
            theme: theme,
            paneID: paneID,
            workspace: workspace,
            agentClient: agentClient,
            brokerEpoch: brokerEpoch,
            submitMode: submitMode,
            dirtySurfaces: dirtySurfaces,
            vanishedSurfaces: vanishedSurfaces,
            fileMap: fileMap,
            onCwdChanged: onCwdChanged
        )
        let tabPane = NSView()
        tabPane.translatesAutoresizingMaskIntoConstraints = false
        tabPane.wantsLayer = true
        tabPane.layer?.backgroundColor = NSColor(hex: theme.terminal.background.hex).cgColor
        embed(tabHost.view, in: tabPane)
        tabArea = tabPane

        // Outer split: sidebar | tab-area.
        let outer = BentoWorkspaceSplitView(theme: theme)
        outer.isVertical = true
        outer.dividerStyle = .thin
        outer.translatesAutoresizingMaskIntoConstraints = false
        outer.addArrangedSubview(sidebarPane)
        outer.addArrangedSubview(tabPane)
        outerSplit = outer
        // Collapsed sidebar = a narrow icon rail (56 pt — wide enough
        // for a 32-pt tile centered in the column with 12 pt gutters).
        // Expanded = the user's saved width (220 pt default), clamped
        // to a 240 pt floor for the new design's readable padding.
        pendingSidebarPosition = WorkspaceContainerView.sidebarWidth(
            state: workspace.sidebarState,
            expanded: workspace.sidebarWidth
        )

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
            // Allow the collapsed rail to clamp down to 48 pt minimum
            // (enough for the 32-pt icon tile centered in the rail).
            // Expanded clamps up against `outer.width - 240` so the
            // tab area can never go below a comfortable terminal width.
            let target = max(48, min(sidebarPos, outer.bounds.width - 240))
            outer.setPosition(target, ofDividerAt: 0)
            pendingSidebarPosition = nil
        }
    }

    /// Single source of truth for the sidebar's resting width per state.
    /// Picked here so both `apply` (state change) and `rebuildTree`
    /// (initial layout) read the same constants.
    static func sidebarWidth(state: WorkspaceSidebarState, expanded: CGFloat) -> CGFloat {
        switch state {
        case .collapsed:
            // 56 pt = 32 pt tile + 12 pt left/right gutter.
            return 56
        case .expanded:
            // 240 pt floor: tighter than that and 3+ levels of indent
            // start losing names to truncation.
            return max(240, expanded)
        }
    }

    override func layout() {
        super.layout()
        // If we're laid out with non-zero bounds and divider placement is
        // still pending (the deferred dispatch lost the race with layout),
        // apply it now.
        if pendingSidebarPosition != nil {
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
        brokerEpoch: Int,
        submitMode: CommandBarView.SubmitMode,
        dirtySurfaces: Set<SurfaceID>,
        vanishedSurfaces: Set<SurfaceID>,
        onOpenFile: @escaping (URL) -> Void,
        onCwdChanged: @escaping (String) -> Void
    ) {
        coordinator?.sidebarHost?.rootView = AnyView(
            sidebarView(theme: theme, workspace: workspace, onOpenFile: onOpenFile)
        )
        coordinator?.tabAreaHost?.rootView = AnyView(
            tabAreaView(
                theme: theme,
                paneID: paneID,
                workspace: workspace,
                agentClient: agentClient,
                brokerEpoch: brokerEpoch,
                submitMode: submitMode,
                dirtySurfaces: dirtySurfaces,
                vanishedSurfaces: vanishedSurfaces,
                fileMap: fileMap,
                onCwdChanged: onCwdChanged
            )
        )
        // Refresh divider colour on themed split views in case the theme
        // changed since the last layout pass.
        outerSplit?.theme = theme
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

    private func hostTabArea(
        theme: ThemeSpec,
        paneID: PaneID,
        workspace: WorkspaceGroup,
        agentClient: AgentClient,
        brokerEpoch: Int,
        submitMode: CommandBarView.SubmitMode,
        dirtySurfaces: Set<SurfaceID>,
        vanishedSurfaces: Set<SurfaceID>,
        fileMap: PaneFileMap,
        onCwdChanged: @escaping (String) -> Void
    ) -> NSHostingController<AnyView> {
        let root = AnyView(
            tabAreaView(
                theme: theme,
                paneID: paneID,
                workspace: workspace,
                agentClient: agentClient,
                brokerEpoch: brokerEpoch,
                submitMode: submitMode,
                dirtySurfaces: dirtySurfaces,
                vanishedSurfaces: vanishedSurfaces,
                fileMap: fileMap,
                onCwdChanged: onCwdChanged
            )
        )
        if let existing = coordinator?.tabAreaHost {
            existing.rootView = root
            return existing
        }
        let host = NSHostingController(rootView: root)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        coordinator?.tabAreaHost = host
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
            // Sidebar follows the workspace's live pwd via OSC 7 —
            // workspaces are spaces the user works in, not directory
            // locks. `cd` in the shell moves the file viewer with
            // you. The toolbar's editable path is just a convenience
            // for jumping the shell, NOT a binding that pins the
            // workspace to a specific cwd.
            currentCwd: workspace.currentCwd,
            activePath: workspace.focusedTab.editorPath,
            isCollapsed: workspace.sidebarState == .collapsed,
            onOpenFile: onOpenFile
        )
    }

    /// The right-hand column: inner tab strip + focused tab content +
    /// (for terminal tabs) command bar. The whole stack is keyed on
    /// `(tab.id, brokerEpoch)` so swapping tabs OR getting a fresh
    /// broker connection gives SwiftUI clean teardown/build semantics.
    @ViewBuilder
    private func tabAreaView(
        theme: ThemeSpec,
        paneID: PaneID,
        workspace: WorkspaceGroup,
        agentClient: AgentClient,
        brokerEpoch: Int,
        submitMode: CommandBarView.SubmitMode,
        dirtySurfaces: Set<SurfaceID>,
        vanishedSurfaces: Set<SurfaceID>,
        fileMap: PaneFileMap,
        onCwdChanged: @escaping (String) -> Void
    ) -> some View {
        let tab = workspace.focusedTab
        VStack(spacing: 0) {
            InnerTabStrip(
                theme: theme,
                tabs: workspace.tabs,
                focusedID: workspace.focusedTabID,
                dirtySurfaces: dirtySurfaces,
                vanishedSurfaces: vanishedSurfaces
            )
            Hairline(theme: theme)
            tabContent(
                theme: theme,
                tab: tab,
                workspace: workspace,
                agentClient: agentClient,
                fileMap: fileMap,
                vanishedSurfaces: vanishedSurfaces,
                onCwdChanged: onCwdChanged
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Combined id: switching tabs OR getting a new broker client
            // both rebuild the inner subtree against fresh state.
            .id("\(tab.id.rawValue)|epoch:\(brokerEpoch)")
            // Only terminal tabs get the warp-style command bar. Editor
            // tabs reclaim that vertical space for the text view — typing
            // commands at a file doesn't make sense.
            if case .terminal = tab.kind {
                Hairline(theme: theme)
                CommandBarBand(
                    theme: theme,
                    submitMode: submitMode,
                    onSubmit: { text in
                        guard let paneID = tab.terminalPaneID else { return }
                        let payload = text + "\n"
                        let data = Data(payload.utf8)
                        Task { try? await agentClient.writeInput(paneID: paneID, data: data) }
                    }
                )
            }
        }
        .background(Color(hex: theme.terminal.background.hex))
    }

    @ViewBuilder
    private func tabContent(
        theme: ThemeSpec,
        tab: WorkspaceInnerTab,
        workspace: WorkspaceGroup,
        agentClient: AgentClient,
        fileMap: PaneFileMap,
        vanishedSurfaces: Set<SurfaceID>,
        onCwdChanged: @escaping (String) -> Void
    ) -> some View {
        // The tab's surface tree is rendered recursively. A single-
        // surface tab is the common case (`.leaf(surfaceID)`); split
        // tabs walk the `.split` nodes into nested HStacks / VStacks
        // with a 1pt hairline divider between halves.
        TabLayoutView(
            theme: theme,
            tab: tab,
            agentClient: agentClient,
            fileMap: fileMap,
            vanishedSurfaces: vanishedSurfaces,
            onCwdChanged: onCwdChanged
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

}

// MARK: - Tab layout (recursive split renderer)

/// Walks a `WorkspaceInnerTab.layout` tree and renders the active
/// surfaces — single-surface tabs are a `.leaf`, split tabs are
/// `.split(direction, lhs, rhs)` nodes that nest. SwiftUI HStack /
/// VStack handle the layout; a `Hairline` separates the two halves.
///
/// Native drag-to-resize is not wired yet — that's a polish pass with
/// an NSSplitView-backed representable. For now splits are 50/50 (or
/// proportional to SwiftUI's flex sizing of the children, which for
/// equally-resizable views resolves to even halves).
struct TabLayoutView: View {
    let theme: ThemeSpec
    let tab: WorkspaceInnerTab
    let agentClient: AgentClient
    let fileMap: PaneFileMap
    let vanishedSurfaces: Set<SurfaceID>
    let onCwdChanged: (String) -> Void

    init(
        theme: ThemeSpec,
        tab: WorkspaceInnerTab,
        agentClient: AgentClient,
        fileMap: PaneFileMap,
        vanishedSurfaces: Set<SurfaceID> = [],
        onCwdChanged: @escaping (String) -> Void
    ) {
        self.theme = theme
        self.tab = tab
        self.agentClient = agentClient
        self.fileMap = fileMap
        self.vanishedSurfaces = vanishedSurfaces
        self.onCwdChanged = onCwdChanged
    }

    var body: some View {
        renderLayout(tab.layout)
    }

    /// Recursive renderer. Returns `AnyView` (rather than `some View`)
    /// because Swift's opaque-result-type inference can't resolve a
    /// recursive function that returns itself. The performance cost
    /// is negligible — split trees are at most a handful of nodes
    /// deep, and the renderer isn't on the hot path anyway.
    private func renderLayout(_ node: TabLayout) -> AnyView {
        switch node {
        case let .leaf(surfaceID):
            if let surface = tab.surfaces.first(where: { $0.id == surfaceID }) {
                return AnyView(
                    SurfaceLeafView(
                        theme: theme,
                        tabID: tab.id,
                        surface: surface,
                        isFocused: surfaceID == tab.focusedSurfaceID,
                        showCloseAffordance: tab.isSplit,
                        tabCwd: tab.cwd,
                        agentClient: agentClient,
                        fileMap: fileMap,
                        isVanished: vanishedSurfaces.contains(surface.id),
                        // Only the focused surface gets the cwd-change
                        // callback wired through; other surfaces still
                        // emit OSC 7 events that update their own
                        // terminal state, but they don't push the
                        // workspace sidebar around.
                        onCwdChanged: surfaceID == tab.focusedSurfaceID
                            ? onCwdChanged
                            : { _ in }
                    )
                )
            } else {
                // Defensive: layout references a surface that doesn't
                // exist in `tab.surfaces`. Shouldn't happen, but show
                // a placeholder rather than crash.
                return AnyView(Color(hex: theme.chrome.panel.hex))
            }
        case let .split(direction, lhs, rhs):
            // `.right` = side-by-side (vertical divider between two
            // horizontal halves). `.down` = stacked (horizontal
            // divider between two vertical halves).
            if direction == .right {
                return AnyView(
                    HStack(spacing: 0) {
                        renderLayout(lhs)
                        Hairline(theme: theme, axis: .vertical)
                        renderLayout(rhs)
                    }
                )
            } else {
                return AnyView(
                    VStack(spacing: 0) {
                        renderLayout(lhs)
                        Hairline(theme: theme)
                        renderLayout(rhs)
                    }
                )
            }
        }
    }
}

/// One leaf surface in a tab's layout tree. Renders either a
/// `TerminalPaneView` or an `EditorTabContent`, then wraps the result
/// in an overlay that paints a 1pt accent border on the focused
/// surface (so the user can tell which split owns the command bar)
/// and forwards mouse clicks as `.bentoFocusSurface` notifications.
///
/// Single-surface tabs hit this path too — `isFocused` is always
/// true, the border is invisible (we draw it transparent), so the
/// leaf renders identically to the pre-#23 path.
private struct SurfaceLeafView: View {
    let theme: ThemeSpec
    let tabID: TabID
    let surface: TabSurface
    let isFocused: Bool
    /// True when the parent tab has more than one surface. The
    /// per-surface close-× is hidden on single-surface tabs because
    /// closing the only surface is the same operation as closing the
    /// whole tab — and the tab's own × in the strip already does that.
    let showCloseAffordance: Bool
    let tabCwd: String
    let agentClient: AgentClient
    let fileMap: PaneFileMap
    /// H-2: true when the editor surface's backing file has been
    /// deleted / renamed. Used to disable the toolbar's Save and
    /// surface a "(missing)" hint to the user.
    let isVanished: Bool
    let onCwdChanged: (String) -> Void

    @State private var isHovered = false

    var body: some View {
        // The focused surface is the common case (every single-surface
        // tab hits this branch). Render it without a SwiftUI tap
        // gesture so AppKit mouseDown reaches the BrokeredTerminalView
        // / EditorPaneView underneath uninterrupted — that's what
        // drives text-selection, click-to-focus-the-input
        // (.bentoFocusCommandBar), and the per-cell hit-testing inside
        // the terminal.
        if isFocused {
            focusedLayout
        } else {
            // Unfocused split surfaces use simultaneousGesture so a
            // tap shifts focus without shadowing the underlying
            // NSView's mouseDown — letting the user start typing
            // immediately after the click lands.
            focusedLayout
                .simultaneousGesture(
                    TapGesture().onEnded {
                        NotificationCenter.default.post(
                            name: .bentoFocusSurface,
                            object: SurfaceFocus(tabID: tabID, surfaceID: surface.id)
                        )
                    }
                )
        }
    }

    /// The shared layout for both focused + unfocused leaves. Click
    /// routing is added on top by `body`.
    @ViewBuilder
    private var focusedLayout: some View {
        surfaceBody
            .overlay(focusBorder)
            .overlay(alignment: .topTrailing) {
                if showCloseAffordance {
                    SurfaceCloseButton(theme: theme) {
                        NotificationCenter.default.post(
                            name: .bentoCloseSurface,
                            object: SurfaceFocus(tabID: tabID, surfaceID: surface.id)
                        )
                    }
                    // Always visible on the focused surface (so the
                    // user can see how to close it without hunting);
                    // hover-only on unfocused ones to keep the split
                    // visually clean.
                    .opacity(isFocused || isHovered ? 1 : 0)
                    .padding(6)
                    .animation(BentoMotion.hover, value: isHovered)
                    .animation(BentoMotion.hover, value: isFocused)
                }
            }
            .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var surfaceBody: some View {
        switch surface.kind {
        case let .terminal(paneID, command):
            TerminalPaneView(
                theme: theme,
                paneID: paneID,
                cwd: tabCwd,
                command: command,
                agentClient: agentClient,
                onCwdChanged: onCwdChanged
            )
        case let .editor(path):
            EditorTabContent(
                theme: theme,
                tabID: tabID,
                surfaceID: surface.id,
                path: path,
                fileMap: fileMap,
                isVanished: isVanished
            )
        }
    }

    /// 1pt accent rectangle on the focused leaf. Single-surface tabs
    /// also draw this, but it sits flush against the existing tab
    /// chrome so it reads as "this surface is active" only when there's
    /// a sibling to differentiate from.
    private var focusBorder: some View {
        Rectangle()
            .strokeBorder(
                Color(hex: theme.chrome.accent.hex),
                lineWidth: isFocused ? 1 : 0
            )
            .allowsHitTesting(false)
    }
}

/// Small × chip in the top-right corner of a split surface. Hidden on
/// single-surface tabs (the tab's own × handles that case). On split
/// tabs the focused surface shows the chip at full opacity; non-
/// focused surfaces reveal it on hover. Tap posts
/// `.bentoCloseSurface` with the parent tab + surface ids.
private struct SurfaceCloseButton: View {
    let theme: ThemeSpec
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text("×")
                .font(BentoType.chrome(13, weight: .medium))
                .foregroundStyle(Color(hex: isHovered
                    ? theme.chrome.text.hex
                    : theme.chrome.tertiaryText.hex))
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: BentoRadius.small, style: .continuous)
                        .fill(Color(hex: theme.chrome.elevated.hex)
                            .opacity(isHovered ? 0.9 : 0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: BentoRadius.small, style: .continuous)
                        .stroke(Color(hex: theme.chrome.hairline.hex), lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovered = $0 }
        .help("Close this split (⌘W still closes the whole tab)")
    }
}

// MARK: - Editor tab content

/// SwiftUI wrapper that hosts an `EditorPaneView` for an editor inner tab.
///
/// The existing `EditorPaneView` is keyed off `(PaneID, PaneFileMap)` —
/// it expects the file map to carry the open URL. Inner tabs don't have
/// their own broker `PaneID` (only terminal tabs do), so we synthesize a
/// deterministic PaneID derived from the tab's id and seed the file map
/// before the editor mounts. The seeding happens in `task(id:)` so a
/// later focus-back-to-this-tab restores the binding cleanly even if the
/// map entry was evicted.
///
/// `path` is optional: nil means the tab is a scratch buffer (no file on
/// disk yet). The file map is cleared for the virtual paneID in that case
/// so EditorPaneView shows an empty buffer. Cmd+S on a scratch buffer
/// still saves to disk via EditorPaneView's existing save path, which
/// pops NSSavePanel when there's no URL bound (TODO: implement that
/// branch — currently Cmd+S on a scratch is a no-op).
private struct EditorTabContent: View {
    let theme: ThemeSpec
    let tabID: TabID
    /// The surface this editor lives on inside `tabID`. Splits within
    /// a single tab can host multiple editor surfaces — each needs a
    /// distinct virtual paneID so their file-map entries don't
    /// collide. Defaults to `tabID.rawValue` for non-split callers so
    /// older single-surface tabs keep their stable paneID across
    /// tab focus changes.
    let surfaceID: SurfaceID
    let path: String?
    @ObservedObject var fileMap: PaneFileMap
    /// H-2: true when the editor's file has been deleted / renamed
    /// underneath. Threaded into EditorToolbar so Save can be
    /// disabled + tooltipped appropriately.
    let isVanished: Bool

    @State private var isDirty: Bool = false

    init(
        theme: ThemeSpec,
        tabID: TabID,
        surfaceID: SurfaceID,
        path: String?,
        fileMap: PaneFileMap,
        isVanished: Bool = false
    ) {
        self.theme = theme
        self.tabID = tabID
        self.surfaceID = surfaceID
        self.path = path
        self.fileMap = fileMap
        self.isVanished = isVanished
    }

    /// Stable virtual paneID — `editor-tab-<tab>-<surface>`. Survives
    /// focus changes because both the tab id and the surface id
    /// survive. Coexists with real broker paneIDs (which are UUIDs)
    /// because of the `editor-tab-` prefix.
    private var virtualPaneID: PaneID {
        PaneID("editor-tab-\(tabID.rawValue)-\(surfaceID.rawValue)")
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(
                theme: theme,
                surfaceID: surfaceID,
                isDirty: isDirty,
                path: path,
                isVanished: isVanished
            )
            Hairline(theme: theme)
            EditorPaneView(
                theme: theme,
                paneID: virtualPaneID,
                surfaceID: surfaceID,
                fileMap: fileMap,
                isDirty: $isDirty
            )
            // Claim all remaining vertical space. Without this, the
            // STTextView's intrinsic content height (which can grow
            // with file length OR with an empty scratch buffer's
            // initial layout pass) leaks up through SwiftUI's VStack
            // sizing and pushes the toolbar / hairline / parent chrome
            // beyond the viewport. Pinning maxHeight: .infinity tells
            // SwiftUI "fill what's left after the 32pt toolbar + 1pt
            // hairline" — the NSScrollView then clips long content
            // internally instead of stretching the layout.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // VStack's own max-frame so its child .frame above resolves
        // against the tab area's bounds (which gets .infinity from
        // tabAreaView) instead of falling back to "natural sum of
        // children" sizing.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: theme.chrome.panel.hex))
        .task(id: "\(tabID.rawValue)|\(surfaceID.rawValue)|\(path ?? "")") {
            if let path {
                fileMap.setFile(URL(fileURLWithPath: path), for: virtualPaneID)
            } else {
                // Scratch tab — make sure no stale URL is bound from
                // a prior file-backed editor reusing this paneID.
                fileMap.setFile(nil, for: virtualPaneID)
            }
        }
        .onChange(of: isDirty) { _, newValue in
            // Push the new dirty state to the controller (which
            // mirrors into its `dirtyEditorSurfaces` set used by the
            // inner tab strip's "•" prefix and the close-prompt).
            // Notification-based so we don't have to thread the
            // controller reference through every layer of the
            // workspace view tree.
            NotificationCenter.default.post(
                name: .bentoEditorDirtyChanged,
                object: EditorDirtyChange(surfaceID: surfaceID, isDirty: newValue)
            )
        }
        .onDisappear {
            // When the editor view unmounts (tab close, app teardown)
            // clear our entry from the controller's dirty set so
            // close-prompts don't fire on a phantom dirty buffer that
            // no longer exists.
            NotificationCenter.default.post(
                name: .bentoEditorDirtyChanged,
                object: EditorDirtyChange(surfaceID: surfaceID, isDirty: false)
            )
        }
    }
}

/// Compact toolbar pinned above the editor pane. Surfaces:
///   - dirty indicator (filename with leading "•" when modified)
///   - Save button (Cmd+S equivalent, disabled when clean)
///   - Undo button (Cmd+Z equivalent — actually fires via the
///     standard Edit menu's responder chain so it Just Works)
///
/// Both buttons post `.bentoSaveSurface` / `.bentoUndoSurface` with
/// the surfaceID. EditorPaneView's coordinator observes them and
/// dispatches to its own save / undo paths.
private struct EditorToolbar: View {
    let theme: ThemeSpec
    let surfaceID: SurfaceID
    let isDirty: Bool
    let path: String?
    /// H-2: when true, the file backing this editor was deleted /
    /// renamed under us. Save is disabled (writing to the old path
    /// would re-create a phantom file under the deleted name); the
    /// label gets a "(missing)" suffix to signal the state to the
    /// user. TODO: wire a Save-As flow so users can still rescue the
    /// unsaved buffer to a new path; for now Save just becomes a
    /// no-op with an explanatory tooltip.
    var isVanished: Bool = false

    @State private var isSaveHovered = false
    @State private var isUndoHovered = false

    var body: some View {
        HStack(spacing: BentoSpacing.s) {
            // Filename + dirty dot. Dim color when clean; accent dot
            // up front when modified so a quick glance tells you
            // whether you need to save.
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: theme.chrome.accent.hex))
                    .frame(width: 6, height: 6)
                    .opacity(isDirty ? 1 : 0)
                Text(filenameLabel)
                    .font(BentoType.mono(BentoType.small, weight: isDirty ? .semibold : .regular))
                    .foregroundStyle(Color(hex: filenameHex))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isVanished {
                    Text("(missing)")
                        .font(BentoType.mono(BentoType.small, weight: .regular))
                        .foregroundStyle(Color(hex: theme.chrome.warning.hex))
                }
            }
            Spacer(minLength: BentoSpacing.s)
            // Undo button — posts via NotificationCenter so the
            // EditorPaneView coordinator can dispatch the undo
            // through its NSTextView's undoManager.
            ToolbarIconButton(
                theme: theme,
                glyph: "↶",
                tooltip: "Undo (⌘Z)",
                isHovered: $isUndoHovered
            ) {
                NotificationCenter.default.post(
                    name: .bentoUndoSurface,
                    object: surfaceID
                )
            }
            // Save button — disabled when buffer is clean OR when
            // the backing file vanished underneath us. Same path the
            // close-prompt uses (`.bentoSaveSurface`).
            ToolbarIconButton(
                theme: theme,
                glyph: "⌘S",
                tooltip: isVanished
                    ? "File no longer exists — use Save As (coming soon)"
                    : "Save (⌘S)",
                isHovered: $isSaveHovered,
                isEnabled: isDirty && !isVanished
            ) {
                NotificationCenter.default.post(
                    name: .bentoSaveSurface,
                    object: surfaceID
                )
            }
        }
        .padding(.horizontal, BentoSpacing.m)
        .frame(height: 32)
        .background(Color(hex: theme.chrome.panel.hex))
    }

    private var filenameLabel: String {
        guard let path, !path.isEmpty else { return "Untitled" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// Highlight the filename in the warning tone when the file
    /// vanished so the toolbar reads as visually "uh oh" without
    /// needing a banner. Falls back to the normal dim text when the
    /// file is intact.
    private var filenameHex: String {
        isVanished ? theme.chrome.warning.hex : theme.chrome.dimText.hex
    }
}

/// Small text-glyph button used by the editor toolbar. Plain by
/// default; hover and pressed states paint the standard `accentSoft`
/// fill. `isEnabled = false` dims the glyph and skips the click
/// callback — used for the Save button when the buffer is clean.
private struct ToolbarIconButton: View {
    let theme: ThemeSpec
    let glyph: String
    let tooltip: String
    @Binding var isHovered: Bool
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: { if isEnabled { action() } }) {
            Text(glyph)
                .font(BentoType.chrome(11, weight: .medium))
                .foregroundStyle(Color(hex: foregroundHex))
                .frame(minWidth: 30, minHeight: 22)
                .padding(.horizontal, BentoSpacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: BentoRadius.small, style: .continuous)
                        .fill(Color(hex: theme.chrome.accentSoft.hex)
                            .opacity(isHovered && isEnabled ? 1 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovered = $0 }
        .help(tooltip)
        .disabled(!isEnabled)
    }

    private var foregroundHex: String {
        if !isEnabled { return theme.chrome.tertiaryText.hex }
        return isHovered ? theme.chrome.text.hex : theme.chrome.dimText.hex
    }
}

// MARK: - Command bar band

/// Wraps `CommandBarView` in a thin `chrome.elevated`-coloured band so it
/// reads as the workspace's dedicated input strip rather than sitting
/// flush against the terminal grid.
private struct CommandBarBand: View {
    let theme: ThemeSpec
    let submitMode: CommandBarView.SubmitMode
    let onSubmit: (String) -> Void

    var body: some View {
        // Wrap onSubmit + onHistoryRequest with the shared
        // notification-based wiring so the user's command history
        // walks across all command bars in the window without
        // threading the controller reference through 5 layers.
        CommandBarView(
            theme: theme,
            submitMode: submitMode,
            onSubmit: { text in
                // Forward to the caller (which sends to the PTY) AND
                // record in history. .post is synchronous so the
                // controller's append finishes before the bar clears.
                onSubmit(text)
                NotificationCenter.default.post(
                    name: .bentoCommandSubmitted,
                    object: text
                )
            },
            onHistoryRequest: { direction, currentBuffer in
                // Synchronous request-response over NotificationCenter:
                // build a mutable response box, post the request, the
                // RootView observer writes into the box, we return
                // its contents.
                let response = CommandHistoryResponse()
                let request = CommandHistoryRequest(
                    direction: direction == .previous ? .previous : .next,
                    currentBuffer: currentBuffer,
                    response: response
                )
                NotificationCenter.default.post(
                    name: .bentoCommandHistoryRequest,
                    object: request
                )
                return response.text
            }
        )
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
                // Collapsed: zero horizontal padding — the icon tiles
                // self-center inside the 56 pt rail. Expanded: standard
                // sidebar horizontal padding.
                .padding(.horizontal, isCollapsed ? 0 : BentoSpacing.s)
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
                // Collapsed: a vertical icon rail. Each top-level entry
                // is a 32-pt tile centered in the 56-pt column — no
                // labels, no chevrons, no indents. Click a directory
                // tile to expand the sidebar AND drill in; click a file
                // tile to open it.
                ForEach(tree.children) { node in
                    CollapsedIconTile(
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
            // Loading error: only show in the expanded state — the
            // 56 pt icon rail has no room for prose.
            if !isCollapsed {
                Text(loadError)
                    .font(BentoType.mono(BentoType.small))
                    .foregroundStyle(Color(hex: theme.chrome.tertiaryText.hex))
                    .padding(.top, BentoSpacing.xs)
            }
        } else if !isCollapsed {
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

    /// 36 pt header. Position is invariant across states: toggle is
    /// always trailing-aligned so the chevron stays in the same place
    /// when collapsing / expanding. In the collapsed rail the toggle
    /// just centers within the 56-pt column.
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
                Spacer(minLength: 0)
                // Expand-all / collapse-all toggle. Only meaningful in
                // the expanded sidebar — there's no nested-tree to
                // expand inside the collapsed rail.
                SidebarExpandAllButton(theme: theme)
            } else {
                Spacer(minLength: 0)
            }
            SidebarToggleButton(theme: theme, isCollapsed: isCollapsed)
            if !isCollapsed { Spacer().frame(width: 0) }
        }
        .padding(.horizontal, isCollapsed ? 0 : BentoSpacing.s)
        .frame(height: 36)
        .frame(maxWidth: .infinity, alignment: isCollapsed ? .center : .leading)
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

/// Toggle button in the sidebar header that flips between
/// expand-all and collapse-all. Tracks the current state locally so
/// the icon flips between `chevron.down` (currently expanded → click
/// to collapse all) and `chevron.right` (currently collapsed →
/// click to expand all). Posts `.bentoSidebarSetAllExpanded` with
/// the *new* state every WorkspaceFileRow listens for.
private struct SidebarExpandAllButton: View {
    let theme: ThemeSpec

    @State private var isHovered = false
    @State private var allExpanded = true

    var body: some View {
        Button {
            allExpanded.toggle()
            NotificationCenter.default.post(
                name: .bentoSidebarSetAllExpanded,
                object: NSNumber(value: allExpanded)
            )
        } label: {
            Image(systemName: allExpanded ? "chevron.down.2" : "chevron.right.2")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(hex: isHovered
                    ? theme.chrome.text.hex
                    : theme.chrome.tertiaryText.hex))
                .frame(width: 22, height: 22)
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
        .help(allExpanded ? "Collapse all" : "Expand all")
        .animation(BentoMotion.hover, value: isHovered)
    }
}

// MARK: - Collapsed sidebar tile

/// Square tile in the collapsed icon rail. Renders a single SF Symbol
/// (folder for directories, doc-shaped variant for files) centered in
/// a 32-pt square. Tooltip on hover gives the entry's name so the user
/// can target without expanding the sidebar. Clicking a file opens it;
/// clicking a directory expands the sidebar so the user can drill in.
private struct CollapsedIconTile: View {
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
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(hex: foregroundHex))
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: BentoRadius.small, style: .continuous)
                        .fill(tileBackground)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovered = $0 }
        .help(node.name)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity)
        .animation(BentoMotion.hover, value: isHovered)
    }

    /// SF Symbol id per node kind. Files get a generic "doc.text" so the
    /// icon reads as "document" without spending effort guessing
    /// language-specific glyphs in this iteration. Directories get
    /// "folder.fill" to read as solid against the panel.
    private var iconName: String {
        switch node.kind {
        case .directory: return isActive ? "folder.fill" : "folder"
        case .file: return "doc.text"
        }
    }

    private var isActive: Bool {
        guard let activePath else { return false }
        return activePath == node.path
    }

    private var foregroundHex: String {
        if isActive { return theme.chrome.accent.hex }
        if isHovered { return theme.chrome.text.hex }
        switch node.kind {
        case .directory: return theme.chrome.text.hex
        case .file: return theme.chrome.dimText.hex
        }
    }

    private var tileBackground: Color {
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
        // Listen for global expand-all / collapse-all toggle so the
        // sidebar header's button can drive the whole tree at once.
        // Only directory rows respond (file rows have no children to
        // expand) but the no-op write here is cheap.
        .onReceive(NotificationCenter.default.publisher(for: .bentoSidebarSetAllExpanded)) { note in
            if let n = note.object as? NSNumber, node.kind == .directory {
                isExpanded = n.boolValue
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

// (The legacy `WorkspaceEditorColumn` lived here; it was removed when the
// editor became an inner tab. The new entry point is `EditorTabContent`
// inside `WorkspaceContainerView`'s SwiftUI tab-area surface above.)

import AppKit
import RivenCore
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
/// file-list refresh with `RivenMotion.pane` so `cd`-driven re-renders
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
    /// S-6: shared scrollback store. Forwarded to peek surfaces.
    let scrollback: ScrollbackStore
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
        scrollback: ScrollbackStore,
        onOpenFile: @escaping (URL) -> Void = { _ in },
        onCwdChanged: @escaping (String) -> Void = { _ in },
        onCloseEditor: @escaping () -> Void = { }
    ) {
        // The editor close action is forwarded via NotificationCenter
        // (`rivenCloseEditor`) so it doesn't have to thread through six
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
        self.scrollback = scrollback
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
            scrollback: scrollback,
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
    let scrollback: ScrollbackStore
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
            scrollback: scrollback,
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
            scrollback: scrollback,
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

    private var outerSplit: RivenWorkspaceSplitView?
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
    /// Where the sidebar *wants* to be, retained across layout
    /// passes. `pendingSidebarPosition` was the previous design but
    /// it had a race: the first `layout()` could fire with the
    /// window's frame still smaller than `intended + 240` (e.g.
    /// the initial 0-by-0 measurement pass before AppKit hands the
    /// hosting view its real size), the clamp would settle at the
    /// floor (48 pt), and `pendingSidebarPosition` got cleared so
    /// the next real layout never re-applied. We now keep
    /// `intendedSidebarPosition` populated until we've actually
    /// achieved it — `applyPendingDividers` only clears it once
    /// the divider lands within 1 pt of the request.
    private var intendedSidebarPosition: CGFloat?

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
        scrollback: ScrollbackStore,
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
            let target = WorkspaceContainerView.sidebarWidth(
                state: workspace.sidebarState,
                expanded: workspace.sidebarWidth
            )
            pendingSidebarPosition = target
            intendedSidebarPosition = target
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
                scrollback: scrollback,
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
                scrollback: scrollback,
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
        scrollback: ScrollbackStore,
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
            scrollback: scrollback,
            onCwdChanged: onCwdChanged
        )
        let tabPane = NSView()
        tabPane.translatesAutoresizingMaskIntoConstraints = false
        tabPane.wantsLayer = true
        tabPane.layer?.backgroundColor = NSColor(hex: theme.terminal.background.hex).cgColor
        embed(tabHost.view, in: tabPane)
        tabArea = tabPane

        // Outer split: sidebar | tab-area.
        let outer = RivenWorkspaceSplitView(theme: theme)
        outer.isVertical = true
        outer.dividerStyle = .thin
        outer.translatesAutoresizingMaskIntoConstraints = false
        outer.addArrangedSubview(sidebarPane)
        outer.addArrangedSubview(tabPane)
        outerSplit = outer
        // NOTE: an earlier attempt set `setHoldingPriority(.defaultHigh)`
        // on the sidebar + a `widthAnchor >= 48` constraint. Both
        // backfired — the high holding priority asked NSSplitView to
        // honor the sidebar's intrinsic content size, which for a
        // hosting-controller pane is whatever SwiftUI reports (often
        // smaller than our setPosition target), and the live divider
        // came out at the content's natural width rather than the
        // intended 240. Keep the defaults; rely on `intendedSidebarPosition`
        // + `setPosition` to drive the layout.

        // Collapsed sidebar = a narrow icon rail (56 pt — wide enough
        // for a 32-pt tile centered in the column with 12 pt gutters).
        // Expanded = the user's saved width (220 pt default), clamped
        // to a 240 pt floor for the new design's readable padding.
        let initialTarget = WorkspaceContainerView.sidebarWidth(
            state: workspace.sidebarState,
            expanded: workspace.sidebarWidth
        )
        pendingSidebarPosition = initialTarget
        intendedSidebarPosition = initialTarget

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
        guard let outer = outerSplit,
              let intended = intendedSidebarPosition,
              outer.arrangedSubviews.count == 2,
              outer.bounds.width > 0 else {
            return
        }
        // Floor at 48 pt so the collapsed rail stays clickable;
        // ceiling at `outer.width - 48` so we don't push the
        // divider off the right edge. We deliberately do NOT
        // reserve a "comfortable terminal width" for the tab area
        // — the previous 240 pt reservation crushed the sidebar to
        // ~160 pt on any window narrower than ~500 pt, which is a
        // perfectly reasonable window size on a 13" laptop. The
        // user can drag the divider if they want more terminal
        // room; NSSplitView handles holding priority + reflow on
        // window resize for the common case.
        let target = max(48, min(intended, outer.bounds.width - 48))
        outer.setPosition(target, ofDividerAt: 0)
        pendingSidebarPosition = nil
        // Only call the intent satisfied if the divider actually
        // landed where we asked. The clamp above can pull the target
        // below the intended position when the window is too narrow
        // to accommodate it; in that case we keep `intendedSidebarPosition`
        // set so the next layout pass (after the window grows) gets
        // another chance to hit the real number. This is what fixes
        // the "sidebar sticks at ~80 pt forever" bug — the previous
        // implementation cleared the pending state after the first
        // attempt, so a narrow-initial-bounds layout would settle on
        // 48 pt and never recover when the window resized to its
        // real size.
        let actual = outer.subviews.first?.frame.width ?? 0
        if abs(actual - intended) < 1.5 {
            intendedSidebarPosition = nil
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
        // Re-apply divider position on every layout pass while we
        // still have an unsatisfied intent. This handles two cases:
        //   1. Initial layout: deferred dispatch fired before
        //      `outer.bounds` became real, the apply skipped, and
        //      now we have real bounds.
        //   2. Window resize: the first apply landed at a clamped
        //      value because the window wasn't big enough; now the
        //      user has resized to a width that can accommodate the
        //      intended position so we should reach for it.
        if intendedSidebarPosition != nil {
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
        scrollback: ScrollbackStore,
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
                scrollback: scrollback,
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
        // Match the tab-area + leaf hosts: don't propagate SwiftUI's
        // preferred size up to AutoLayout. The sidebar's contents
        // (file rows) are scroll-clipped, so even a 10k-entry tree
        // shouldn't push the parent split-view past viewport — but
        // with default sizingOptions it could, and this is cheap
        // insurance.
        host.sizingOptions = []
        host.view.setContentHuggingPriority(.defaultLow, for: .vertical)
        host.view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        host.view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        host.view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        scrollback: ScrollbackStore,
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
                scrollback: scrollback,
                onCwdChanged: onCwdChanged
            )
        )
        if let existing = coordinator?.tabAreaHost {
            existing.rootView = root
            return existing
        }
        let host = NSHostingController(rootView: root)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        // #40 follow-up: same fix as PaneGridView.hostingController —
        // clear the default sizingOptions so the host's intrinsic
        // height doesn't override the embed-edge constraints. Without
        // this, an editor inner tab's first layout pass reported the
        // STTextView's natural content height as the host's intrinsic
        // height, which propagated up through the NSSplitView all the
        // way to the mainColumn and pushed the status bar past the
        // window's bottom edge.
        host.sizingOptions = []
        host.view.setContentHuggingPriority(.defaultLow, for: .vertical)
        host.view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        host.view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        host.view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        scrollback: ScrollbackStore,
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
                scrollback: scrollback,
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
        scrollback: ScrollbackStore,
        onCwdChanged: @escaping (String) -> Void
    ) -> some View {
        // The tab's surface tree is rendered recursively. A single-
        // surface tab is the common case (`.leaf(surfaceID)`); split
        // tabs walk the `.split` nodes into nested HStacks / VStacks
        // with a 1pt hairline divider between halves.
        TabLayoutView(
            theme: theme,
            tab: tab,
            workspaceCwd: workspace.currentCwd,
            agentClient: agentClient,
            fileMap: fileMap,
            vanishedSurfaces: vanishedSurfaces,
            scrollback: scrollback,
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
    /// The owning workspace's live cwd. Forwarded to the
    /// scrollback-peek surface so the "Replay in new pane" button
    /// can spawn a fresh shell in the same directory the user is
    /// actually sitting in. Defaults to `tab.cwd` for back-compat.
    let workspaceCwd: String
    let agentClient: AgentClient
    let fileMap: PaneFileMap
    let vanishedSurfaces: Set<SurfaceID>
    let scrollback: ScrollbackStore
    let onCwdChanged: (String) -> Void

    init(
        theme: ThemeSpec,
        tab: WorkspaceInnerTab,
        workspaceCwd: String? = nil,
        agentClient: AgentClient,
        fileMap: PaneFileMap,
        vanishedSurfaces: Set<SurfaceID> = [],
        scrollback: ScrollbackStore,
        onCwdChanged: @escaping (String) -> Void
    ) {
        self.theme = theme
        self.tab = tab
        self.workspaceCwd = workspaceCwd ?? tab.cwd
        self.agentClient = agentClient
        self.fileMap = fileMap
        self.vanishedSurfaces = vanishedSurfaces
        self.scrollback = scrollback
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
                        workspaceCwd: workspaceCwd,
                        agentClient: agentClient,
                        fileMap: fileMap,
                        scrollback: scrollback,
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
            // Inter-pane split divider — inherit the theme's
            // `geometry.dividerWeight` so Riven (6 pt) reads as a
            // proper compartment wall while Carbon / Tokyo / Paper
            // stay at the hairline they ship.
            if direction == .right {
                return AnyView(
                    HStack(spacing: 0) {
                        renderLayout(lhs)
                        Hairline(theme: theme, axis: .vertical, weight: nil)
                        renderLayout(rhs)
                    }
                )
            } else {
                return AnyView(
                    VStack(spacing: 0) {
                        renderLayout(lhs)
                        Hairline(theme: theme, weight: nil)
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
/// and forwards mouse clicks as `.rivenFocusSurface` notifications.
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
    /// Workspace-level cwd, threaded for the scrollback-peek surface
    /// (the "Replay in new pane" button spawns a shell in this dir).
    let workspaceCwd: String
    let agentClient: AgentClient
    let fileMap: PaneFileMap
    /// S-6: shared scrollback store. Used by `.scrollbackPeek`
    /// surfaces to read on-disk log bytes.
    let scrollback: ScrollbackStore
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
        // (.rivenFocusCommandBar), and the per-cell hit-testing inside
        // the terminal.
        if isFocused {
            focusedLayout
        } else {
            // Unfocused split surfaces use a zero-distance DragGesture
            // rather than TapGesture because TapGesture's `.onEnded`
            // doesn't fire until macOS's tap-vs-drag-vs-double-tap
            // recognizer's window closes (~200-300 ms). For a focus-
            // shift that delay reads as the whole UI being sluggish.
            // `DragGesture(minimumDistance: 0).onChanged` fires on
            // mouseDown's very first event, no recognition window.
            //
            // No guard against multi-posting: the controller's
            // `focusSurface` is idempotent (compares before mutating,
            // no-ops when the workspace already says we're focused),
            // and the moment that mutation lands SwiftUI re-renders
            // this leaf into the `if isFocused` branch which has no
            // gesture attached — the gesture is torn down within the
            // same drag and stops firing. Net cost: a small handful
            // of redundant no-op posts during the drag's tail.
            focusedLayout
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // DragGesture(minimumDistance: 0) fires onChanged
                            // for mouseDown (translation == .zero) AND for
                            // every cursor movement during the drag. The
                            // earlier "post unconditionally" version
                            // hammered .rivenFocusSurface dozens of times
                            // during a drag-select gesture — each post
                            // cascaded into a full SwiftUI tree invalidation
                            // via state.paneGraph (the controller's
                            // focusSurface mutates @Published state).
                            //
                            // SwiftUI's gesture event with `translation ==
                            // .zero` corresponds to the initial mouseDown
                            // before any cursor motion. Gate on that to
                            // fire focus-shift exactly once per click.
                            guard value.translation == .zero else { return }
                            NotificationCenter.default.post(
                                name: .rivenFocusSurface,
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
                            name: .rivenCloseSurface,
                            object: SurfaceFocus(tabID: tabID, surfaceID: surface.id)
                        )
                    }
                    // Always visible on the focused surface (so the
                    // user can see how to close it without hunting);
                    // hover-only on unfocused ones to keep the split
                    // visually clean.
                    .opacity(isFocused || isHovered ? 1 : 0)
                    .padding(6)
                    .animation(RivenMotion.hover, value: isHovered)
                    .animation(RivenMotion.hover, value: isFocused)
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
        case let .scrollbackPeek(peekPaneID, focusLine):
            ScrollbackPeekView(
                theme: theme,
                paneID: peekPaneID,
                focusLine: focusLine,
                scrollback: scrollback,
                metadata: (try? scrollback.readMetadata(peekPaneID)) ?? nil,
                onReplayInNewPane: {
                    // S-6: open a fresh terminal inner tab seeded in
                    // the workspace's current cwd. The controller
                    // owns the open-new-tab path; we post a
                    // notification rather than threading another
                    // closure through SurfaceLeafView so the wiring
                    // stays consistent with `.rivenCloseSurface` /
                    // `.rivenFocusSurface`.
                    // TODO: true "replay" — re-running the commands
                    // that produced the scrollback — is a bigger
                    // ticket. Today's button just opens a new shell
                    // in the same cwd.
                    NotificationCenter.default.post(
                        name: .rivenNewTab,
                        object: nil
                    )
                }
            )
        }
    }

    /// Themed accent rectangle on the focused leaf. Width comes from
    /// `geometry.activeHighlightWidth` (defaults to 1 pt) and alpha
    /// from `geometry.activeHighlightAlpha` (Riven ships 0.55 for a
    /// glowing-amber rather than hard-line read; Carbon / Tokyo /
    /// Paper ship 1.0). Single-surface tabs draw this too, but it
    /// sits flush against the existing tab chrome so it reads as
    /// "this surface is active" only when there's a sibling to
    /// differentiate from.
    private var focusBorder: some View {
        let radius = theme.geometry.paneRadius
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(
                Color(hex: theme.chrome.activeBorder.hex)
                    .opacity(theme.geometry.activeHighlightAlpha),
                lineWidth: isFocused ? theme.geometry.activeHighlightWidth : 0
            )
            .allowsHitTesting(false)
    }
}

/// Small × chip in the top-right corner of a split surface. Hidden on
/// single-surface tabs (the tab's own × handles that case). On split
/// tabs the focused surface shows the chip at full opacity; non-
/// focused surfaces reveal it on hover. Tap posts
/// `.rivenCloseSurface` with the parent tab + surface ids.
private struct SurfaceCloseButton: View {
    let theme: ThemeSpec
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text("×")
                .font(RivenType.chrome(13, weight: .medium))
                .foregroundStyle(Color(hex: isHovered
                    ? theme.chrome.text.hex
                    : theme.chrome.tertiaryText.hex))
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: RivenRadius.small, style: .continuous)
                        .fill(Color(hex: theme.chrome.elevated.hex)
                            .opacity(isHovered ? 0.9 : 0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: RivenRadius.small, style: .continuous)
                        .stroke(Color(hex: theme.chrome.hairline.hex), lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovered = $0 }
        .help("Close this split (⌘W still closes the whole tab)")
        // H-14: × is decorative; screen readers should hear "Close split".
        .accessibilityLabel("Close split")
        .accessibilityHint("Removes this surface from the inner tab")
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
                name: .rivenEditorDirtyChanged,
                object: EditorDirtyChange(surfaceID: surfaceID, isDirty: newValue)
            )
        }
        .onDisappear {
            // When the editor view unmounts (tab close, app teardown)
            // clear our entry from the controller's dirty set so
            // close-prompts don't fire on a phantom dirty buffer that
            // no longer exists.
            NotificationCenter.default.post(
                name: .rivenEditorDirtyChanged,
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
/// Both buttons post `.rivenSaveSurface` / `.rivenUndoSurface` with
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
        HStack(spacing: RivenSpacing.s) {
            // Filename + dirty dot. Dim color when clean; accent dot
            // up front when modified so a quick glance tells you
            // whether you need to save.
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: theme.chrome.accent.hex))
                    .frame(width: 6, height: 6)
                    .opacity(isDirty ? 1 : 0)
                Text(filenameLabel)
                    .font(RivenType.mono(RivenType.small, weight: isDirty ? .semibold : .regular))
                    .foregroundStyle(Color(hex: filenameHex))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isVanished {
                    Text("(missing)")
                        .font(RivenType.mono(RivenType.small, weight: .regular))
                        .foregroundStyle(Color(hex: theme.chrome.warning.hex))
                }
            }
            Spacer(minLength: RivenSpacing.s)
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
                    name: .rivenUndoSurface,
                    object: surfaceID
                )
            }
            // Save button — disabled when buffer is clean OR when
            // the backing file vanished underneath us. Same path the
            // close-prompt uses (`.rivenSaveSurface`).
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
                    name: .rivenSaveSurface,
                    object: surfaceID
                )
            }
        }
        .padding(.horizontal, RivenSpacing.m)
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
                .font(RivenType.chrome(11, weight: .medium))
                .foregroundStyle(Color(hex: foregroundHex))
                .frame(minWidth: 30, minHeight: 22)
                .padding(.horizontal, RivenSpacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: RivenRadius.small, style: .continuous)
                        .fill(Color(hex: theme.chrome.accentSoft.hex)
                            .opacity(isHovered && isEnabled ? 1 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovered = $0 }
        .help(tooltip)
        // H-14: the glyph is a decorative unicode char (✎ / ↶ / 〤),
        // useless to VoiceOver — hide it and surface the tooltip as
        // the accessibility label so screen-reader users hear "Save"
        // / "Undo" / "Cycle pane" instead of a literal glyph name.
        .accessibilityLabel(tooltip)
        .accessibilityRemoveTraits(.isImage)
        .accessibilityAddTraits(.isButton)
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
                    name: .rivenCommandSubmitted,
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
                    name: .rivenCommandHistoryRequest,
                    object: request
                )
                return response.text
            },
            onSuggest: { typed in
                // Same synchronous request/response pattern. The
                // controller's `suggestObserver` (installed in
                // `RivenRootController.init`) fills `response.text`
                // before `post` returns. Returning nil ⇒ no ghost
                // text is rendered for this prefix.
                let response = CommandSuggestResponse()
                let request = CommandSuggestRequest(prefix: typed, response: response)
                NotificationCenter.default.post(
                    name: .rivenCommandSuggestRequest,
                    object: request
                )
                return response.text
            }
        )
        .padding(.vertical, RivenSpacing.xxs)
        .padding(.horizontal, RivenSpacing.xxs)
        .background(Color(hex: theme.chrome.elevated.hex))
    }
}

// MARK: - Themed split view

/// `NSSplitView` subclass that paints a 1-px divider in the chrome
/// hairline colour so the workspace reads as one coherent surface rather
/// than three disconnected boxes. The colour follows the active theme so
/// switching themes mid-session repaints the divider too.
private final class RivenWorkspaceSplitView: NSSplitView, NSSplitViewDelegate {
    /// Hard floor for the sidebar pane: even the collapsed icon
    /// rail keeps a 48-pt-wide hit target so the user can always
    /// see + click the expand chevron. AppKit's default lets the
    /// user drag the divider all the way to 0 — once the sidebar
    /// is hidden there's no visible affordance to drag it back.
    /// This is the contract the user articulated: there should be
    /// no scenario where the sidebar is collapsed to the point of
    /// not being visible.
    static let sidebarMinimumWidth: CGFloat = 48

    /// Mirror floor for the tab area so a user dragging the
    /// divider all the way RIGHT doesn't hide the terminal. 48 pt
    /// is just enough to render the close-tab × + a few chars of
    /// label — a "rescue" affordance, not a comfortable working
    /// width, but it keeps the gesture reversible.
    static let tabAreaMinimumWidth: CGFloat = 48

    var theme: ThemeSpec {
        didSet { needsDisplay = true }
    }

    init(theme: ThemeSpec) {
        self.theme = theme
        super.init(frame: .zero)
        // Self-delegate: the split view's two `splitView(_:constrain*)`
        // delegate methods clamp the divider drag range so neither
        // pane can be crushed below the rescue width above.
        self.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RivenWorkspaceSplitView does not support NSCoder")
    }

    override var dividerColor: NSColor {
        NSColor(hex: theme.chrome.hairline.hex)
    }

    override var dividerThickness: CGFloat { 1 }

    // MARK: NSSplitViewDelegate

    /// Minimum divider position (i.e. the smallest the left/sidebar
    /// pane can shrink to). Called continuously during drag and
    /// also during programmatic `setPosition(_:ofDividerAt:)`, so
    /// this is the SINGLE place that enforces the "sidebar always
    /// visible" invariant.
    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard dividerIndex == 0 else { return proposedMinimumPosition }
        return max(proposedMinimumPosition, Self.sidebarMinimumWidth)
    }

    /// Maximum divider position (i.e. the largest the left/sidebar
    /// pane can grow to before the right pane hits its own floor).
    /// We back off `tabAreaMinimumWidth` from the right edge.
    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard dividerIndex == 0 else { return proposedMaximumPosition }
        return min(proposedMaximumPosition, splitView.bounds.width - Self.tabAreaMinimumWidth)
    }
}

// MARK: - Sidebar (workspace-scoped)

/// File-tree sidebar for one workspace. Scans `currentCwd` lazily inside
/// `task(id:)` so the I/O happens off the main view body, and falls back
/// to a friendly empty state if the path doesn't exist (or the scan
/// throws — e.g. permission denied on the workspace root).
///
/// Header on top (`FILES` + middle-truncated cwd), file list below with
/// hover/active states, all painted on `chrome.panel`. The cwd-driven
/// refresh animates via `RivenMotion.pane` so `cd`-in-the-shell feels
/// smooth rather than a hard cut.
private struct WorkspaceSidebarView: View {
    let theme: ThemeSpec
    let currentCwd: String
    let activePath: String?
    let isCollapsed: Bool
    let onOpenFile: (URL) -> Void

    @StateObject private var model = SidebarTreeModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline(theme: theme)
            ScrollView {
                // LazyVStack (not VStack) so only the rows scrolled
                // into view materialize. Combined with the model's
                // shallow-scan + lazy-load, the sidebar renders a
                // handful of views regardless of how deep / wide the
                // directory is — Finder semantics rather than "walk
                // and build the whole tree up front."
                LazyVStack(alignment: .leading, spacing: RivenSpacing.xxs) {
                    contentBody
                }
                // Collapsed: zero horizontal padding — the icon tiles
                // self-center inside the 56 pt rail. Expanded: standard
                // sidebar horizontal padding.
                .padding(.horizontal, isCollapsed ? 0 : RivenSpacing.s)
                .padding(.vertical, RivenSpacing.s)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(hex: theme.chrome.panel.hex))
        .task(id: currentCwd) {
            await model.setRoot(currentCwd)
        }
        // ONE observer for the whole sidebar (was one per row before —
        // thousands of NotificationCenter subscriptions for a big
        // tree). Expand-all only reveals already-loaded directories;
        // deeper levels load lazily as the user drills.
        .onReceive(NotificationCenter.default.publisher(for: .rivenSidebarSetAllExpanded)) { note in
            guard let n = note.object as? NSNumber else { return }
            if n.boolValue { model.expandAllLoaded() } else { model.collapseAll() }
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        if isCollapsed {
            // Collapsed: a vertical icon rail. Top-level entries only
            // — no nesting in the rail. Click a directory tile to
            // expand the sidebar AND drill in; click a file to open.
            ForEach(model.topLevelChildren) { node in
                CollapsedIconTile(
                    node: node,
                    theme: theme,
                    activePath: activePath,
                    onOpenFile: onOpenFile
                )
            }
        } else if let rootError = model.rootError {
            Text(rootError)
                .font(RivenType.mono(RivenType.small))
                .foregroundStyle(Color(hex: theme.chrome.tertiaryText.hex))
                .padding(.top, RivenSpacing.xs)
        } else if model.isEmpty {
            emptyState
        } else if !model.rootLoaded {
            Text("Loading…")
                .font(RivenType.mono(RivenType.small))
                .foregroundStyle(Color(hex: theme.chrome.tertiaryText.hex))
                .padding(.top, RivenSpacing.xs)
        } else {
            // The visible tree, pre-flattened by the model into a
            // linear list of (node, depth) respecting which
            // directories are expanded. Each row renders ONLY itself
            // — no recursion — so LazyVStack can virtualize them.
            ForEach(model.flatRows) { row in
                switch row.content {
                case let .node(node):
                    WorkspaceFileRow(
                        node: node,
                        theme: theme,
                        depth: row.depth,
                        isExpanded: model.expandedPaths.contains(node.path),
                        isLoading: model.loadingPaths.contains(node.path),
                        activePath: activePath,
                        onToggle: { model.toggle(node.path) },
                        onOpenFile: onOpenFile
                    )
                case let .truncation(parent):
                    TruncatedMarkerRow(node: parent, theme: theme, depth: row.depth)
                }
            }
        }
    }

    /// H-9: replace the bare `(empty)` with an actual empty state.
    /// Small SF Symbol on top + a tertiary-tint paragraph below that
    /// tells the user what to do next ("⌘T for a new shell"). The
    /// icon makes the empty state read as intentional rather than
    /// a render glitch, and the shortcut hint primes the muscle
    /// memory we want users to build.
    private var emptyState: some View {
        VStack(spacing: RivenSpacing.s) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Color(hex: theme.chrome.tertiaryText.hex))
                .accessibilityHidden(true)
            Text("no files yet")
                .font(RivenType.mono(RivenType.small, weight: .medium))
                .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
            Text("\u{2318}T for a new shell")
                .font(RivenType.mono(RivenType.caption))
                .foregroundStyle(Color(hex: theme.chrome.tertiaryText.hex))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, RivenSpacing.xl)
    }

    /// 36 pt header. Position is invariant across states: toggle is
    /// always trailing-aligned so the chevron stays in the same place
    /// when collapsing / expanding. In the collapsed rail the toggle
    /// just centers within the 56-pt column.
    private var header: some View {
        HStack(spacing: RivenSpacing.s) {
            if !isCollapsed {
                SectionLabel(theme: theme, "FILES")
                Spacer(minLength: RivenSpacing.s)
                Text(breadcrumb(for: currentCwd))
                    .font(RivenType.mono(RivenType.small))
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
        .padding(.horizontal, isCollapsed ? 0 : RivenSpacing.s)
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

}

// MARK: - Sidebar tree model (shallow scan + lazy load)

/// Backing store for the workspace sidebar's file tree. Models the
/// directory as Finder does: read ONE level at a time, load a
/// directory's children only when the user expands it.
///
/// The previous design eagerly scanned `cwd` to depth 3 and rendered
/// every node with `isExpanded = true` — for a home directory that's
/// thousands of nodes walked + thousands of SwiftUI rows + thousands
/// of per-row NotificationCenter subscriptions built synchronously on
/// every sidebar mount. That was the multi-second hang on launch + new
/// tab. This model loads `cwd`'s immediate children (depth-1 scan,
/// always fast no matter how big the directory) and grafts deeper
/// levels in on demand.
@MainActor
final class SidebarTreeModel: ObservableObject {
    /// The directory each loaded path maps to (its shallow scan,
    /// carrying immediate `children` + `truncatedChildren`). A path
    /// present here has been scanned; absent means "not loaded yet."
    @Published private(set) var loaded: [String: ProjectFileTree] = [:]
    /// Directories the user has expanded. A directory must be both
    /// expanded AND loaded for its children to appear.
    @Published var expandedPaths: Set<String> = []
    /// Directories with an in-flight scan — drives a row spinner.
    @Published private(set) var loadingPaths: Set<String> = []
    /// Set when the root scan itself fails (permission denied, etc.).
    @Published private(set) var rootError: String?
    /// Flips true once the root's first scan completes (success or
    /// empty) so the view can distinguish "still loading" from "loaded
    /// + genuinely empty."
    @Published private(set) var rootLoaded: Bool = false

    private(set) var rootPath: String = ""

    /// Point the model at a directory. Resets all per-tree state when
    /// the root actually changes (a `cd` or workspace switch), then
    /// shallow-scans the new root's immediate children.
    func setRoot(_ path: String) async {
        if path != rootPath {
            rootPath = path
            loaded = [:]
            expandedPaths = []
            loadingPaths = []
            rootError = nil
            rootLoaded = false
        }
        await load(path, isRoot: true)
    }

    /// Toggle a directory's expansion. On first expand, kicks off a
    /// shallow scan of that directory's children (cached after).
    func toggle(_ path: String) {
        if expandedPaths.contains(path) {
            expandedPaths.remove(path)
        } else {
            expandedPaths.insert(path)
            if loaded[path] == nil {
                Task { await load(path, isRoot: false) }
            }
        }
    }

    func collapseAll() {
        expandedPaths = []
    }

    /// Expand every directory we've ALREADY scanned. Deliberately does
    /// not recursively load the whole tree — that would reintroduce
    /// the eager-walk cost we're avoiding. Newly-revealed directories
    /// load lazily as the user keeps drilling.
    func expandAllLoaded() {
        var dirs: Set<String> = []
        for node in loaded.values {
            for child in node.children where child.kind == .directory {
                dirs.insert(child.path)
            }
        }
        expandedPaths.formUnion(dirs)
    }

    /// Immediate children of the root, for the collapsed icon rail.
    var topLevelChildren: [ProjectFileTree] {
        loaded[rootPath]?.children ?? []
    }

    var isEmpty: Bool {
        rootLoaded && (loaded[rootPath]?.children.isEmpty ?? true)
    }

    /// The visible tree flattened to a linear list for LazyVStack.
    /// Walks only expanded + loaded directories, so the cost scales
    /// with what's actually on screen, not with the filesystem.
    var flatRows: [FlatSidebarRow] {
        var out: [FlatSidebarRow] = []
        func walk(_ parentPath: String, depth: Int) {
            guard let parent = loaded[parentPath] else { return }
            for child in parent.children {
                out.append(FlatSidebarRow(content: .node(child), depth: depth, id: child.path))
                guard child.kind == .directory, expandedPaths.contains(child.path) else { continue }
                walk(child.path, depth: depth + 1)
                if let loadedChild = loaded[child.path], loadedChild.truncatedChildren > 0 {
                    out.append(
                        FlatSidebarRow(
                            content: .truncation(parent: loadedChild),
                            depth: depth + 1,
                            id: child.path + "\u{0}trunc"
                        )
                    )
                }
            }
        }
        walk(rootPath, depth: 0)
        if let root = loaded[rootPath], root.truncatedChildren > 0 {
            out.append(
                FlatSidebarRow(
                    content: .truncation(parent: root),
                    depth: 0,
                    id: rootPath + "\u{0}trunc"
                )
            )
        }
        return out
    }

    private func load(_ path: String, isRoot: Bool) async {
        guard loaded[path] == nil else { return }
        loadingPaths.insert(path)
        // Shallow scan: depth-1 only. Returns the directory with its
        // immediate children (directory children are stubs with empty
        // `children` until the user expands them). This is O(entries
        // in this one directory) — instant even for a home dir with
        // thousands of entries, because we never recurse.
        let scanned = await Task.detached(priority: .userInitiated) {
            try? ProjectFileTree.scan(root: URL(fileURLWithPath: path), maxDepth: 1)
        }.value
        loadingPaths.remove(path)
        if let scanned {
            loaded[path] = scanned
            if isRoot {
                rootError = nil
                rootLoaded = true
            }
        } else if isRoot {
            rootError = "Couldn't read \(URL(fileURLWithPath: path).lastPathComponent)"
            rootLoaded = true
        }
    }
}

/// One row in the flattened sidebar list — either a real file/dir
/// node or a "…N more" truncation marker for a capped directory.
struct FlatSidebarRow: Identifiable {
    enum Content {
        case node(ProjectFileTree)
        case truncation(parent: ProjectFileTree)
    }
    let content: Content
    let depth: Int
    let id: String
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
            NotificationCenter.default.post(name: .rivenToggleSidebar, object: nil)
        } label: {
            Text(isCollapsed ? "›" : "‹")
                .font(RivenType.chrome(15, weight: .semibold))
                .foregroundStyle(Color(hex: isHovered
                    ? theme.chrome.text.hex
                    : theme.chrome.tertiaryText.hex))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: RivenRadius.small, style: .continuous)
                        .fill(Color(hex: theme.chrome.accentSoft.hex)
                            .opacity(isHovered ? 1 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovered = $0 }
        .help(isCollapsed ? "Expand sidebar" : "Collapse sidebar")
        // H-14: chevron glyphs are opaque; surface the action.
        .accessibilityLabel(isCollapsed ? "Expand sidebar" : "Collapse sidebar")
        .animation(RivenMotion.hover, value: isHovered)
    }
}

/// Toggle button in the sidebar header that flips between
/// expand-all and collapse-all. Tracks the current state locally so
/// the icon flips between `chevron.down` (currently expanded → click
/// to collapse all) and `chevron.right` (currently collapsed →
/// click to expand all). Posts `.rivenSidebarSetAllExpanded` with
/// the *new* state every WorkspaceFileRow listens for.
private struct SidebarExpandAllButton: View {
    let theme: ThemeSpec

    @State private var isHovered = false
    @State private var allExpanded = true

    var body: some View {
        Button {
            allExpanded.toggle()
            NotificationCenter.default.post(
                name: .rivenSidebarSetAllExpanded,
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
                    RoundedRectangle(cornerRadius: RivenRadius.small, style: .continuous)
                        .fill(Color(hex: theme.chrome.accentSoft.hex)
                            .opacity(isHovered ? 1 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovered = $0 }
        .help(allExpanded ? "Collapse all" : "Expand all")
        // H-14: SF Symbol announces itself as "chevron.down.2" without help.
        .accessibilityLabel(allExpanded ? "Collapse all folders" : "Expand all folders")
        .animation(RivenMotion.hover, value: isHovered)
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
                NotificationCenter.default.post(name: .rivenToggleSidebar, object: nil)
            }
        } label: {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(hex: foregroundHex))
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: RivenRadius.small, style: .continuous)
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
        .animation(RivenMotion.hover, value: isHovered)
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
/// `accentSoft` slot, and indents children by `RivenSpacing.m` per depth
/// level so nesting reads cleanly without horizontal scroll.
private struct WorkspaceFileRow: View {
    let node: ProjectFileTree
    let theme: ThemeSpec
    let depth: Int
    /// Expansion state lives in the SidebarTreeModel now (one Set for
    /// the whole tree), not per-row @State. Passed in so the row can
    /// render the right disclosure glyph; toggled via `onToggle`.
    let isExpanded: Bool
    /// True while this directory's children are being scanned — shows
    /// a subtle in-progress glyph instead of the chevron.
    let isLoading: Bool
    let activePath: String?
    let onToggle: () -> Void
    let onOpenFile: (URL) -> Void

    @State private var isHovering: Bool = false

    private var isActive: Bool {
        node.kind == .file && activePath == node.path
    }

    // Non-recursive: renders ONLY this row. Hierarchy + which children
    // are visible is handled by SidebarTreeModel.flatRows feeding a
    // LazyVStack. No per-row .onReceive (one observer lives on the
    // sidebar container), no child ForEach.
    var body: some View {
        HStack(spacing: RivenSpacing.xs) {
            disclosure
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(Color(hex: foregroundHex))
        }
        .font(RivenType.mono(RivenType.body, weight: node.kind == .directory ? .medium : .regular))
        .padding(.leading, indent)
        .padding(.trailing, RivenSpacing.xs)
        .frame(height: 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: RivenRadius.small, style: .continuous)
                .fill(rowBackground)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(RivenMotion.hover) {
                isHovering = hovering
            }
        }
        .onTapGesture {
            switch node.kind {
            case .directory:
                onToggle()
            case .file:
                onOpenFile(URL(fileURLWithPath: node.path))
            }
        }
    }

    private var disclosure: some View {
        Text(disclosureGlyph)
            .font(RivenType.mono(RivenType.caption))
            .foregroundStyle(Color(hex: theme.chrome.tertiaryText.hex))
            .frame(width: 10, alignment: .leading)
    }

    private var disclosureGlyph: String {
        switch node.kind {
        case .directory:
            if isLoading { return "·" }
            return isExpanded ? "v" : ">"
        case .file:
            return " "
        }
    }

    /// Per-depth indent. `RivenSpacing.m` (12 pt) per level matches the
    /// spec — deep enough to read as nesting, narrow enough that a 220 pt
    /// sidebar can show ~4 levels before truncation kicks in.
    private var indent: CGFloat {
        RivenSpacing.s + CGFloat(depth) * RivenSpacing.m
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

/// "…N more" sentinel row for a directory whose children were elided
/// by the scan's per-directory cap. Click reveals the directory in
/// Finder. Standalone (was nested in WorkspaceFileRow) so the model's
/// flat-row list can emit it as its own entry.
private struct TruncatedMarkerRow: View {
    let node: ProjectFileTree
    let theme: ThemeSpec
    let depth: Int

    var body: some View {
        HStack(spacing: RivenSpacing.xs) {
            Text(" ")
                .font(RivenType.mono(RivenType.caption))
                .frame(width: 10, alignment: .leading)
            Text("… \(node.truncatedChildren) more — open in Finder")
                .font(RivenType.mono(RivenType.caption))
                .foregroundStyle(Color(hex: theme.chrome.tertiaryText.hex))
                .italic()
        }
        .padding(.leading, RivenSpacing.s + CGFloat(depth) * RivenSpacing.m)
        .padding(.trailing, RivenSpacing.xs)
        .frame(height: 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            NSWorkspace.shared.activateFileViewerSelecting([
                URL(fileURLWithPath: node.path)
            ])
        }
        .help("Reveal \(node.name) in Finder to browse all \(node.children.count + node.truncatedChildren) entries")
    }
}

// (The legacy `WorkspaceEditorColumn` lived here; it was removed when the
// editor became an inner tab. The new entry point is `EditorTabContent`
// inside `WorkspaceContainerView`'s SwiftUI tab-area surface above.)

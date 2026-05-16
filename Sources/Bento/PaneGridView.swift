import AppKit
import BentoCore
import SwiftUI

/// Real `NSSplitView`-backed pane grid driven by `BentoCore.PaneGraph`.
///
/// Every leaf in the graph is rendered as either a `TerminalPaneView` or
/// `EditorPaneView` wrapped in a chrome shell; every internal `.split`
/// node is rendered as a real `NSSplitView` (horizontal for `.right`,
/// vertical for `.down` — same terminology as common terminal multiplexers).
///
/// Splitting, focusing, and closing are pure operations on `PaneGraph`;
/// each mutation is reported back to the owner via `onGraphChange` so the
/// workspace controller can persist it.
struct PaneGridView: NSViewRepresentable {
    let theme: ThemeSpec
    let paneGraph: PaneGraph
    let projectRoot: String
    let fileMap: PaneFileMap
    let agentClient: AgentClient?
    /// Bumped each time the agent client is replaced (initial connect /
    /// watchdog respawn). Threaded through so terminal tab content can
    /// stamp it into its `.id(...)` and SwiftUI tears down + rebuilds
    /// the underlying `BrokeredTerminalView` against the fresh client.
    let brokerEpoch: Int
    let onGraphChange: (PaneGraph) -> Void
    let onOpenFile: (URL) -> Void
    let onCwdChanged: (PaneID, String) -> Void

    init(
        theme: ThemeSpec,
        paneGraph: PaneGraph,
        projectRoot: String,
        fileMap: PaneFileMap,
        agentClient: AgentClient?,
        brokerEpoch: Int = 0,
        onGraphChange: @escaping (PaneGraph) -> Void = { _ in },
        onOpenFile: @escaping (URL) -> Void = { _ in },
        onCwdChanged: @escaping (PaneID, String) -> Void = { _, _ in },
        onCloseEditor: @escaping () -> Void = { }
    ) {
        // `onCloseEditor` is accepted for API symmetry; the actual close
        // signal flows via NotificationCenter (`bentoCloseEditor`) so we
        // don't thread the closure through six layers of nested workspace
        // views.
        self.theme = theme
        self.paneGraph = paneGraph
        self.projectRoot = projectRoot
        self.fileMap = fileMap
        self.agentClient = agentClient
        self.brokerEpoch = brokerEpoch
        self.onGraphChange = onGraphChange
        self.onOpenFile = onOpenFile
        self.onCwdChanged = onCwdChanged
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> BentoPaneContainerView {
        let view = BentoPaneContainerView()
        view.coordinator = context.coordinator
        view.apply(
            graph: paneGraph,
            theme: theme,
            projectRoot: projectRoot,
            fileMap: fileMap,
            agentClient: agentClient,
            brokerEpoch: brokerEpoch,
            onGraphChange: onGraphChange,
            onOpenFile: onOpenFile,
            onCwdChanged: onCwdChanged
        )
        // Schedule first-responder grab once we're in a window.
        DispatchQueue.main.async { [weak view] in
            view?.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: BentoPaneContainerView, context: Context) {
        nsView.coordinator = context.coordinator
        nsView.apply(
            graph: paneGraph,
            theme: theme,
            projectRoot: projectRoot,
            fileMap: fileMap,
            agentClient: agentClient,
            brokerEpoch: brokerEpoch,
            onGraphChange: onGraphChange,
            onOpenFile: onOpenFile,
            onCwdChanged: onCwdChanged
        )
    }

    /// Holds per-leaf `NSHostingController`s across SwiftUI updates so the
    /// underlying terminal PTYs / editor text views aren't torn down every
    /// time the graph mutates. Also remembers the last broker epoch we
    /// served — when it changes (broker respawn), the entire cache is
    /// invalidated so stale BrokeredTerminalView captures get rebuilt.
    final class Coordinator {
        var leafHosts: [PaneID: NSHostingController<AnyView>] = [:]
        var brokerEpoch: Int = 0
    }
}

// MARK: - Container NSView

/// Top-level view installed by `PaneGridView`. Hosts the recursive split
/// tree as a single subview, and intercepts pane-grid keyboard shortcuts
/// (Cmd+D, Cmd+Shift+D, Ctrl+Tab, Cmd+W) before they reach the focused
/// pane's first responder.
final class BentoPaneContainerView: NSView {
    weak var coordinator: PaneGridView.Coordinator?

    private var currentGraph: PaneGraph?
    private var onGraphChange: ((PaneGraph) -> Void)?
    private var contentView: NSView?
    /// `Any?` so we can store the observer token across NotificationCenter
    /// API surfaces. Marked unsafe so `deinit` (which is nonisolated) can
    /// remove it without crossing actor boundaries.
    nonisolated(unsafe) private var firstResponderObserver: Any?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    deinit {
        if let firstResponderObserver {
            NotificationCenter.default.removeObserver(firstResponderObserver)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BentoPaneContainerView does not support NSCoder")
    }

    /// Once we're attached to a window, watch for first-responder changes so
    /// that clicks inside an editor (`STTextView`) or terminal
    /// (`BrokeredTerminalView`) update `paneGraph.focusedPaneID`. Without
    /// this, only clicks on the pane's chrome border or header would change
    /// focus — which makes it impossible to tell which pane Cmd+W targets
    /// after typing in a buffer.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let firstResponderObserver {
            NotificationCenter.default.removeObserver(firstResponderObserver)
            self.firstResponderObserver = nil
        }
        guard let window else { return }
        firstResponderObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            // .main queue + main-actor isolation: hop explicitly so Swift 6
            // strict concurrency can verify the call is safe.
            MainActor.assumeIsolated {
                self?.handleFirstResponderChange()
            }
        }
    }

    /// Walk up from the window's current first responder until we find an
    /// enclosing `PaneShellNSView`; if it represents a different pane than
    /// the focused one, propagate the change.
    private func handleFirstResponderChange() {
        guard let window, let responder = window.firstResponder as? NSView else { return }
        var node: NSView? = responder
        while let current = node {
            if let shell = current as? PaneShellNSView {
                requestFocus(shell.paneID)
                return
            }
            node = current.superview
        }
    }

    func apply(
        graph: PaneGraph,
        theme: ThemeSpec,
        projectRoot: String,
        fileMap: PaneFileMap,
        agentClient: AgentClient?,
        brokerEpoch: Int,
        onGraphChange: @escaping (PaneGraph) -> Void,
        onOpenFile: @escaping (URL) -> Void,
        onCwdChanged: @escaping (PaneID, String) -> Void
    ) {
        self.currentGraph = graph
        self.onGraphChange = onGraphChange
        self.layer?.backgroundColor = NSColor(hex: theme.chrome.border.hex).cgColor

        // If the broker has been respawned since the last apply, drop the
        // cached leaf hosting controllers — they hold BrokeredTerminalView
        // instances that captured the *previous* (now-closed) agent
        // client and would silently fail their next subscribe.
        if let coord = coordinator, coord.brokerEpoch != brokerEpoch {
            coord.leafHosts.removeAll()
            coord.brokerEpoch = brokerEpoch
        }

        // Build a fresh tree. NSHostingControllers for leaves are cached on
        // the coordinator so the existing terminal/editor NSViews are reused.
        let builder = PaneTreeBuilder(
            theme: theme,
            graph: graph,
            projectRoot: projectRoot,
            fileMap: fileMap,
            agentClient: agentClient,
            brokerEpoch: brokerEpoch,
            coordinator: coordinator,
            onFocus: { [weak self] id in
                self?.requestFocus(id)
            },
            onSplit: { [weak self] id in
                self?.requestFocus(id)
                self?.splitFocused(.right, target: id)
            },
            onClose: { [weak self] id in
                self?.closeFocused(target: id)
            },
            onOpenFile: onOpenFile,
            onCwdChanged: onCwdChanged
        )
        // One workspace per screen: render ONLY the focused leaf full-width.
        // The pane graph still holds every workspace as a leaf (the top
        // WorkspaceTabBar uses graph.leaves() to populate tab chips), but
        // the user only ever sees one at a time. Splits / side-by-side
        // layouts are explicitly out of scope — they fought the "1 screen
        // = 1 workspace" mental model and made the chrome feel squeezed.
        let newContent = builder.build(node: .leaf(graph.focusedPaneID))

        // Prune hosting controllers for panes that no longer exist.
        let liveIDs = Set(graph.leaves().map(\.id))
        coordinator?.leafHosts = (coordinator?.leafHosts ?? [:]).filter { liveIDs.contains($0.key) }

        // Swap in the new content view.
        contentView?.removeFromSuperview()
        newContent.translatesAutoresizingMaskIntoConstraints = false
        addSubview(newContent)
        NSLayoutConstraint.activate([
            newContent.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            newContent.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            newContent.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            newContent.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
        self.contentView = newContent
    }

    // MARK: - Mutation entry points

    private func requestFocus(_ id: PaneID) {
        guard let graph = currentGraph else { return }
        let next = graph.focus(id)
        if next != graph { onGraphChange?(next) }
    }

    /// Split a pane. If `target` is `nil`, splits the currently focused pane
    /// (keyboard shortcut path). If `target` is non-nil, splits that specific
    /// pane (header `+` button path).
    private func splitFocused(_ direction: SplitDirection, target: PaneID? = nil) {
        guard let graph = currentGraph else { return }
        let id = target ?? graph.focusedPaneID
        let next = graph.splittingInheriting(id, direction: direction)
        if next != graph { onGraphChange?(next) }
    }

    /// Close a pane. If `target` is `nil`, closes the currently focused pane
    /// (keyboard shortcut path). If `target` is non-nil, closes that specific
    /// pane (header `×` button path).
    private func closeFocused(target: PaneID? = nil) {
        guard let graph = currentGraph else { return }
        let id = target ?? graph.focusedPaneID
        if let next = graph.close(id), next != graph {
            onGraphChange?(next)
        }
    }

    private func cycleFocus() {
        guard let graph = currentGraph else { return }
        let next = graph.nextFocus()
        if next != graph { onGraphChange?(next) }
    }

    // MARK: - Keyboard handling

    /// Match against Cmd+D / Cmd+Shift+D / Cmd+W / Ctrl+Tab regardless of
    /// who is first responder. Returns true if the event was consumed.
    private func handleShortcut(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()

        if mods == [.command] && key == "d" {
            splitFocused(.right); return true
        }
        if mods == [.command, .shift] && key == "d" {
            splitFocused(.down); return true
        }
        if mods == [.command] && key == "w" {
            closeFocused(); return true
        }
        // Ctrl+Tab — the character is a horizontal tab (0x09) with .control set.
        if mods == [.control] && event.keyCode == 0x30 {
            cycleFocus(); return true
        }
        return false
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if handleShortcut(event) { return }
        super.keyDown(with: event)
    }
}

// MARK: - Recursive tree builder

/// Walks a `PaneNode` and produces a corresponding tree of `NSSplitView`
/// containers wrapping leaf `PaneShellView`s.
@MainActor
private struct PaneTreeBuilder {
    let theme: ThemeSpec
    let graph: PaneGraph
    let projectRoot: String
    let fileMap: PaneFileMap
    let agentClient: AgentClient?
    let brokerEpoch: Int
    weak var coordinator: PaneGridView.Coordinator?
    let onFocus: @MainActor (PaneID) -> Void
    let onSplit: @MainActor (PaneID) -> Void
    let onClose: @MainActor (PaneID) -> Void
    let onOpenFile: (URL) -> Void
    let onCwdChanged: (PaneID, String) -> Void

    func build(node: PaneNode) -> NSView {
        switch node {
        case let .leaf(id):
            return makeLeaf(id: id)
        case let .split(direction, first, second):
            return makeSplit(
                direction: direction,
                first: build(node: first),
                second: build(node: second),
                autosaveName: Self.autosaveName(for: .split(direction, first, second))
            )
        }
    }

    /// Collect the leaf paneIDs under `node`, sort them, and join with `-`.
    /// Used to build a deterministic `autosaveName` for an `NSSplitView`:
    /// any time the same set of leaves coexists under one split, NSSplitView
    /// can restore the divider position from `UserDefaults`.
    static func autosaveName(for node: PaneNode) -> String {
        let ids = leafIDs(of: node).map(\.rawValue).sorted()
        return "bento-split-\(ids.joined(separator: "-"))"
    }

    private static func leafIDs(of node: PaneNode) -> [PaneID] {
        switch node {
        case let .leaf(id):
            return [id]
        case let .split(_, first, second):
            return leafIDs(of: first) + leafIDs(of: second)
        }
    }

    private func makeSplit(
        direction: SplitDirection,
        first: NSView,
        second: NSView,
        autosaveName: String
    ) -> NSSplitView {
        let split = BentoSplitView()
        split.isVertical = (direction == .right) // .right == side-by-side == vertical divider
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        // Setting `autosaveName` lets NSSplitView persist the divider
        // position under `UserDefaults` (key: "NSSplitView Subview Frames
        // <autosaveName>") across pane-graph rebuilds AND across app
        // launches. Must be set before subviews are added so the first
        // layout reads from the saved value.
        split.autosaveName = autosaveName
        split.addArrangedSubview(first)
        split.addArrangedSubview(second)
        // Default to a 50/50 split, but ONLY when there's no autosaved
        // divider position. NSSplitView restores from autosave automatically;
        // calling `setPosition` here would fight that on every rebuild.
        let hasSavedPosition = UserDefaults.standard.object(
            forKey: "NSSplitView Subview Frames \(autosaveName)"
        ) != nil
        if !hasSavedPosition {
            DispatchQueue.main.async { [weak split] in
                guard let split, split.arrangedSubviews.count == 2 else { return }
                let total = split.isVertical ? split.bounds.width : split.bounds.height
                if total > 0 {
                    split.setPosition((total - split.dividerThickness) / 2, ofDividerAt: 0)
                }
            }
        }
        return split
    }

    private func makeLeaf(id: PaneID) -> NSView {
        let pane = graph.pane(id)
        let isFocused = (id == graph.focusedPaneID)

        let host = hostingController(for: id, pane: pane)

        let shell = PaneShellNSView(
            paneID: id,
            isFocused: isFocused,
            theme: theme,
            onFocus: onFocus,
            onSplit: onSplit,
            onClose: onClose
        )
        shell.installContent(host.view)
        shell.title = pane?.name ?? "pane"
        shell.badge = badge(for: pane)
        return shell
    }

    private func badge(for pane: PaneDescriptor?) -> String {
        // Backend-engine badges ("workspace" / "libghostty" / "STTextView")
        // were internal jargon that competed with the pane title for
        // attention. The pane chrome shows the title; the engine is an
        // implementation detail the user doesn't need surfaced here.
        return ""
    }

    private func hostingController(for id: PaneID, pane: PaneDescriptor?) -> NSHostingController<AnyView> {
        if let existing = coordinator?.leafHosts[id] {
            existing.rootView = leafView(for: id, pane: pane)
            return existing
        }
        let host = NSHostingController(rootView: leafView(for: id, pane: pane))
        host.view.translatesAutoresizingMaskIntoConstraints = false
        coordinator?.leafHosts[id] = host
        return host
    }

    @ViewBuilder
    private func leafContent(for id: PaneID, pane: PaneDescriptor?) -> some View {
        if let pane {
            switch pane.kind {
            case let .terminal(terminal):
                if let agentClient {
                    TerminalPaneView(
                        theme: theme,
                        paneID: pane.id,
                        cwd: terminal.cwd,
                        command: terminal.command,
                        agentClient: agentClient
                    )
                } else {
                    BrokerConnectingPlaceholder(theme: theme)
                }
            case .editor:
                EditorPaneView(theme: theme, paneID: pane.id, fileMap: fileMap)
            case let .workspace(workspace):
                if let agentClient {
                    WorkspaceGroupView(
                        theme: theme,
                        paneID: pane.id,
                        workspace: workspace,
                        fileMap: fileMap,
                        agentClient: agentClient,
                        brokerEpoch: brokerEpoch,
                        onOpenFile: onOpenFile,
                        onCwdChanged: { newCwd in onCwdChanged(pane.id, newCwd) }
                    )
                } else {
                    BrokerConnectingPlaceholder(theme: theme)
                }
            }
        } else {
            // Defensive fallback: the graph referenced an unknown id. Show
            // a placeholder so the tree still renders.
            Color(hex: theme.chrome.panel.hex)
        }
    }

    private func leafView(for id: PaneID, pane: PaneDescriptor?) -> AnyView {
        AnyView(leafContent(for: id, pane: pane))
    }
}

/// Placeholder shown in a terminal leaf while `AgentClient` is still
/// connecting. Once the client lands, the leaf re-renders with a real
/// `TerminalPaneView`.
private struct BrokerConnectingPlaceholder: View {
    let theme: ThemeSpec

    var body: some View {
        VStack {
            Spacer()
            Text("connecting to broker…")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: theme.terminal.background.hex))
    }
}

// MARK: - Split view that doesn't draw a noisy divider

/// `NSSplitView` subclass that uses the chrome border color for its
/// divider so the grid reads as a coherent surface rather than a stack
/// of disconnected boxes.
private final class BentoSplitView: NSSplitView {
    override var dividerColor: NSColor {
        NSColor.black.withAlphaComponent(0.35)
    }

    override var dividerThickness: CGFloat { 1 }
}

// MARK: - Per-pane chrome / click-to-focus

/// Container view for a single leaf. Draws a 1-px border (active or
/// inactive depending on focus), a 32 pt header strip with the pane
/// name + a pill-style backend badge + `+`/`×` buttons, and a 2-pt
/// accent indicator bar UNDER the header when the pane is focused
/// (inactive panes get a hairline divider instead).
///
/// Clicks anywhere on the chrome (header or border) that don't land on
/// a button forward to `onFocus`. Header buttons consume their own
/// clicks so `+`/`×` never double-fire as focus.
///
/// All sizes, fonts, and colors come from `BentoSpacing`, `BentoType`,
/// `BentoRadius`, `BentoMotion`, and `ThemeChrome` — no magic numbers.
private final class PaneShellNSView: NSView {
    let paneID: PaneID
    private let isFocused: Bool
    private let theme: ThemeSpec
    private let onFocus: @MainActor (PaneID) -> Void
    private let onSplit: @MainActor (PaneID) -> Void
    private let onClose: @MainActor (PaneID) -> Void

    private let header = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let badgeContainer = NSView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private let headerIndicator = NSView()
    private let splitButton: PaneHeaderButton
    private let closeButton: PaneHeaderButton
    private let borderLayer = CALayer()
    private var contentContainer = NSView()

    // Header is fixed at 32 pt, with 12 pt horizontal padding inside.
    private static let headerHeight: CGFloat = 32
    // 2-pt active indicator bar under the header on focused pane.
    private static let activeIndicatorHeight: CGFloat = 2
    // 1-pt hairline divider under the header on inactive panes.
    private static let inactiveDividerHeight: CGFloat = 1
    // Pill badge geometry.
    private static let badgeHeight: CGFloat = 18
    private static let badgeHPadding: CGFloat = 6
    // Header buttons: 22x22 hit area, 14x14 visual.
    private static let buttonHitSize: CGFloat = 22
    private static let buttonVisualSize: CGFloat = 14

    var title: String {
        get { titleLabel.stringValue }
        set { titleLabel.stringValue = newValue }
    }

    var badge: String {
        get { badgeLabel.stringValue }
        set {
            badgeLabel.stringValue = newValue
            // Hide the entire pill when there's no badge text so we don't
            // render an empty capsule.
            badgeContainer.isHidden = newValue.isEmpty
        }
    }

    override var isFlipped: Bool { true }

    init(
        paneID: PaneID,
        isFocused: Bool,
        theme: ThemeSpec,
        onFocus: @escaping @MainActor (PaneID) -> Void,
        onSplit: @escaping @MainActor (PaneID) -> Void,
        onClose: @escaping @MainActor (PaneID) -> Void
    ) {
        self.paneID = paneID
        self.isFocused = isFocused
        self.theme = theme
        self.onFocus = onFocus
        self.onSplit = onSplit
        self.onClose = onClose
        self.splitButton = PaneHeaderButton(glyph: "+", accessibilityLabel: "Split pane right")
        self.closeButton = PaneHeaderButton(glyph: "×", accessibilityLabel: "Close pane")
        super.init(frame: .zero)

        wantsLayer = true
        // The pane body uses the standard panel surface; the header sits
        // on top with `elevated` when focused for a subtle depth cue.
        layer?.backgroundColor = NSColor(hex: theme.chrome.panel.hex).cgColor

        // Border around the whole pane: accent at 1-pt when focused,
        // hairline at 1-pt otherwise.
        borderLayer.borderWidth = 1
        borderLayer.borderColor = (
            isFocused
                ? NSColor(hex: theme.chrome.accent.hex)
                : NSColor(hex: theme.chrome.hairline.hex)
        ).cgColor
        borderLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(borderLayer)

        // Header surface: elevated on the focused pane, panel otherwise.
        header.wantsLayer = true
        header.layer?.backgroundColor = headerSurfaceColor.cgColor
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        // Title sits flush-left in the header.
        titleLabel.font = NSFont.systemFont(
            ofSize: BentoType.body,
            weight: isFocused ? .semibold : .medium
        )
        titleLabel.textColor = NSColor(
            hex: isFocused ? theme.chrome.text.hex : theme.chrome.dimText.hex
        )
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.addSubview(titleLabel)

        // Subtle uppercase letter-spaced metadata label — NOT a filled pill.
        // The old accent-on-accentSoft pill had unreadable contrast; this
        // reads as 'this is metadata about the surface' without competing
        // for attention with content.
        badgeContainer.wantsLayer = true
        badgeContainer.layer?.cornerRadius = 0
        badgeContainer.layer?.backgroundColor = NSColor.clear.cgColor
        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.setContentHuggingPriority(.required, for: .horizontal)
        badgeContainer.setContentCompressionResistancePriority(.required, for: .horizontal)
        badgeLabel.font = NSFont.monospacedSystemFont(
            ofSize: BentoType.caption,
            weight: .semibold
        )
        badgeLabel.textColor = NSColor(hex: theme.chrome.tertiaryText.hex)
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.isEditable = false
        badgeLabel.isSelectable = false
        badgeContainer.addSubview(badgeLabel)
        header.addSubview(badgeContainer)

        splitButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        splitButton.configure(
            idleColor: NSColor(hex: theme.chrome.tertiaryText.hex),
            hoverColor: NSColor(hex: theme.chrome.text.hex),
            hoverBackground: NSColor(hex: theme.chrome.accentSoft.hex)
        )
        closeButton.configure(
            idleColor: NSColor(hex: theme.chrome.tertiaryText.hex),
            hoverColor: NSColor(hex: theme.chrome.text.hex),
            hoverBackground: NSColor(hex: theme.chrome.accentSoft.hex)
        )
        splitButton.onClick = { [weak self] in
            guard let self else { return }
            self.onSplit(self.paneID)
        }
        closeButton.onClick = { [weak self] in
            guard let self else { return }
            self.onClose(self.paneID)
        }
        header.addSubview(splitButton)
        header.addSubview(closeButton)

        // Indicator under the header. 2-pt accent bar when focused;
        // 1-pt hairline divider when inactive.
        headerIndicator.wantsLayer = true
        headerIndicator.layer?.backgroundColor = (
            isFocused
                ? NSColor(hex: theme.chrome.accent.hex)
                : NSColor(hex: theme.chrome.hairline.hex)
        ).cgColor
        headerIndicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerIndicator)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentContainer)

        let indicatorHeight = isFocused
            ? Self.activeIndicatorHeight
            : Self.inactiveDividerHeight

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),

            // Title — flush left at BentoSpacing.m (12 pt) from the edge.
            titleLabel.leadingAnchor.constraint(
                equalTo: header.leadingAnchor,
                constant: BentoSpacing.m
            ),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            // Close button — trailing edge at BentoSpacing.s (8 pt) inset,
            // so the 22-pt hit area still sits comfortably inside the 12-pt
            // visual padding zone.
            closeButton.trailingAnchor.constraint(
                equalTo: header.trailingAnchor,
                constant: -BentoSpacing.s
            ),
            closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: Self.buttonHitSize),
            closeButton.heightAnchor.constraint(equalToConstant: Self.buttonHitSize),

            splitButton.trailingAnchor.constraint(
                equalTo: closeButton.leadingAnchor,
                constant: -BentoSpacing.xxs
            ),
            splitButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            splitButton.widthAnchor.constraint(equalToConstant: Self.buttonHitSize),
            splitButton.heightAnchor.constraint(equalToConstant: Self.buttonHitSize),

            // Badge pill sits immediately LEFT of the buttons.
            badgeContainer.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            badgeContainer.heightAnchor.constraint(equalToConstant: Self.badgeHeight),
            badgeContainer.trailingAnchor.constraint(
                equalTo: splitButton.leadingAnchor,
                constant: -BentoSpacing.s
            ),
            badgeContainer.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleLabel.trailingAnchor,
                constant: BentoSpacing.s
            ),

            badgeLabel.leadingAnchor.constraint(
                equalTo: badgeContainer.leadingAnchor,
                constant: Self.badgeHPadding
            ),
            badgeLabel.trailingAnchor.constraint(
                equalTo: badgeContainer.trailingAnchor,
                constant: -Self.badgeHPadding
            ),
            badgeLabel.centerYAnchor.constraint(equalTo: badgeContainer.centerYAnchor),

            headerIndicator.topAnchor.constraint(equalTo: header.bottomAnchor),
            headerIndicator.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerIndicator.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerIndicator.heightAnchor.constraint(equalToConstant: indicatorHeight),

            contentContainer.topAnchor.constraint(equalTo: headerIndicator.bottomAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    private var headerSurfaceColor: NSColor {
        NSColor(hex: isFocused ? theme.chrome.elevated.hex : theme.chrome.panel.hex)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PaneShellNSView does not support NSCoder")
    }

    func installContent(_ view: NSView) {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
        ])
    }

    override func layout() {
        super.layout()
        borderLayer.frame = bounds
    }

    // Click anywhere on the chrome (border or header gap) that doesn't
    // hit a button forwards to focus. `PaneHeaderButton.mouseDown` is
    // self-consuming and never bubbles here, so `+`/`×` clicks don't
    // also trigger a focus event.
    override func mouseDown(with event: NSEvent) {
        onFocus(paneID)
        super.mouseDown(with: event)
    }
}

// MARK: - Header buttons

/// Small square button for the pane header (`+` split, `×` close).
///
/// 22x22 pt hit area with a 14x14 pt visual square inside. Default state
/// renders just the glyph in `tertiaryText`; on hover the inner square
/// fills with `accentSoft` (animated over `BentoMotion.hover`'s ~0.10s)
/// and the glyph shifts to `text`. Pressed-state is the same as hover
/// for now.
///
/// Implemented as a custom `NSView` (not `NSButton`) so we get a
/// minimal, theme-driven look: no system focus ring, no system background.
///
/// `mouseDown` is consumed locally — it never reaches `PaneShellNSView`,
/// so clicking a button doesn't also trigger the pane's focus handler.
private final class PaneHeaderButton: NSView {
    var onClick: (@MainActor () -> Void)?

    private let backdrop = NSView()
    private let label = NSTextField(labelWithString: "")
    private var idleColor: NSColor = .secondaryLabelColor
    private var hoverColor: NSColor = .labelColor
    private var hoverBackground: NSColor = NSColor.white.withAlphaComponent(0.1)
    private var trackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet {
            guard oldValue != isHovering else { return }
            refreshAppearance(animated: true)
        }
    }

    /// Matches `BentoMotion.hover` (SwiftUI 0.10s easeInOut). We can't
    /// reuse the SwiftUI Animation token directly on a CALayer, so we
    /// mirror its duration here.
    private static let hoverAnimationDuration: CFTimeInterval = 0.10
    private static let visualSize: CGFloat = 14

    override var isFlipped: Bool { true }
    // The button refuses focus by returning false here; `refusesFirstResponder`
    // is not an `NSView` property (only `NSResponder` and some subclasses
    // expose it), so we only override the one that exists.
    override var acceptsFirstResponder: Bool { false }

    init(glyph: String, accessibilityLabel: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        // The hover background lives on an inner 14x14 backdrop so the
        // full 22x22 view is the hit area but the visible fill is just
        // the inner square (matches the design spec).
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = BentoRadius.small
        backdrop.layer?.backgroundColor = NSColor.clear.cgColor
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        label.stringValue = glyph
        label.font = NSFont.systemFont(ofSize: BentoType.small, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isEditable = false
        label.isSelectable = false
        // Label sits on top of (but not inside) the backdrop, so the
        // backdrop's corner radius doesn't clip glyph descenders.
        addSubview(label)

        NSLayoutConstraint.activate([
            backdrop.centerXAnchor.constraint(equalTo: centerXAnchor),
            backdrop.centerYAnchor.constraint(equalTo: centerYAnchor),
            backdrop.widthAnchor.constraint(equalToConstant: Self.visualSize),
            backdrop.heightAnchor.constraint(equalToConstant: Self.visualSize),

            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            // Optical centering: the `×` and `+` glyphs sit slightly low
            // in the cap-height box of the system font.
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -0.5),
        ])

        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PaneHeaderButton does not support NSCoder")
    }

    func configure(idleColor: NSColor, hoverColor: NSColor, hoverBackground: NSColor) {
        self.idleColor = idleColor
        self.hoverColor = hoverColor
        self.hoverBackground = hoverBackground
        refreshAppearance(animated: false)
    }

    private func refreshAppearance(animated: Bool) {
        let textColor = isHovering ? hoverColor : idleColor
        let bgColor = (isHovering ? hoverBackground : NSColor.clear).cgColor
        if animated {
            CATransaction.begin()
            CATransaction.setAnimationDuration(Self.hoverAnimationDuration)
            backdrop.layer?.backgroundColor = bgColor
            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            backdrop.layer?.backgroundColor = bgColor
            CATransaction.commit()
        }
        // Text color isn't animatable through NSTextField cleanly, so we
        // just switch it (the change is small enough that a hard cut reads
        // fine against the animated background).
        label.textColor = textColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        NSCursor.arrow.set()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    // Consume the click locally so it never reaches the enclosing
    // `PaneShellNSView.mouseDown` (which would refocus the pane and then
    // call `super`, racing the action).
    override func mouseDown(with event: NSEvent) {
        // Track press-then-release inside the 22-pt hit area so dragging
        // away cancels, matching standard button behavior. The full
        // `bounds` is the hit zone, not just the visible 14x14 backdrop.
        var pressed = true
        isHovering = true
        var current = event
        while pressed {
            let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged])
            guard let next else { break }
            let location = convert(next.locationInWindow, from: nil)
            let inside = bounds.contains(location)
            if next.type == .leftMouseUp {
                if inside { onClick?() }
                pressed = false
            } else {
                isHovering = inside
                current = next
            }
        }
        _ = current
        // Refresh hover state from the final mouse position.
        if let window {
            let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            isHovering = bounds.contains(location)
        }
    }
}

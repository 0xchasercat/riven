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
    let onGraphChange: (PaneGraph) -> Void
    let onOpenFile: (URL) -> Void
    let onCwdChanged: (PaneID, String) -> Void

    init(
        theme: ThemeSpec,
        paneGraph: PaneGraph,
        projectRoot: String,
        fileMap: PaneFileMap,
        agentClient: AgentClient?,
        onGraphChange: @escaping (PaneGraph) -> Void = { _ in },
        onOpenFile: @escaping (URL) -> Void = { _ in },
        onCwdChanged: @escaping (PaneID, String) -> Void = { _, _ in }
    ) {
        self.theme = theme
        self.paneGraph = paneGraph
        self.projectRoot = projectRoot
        self.fileMap = fileMap
        self.agentClient = agentClient
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
            onGraphChange: onGraphChange,
            onOpenFile: onOpenFile,
            onCwdChanged: onCwdChanged
        )
    }

    /// Holds per-leaf `NSHostingController`s across SwiftUI updates so the
    /// underlying terminal PTYs / editor text views aren't torn down every
    /// time the graph mutates.
    final class Coordinator {
        var leafHosts: [PaneID: NSHostingController<AnyView>] = [:]
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
        onGraphChange: @escaping (PaneGraph) -> Void,
        onOpenFile: @escaping (URL) -> Void,
        onCwdChanged: @escaping (PaneID, String) -> Void
    ) {
        self.currentGraph = graph
        self.onGraphChange = onGraphChange
        self.layer?.backgroundColor = NSColor(hex: theme.chrome.border.hex).cgColor

        // Build a fresh tree. NSHostingControllers for leaves are cached on
        // the coordinator so the existing terminal/editor NSViews are reused.
        let builder = PaneTreeBuilder(
            theme: theme,
            graph: graph,
            projectRoot: projectRoot,
            fileMap: fileMap,
            agentClient: agentClient,
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
        let newContent = builder.build(node: graph.rootNode)

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
        let activeHex = theme.chrome.activeBorder.hex
        let inactiveHex = theme.chrome.border.hex

        let host = hostingController(for: id, pane: pane)

        let shell = PaneShellNSView(
            paneID: id,
            isFocused: isFocused,
            activeColor: NSColor(hex: activeHex),
            inactiveColor: NSColor(hex: inactiveHex),
            chromeBackground: NSColor(hex: theme.chrome.panel.hex),
            onFocus: onFocus,
            onSplit: onSplit,
            onClose: onClose
        )
        shell.installContent(host.view)
        shell.title = pane?.name ?? "pane"
        shell.titleColor = NSColor(hex: theme.chrome.text.hex)
        shell.headerBackground = NSColor(hex: theme.chrome.background.hex)
        shell.badge = badge(for: pane)
        shell.badgeColor = NSColor(hex: theme.chrome.dimText.hex)
        shell.applyButtonColors(
            idle: NSColor(hex: theme.chrome.dimText.hex),
            hover: NSColor(hex: theme.chrome.text.hex),
            hoverBackground: NSColor(hex: activeHex).withAlphaComponent(0.15)
        )
        return shell
    }

    private func badge(for pane: PaneDescriptor?) -> String {
        switch pane?.kind {
        case .editor: return "STTextView"
        case .terminal: return "libghostty"
        case .workspace: return "workspace"
        case .none: return ""
        }
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
/// inactive depending on focus), a small header strip with the pane
/// name + backend badge, and forwards clicks anywhere inside the pane
/// to `onFocus` so the user can click between panes to move focus.
private final class PaneShellNSView: NSView {
    let paneID: PaneID
    private let isFocused: Bool
    private let activeColor: NSColor
    private let inactiveColor: NSColor
    private let onFocus: @MainActor (PaneID) -> Void
    private let onSplit: @MainActor (PaneID) -> Void
    private let onClose: @MainActor (PaneID) -> Void
    private let header = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let splitButton: PaneHeaderButton
    private let closeButton: PaneHeaderButton
    private let borderLayer = CALayer()
    private var contentContainer = NSView()

    var title: String {
        get { titleLabel.stringValue }
        set { titleLabel.stringValue = newValue }
    }

    var titleColor: NSColor {
        get { titleLabel.textColor ?? .labelColor }
        set { titleLabel.textColor = newValue }
    }

    var badge: String {
        get { badgeLabel.stringValue }
        set { badgeLabel.stringValue = newValue }
    }

    var badgeColor: NSColor {
        get { badgeLabel.textColor ?? .secondaryLabelColor }
        set { badgeLabel.textColor = newValue }
    }

    var headerBackground: NSColor = .windowBackgroundColor {
        didSet {
            header.layer?.backgroundColor = headerBackground.cgColor
        }
    }

    var chromeBackground: NSColor = .windowBackgroundColor {
        didSet {
            layer?.backgroundColor = chromeBackground.cgColor
        }
    }

    override var isFlipped: Bool { true }

    init(
        paneID: PaneID,
        isFocused: Bool,
        activeColor: NSColor,
        inactiveColor: NSColor,
        chromeBackground: NSColor,
        onFocus: @escaping @MainActor (PaneID) -> Void,
        onSplit: @escaping @MainActor (PaneID) -> Void,
        onClose: @escaping @MainActor (PaneID) -> Void
    ) {
        self.paneID = paneID
        self.isFocused = isFocused
        self.activeColor = activeColor
        self.inactiveColor = inactiveColor
        self.onFocus = onFocus
        self.onSplit = onSplit
        self.onClose = onClose
        self.splitButton = PaneHeaderButton(glyph: "+", accessibilityLabel: "Split pane right")
        self.closeButton = PaneHeaderButton(glyph: "×", accessibilityLabel: "Close pane")
        super.init(frame: .zero)
        self.chromeBackground = chromeBackground

        wantsLayer = true
        layer?.backgroundColor = chromeBackground.cgColor

        borderLayer.borderWidth = 1
        borderLayer.borderColor = (isFocused ? activeColor : inactiveColor).cgColor
        borderLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(borderLayer)

        header.wantsLayer = true
        header.layer?.backgroundColor = headerBackground.cgColor
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        titleLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: isFocused ? .semibold : .regular)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titleLabel)
        header.addSubview(badgeLabel)

        splitButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
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

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentContainer)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 26),

            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            badgeLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            // Buttons sit at the trailing edge; badge sits to their left.
            closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),

            splitButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            splitButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            splitButton.widthAnchor.constraint(equalToConstant: 18),
            splitButton.heightAnchor.constraint(equalToConstant: 18),

            badgeLabel.trailingAnchor.constraint(equalTo: splitButton.leadingAnchor, constant: -8),

            contentContainer.topAnchor.constraint(equalTo: header.bottomAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    /// Push theme-derived button colors down to the header buttons. Called
    /// after `init` so the builder can pull all colors from `ThemeSpec` once.
    func applyButtonColors(idle: NSColor, hover: NSColor, hoverBackground: NSColor) {
        splitButton.configure(idleColor: idle, hoverColor: hover, hoverBackground: hoverBackground)
        closeButton.configure(idleColor: idle, hoverColor: hover, hoverBackground: hoverBackground)
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

    // Click anywhere on the chrome (border or header) to focus this pane.
    override func mouseDown(with event: NSEvent) {
        onFocus(paneID)
        super.mouseDown(with: event)
    }
}

// MARK: - Header buttons

/// Small square button for the pane header (`+` split, `×` close).
///
/// Implemented as a custom `NSView` rather than `NSButton` so we get a
/// minimal, theme-driven appearance: no system focus ring, no system
/// background, and an explicit hover state we drive from
/// `mouseEntered`/`mouseExited`.
///
/// `mouseDown` is consumed locally — it never reaches `PaneShellNSView`,
/// so clicking a button doesn't also trigger the pane's focus handler
/// (the split / close action implies focus where it matters).
private final class PaneHeaderButton: NSView {
    var onClick: (@MainActor () -> Void)?

    private let label = NSTextField(labelWithString: "")
    private var idleColor: NSColor = .secondaryLabelColor
    private var hoverColor: NSColor = .labelColor
    private var hoverBackground: NSColor = NSColor.white.withAlphaComponent(0.1)
    private var trackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet { refreshAppearance() }
    }

    override var isFlipped: Bool { true }
    // The button refuses focus by returning false here; `refusesFirstResponder`
    // is not an `NSView` property (only `NSResponder` and some subclasses
    // expose it), so we only override the one that exists.
    override var acceptsFirstResponder: Bool { false }

    init(glyph: String, accessibilityLabel: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 3
        layer?.backgroundColor = NSColor.clear.cgColor

        label.stringValue = glyph
        label.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isEditable = false
        label.isSelectable = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            // Optical centering: the `×` and `+` glyphs sit slightly low
            // in the cap-height box of the system mono font.
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
        refreshAppearance()
    }

    private func refreshAppearance() {
        label.textColor = isHovering ? hoverColor : idleColor
        layer?.backgroundColor = (isHovering ? hoverBackground : NSColor.clear).cgColor
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
        // Track press-then-release inside bounds so dragging away cancels,
        // matching standard button behavior.
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

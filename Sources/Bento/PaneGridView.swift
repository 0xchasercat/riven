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

    init(
        theme: ThemeSpec,
        paneGraph: PaneGraph,
        projectRoot: String,
        fileMap: PaneFileMap,
        agentClient: AgentClient?,
        onGraphChange: @escaping (PaneGraph) -> Void = { _ in }
    ) {
        self.theme = theme
        self.paneGraph = paneGraph
        self.projectRoot = projectRoot
        self.fileMap = fileMap
        self.agentClient = agentClient
        self.onGraphChange = onGraphChange
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
            onGraphChange: onGraphChange
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
            onGraphChange: onGraphChange
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

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BentoPaneContainerView does not support NSCoder")
    }

    func apply(
        graph: PaneGraph,
        theme: ThemeSpec,
        projectRoot: String,
        fileMap: PaneFileMap,
        agentClient: AgentClient?,
        onGraphChange: @escaping (PaneGraph) -> Void
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
            }
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

    private func splitFocused(_ direction: SplitDirection) {
        guard let graph = currentGraph else { return }
        let next = graph.splittingInheriting(graph.focusedPaneID, direction: direction)
        if next != graph { onGraphChange?(next) }
    }

    private func closeFocused() {
        guard let graph = currentGraph else { return }
        if let next = graph.close(graph.focusedPaneID), next != graph {
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

    func build(node: PaneNode) -> NSView {
        switch node {
        case let .leaf(id):
            return makeLeaf(id: id)
        case let .split(direction, first, second):
            return makeSplit(direction: direction, first: build(node: first), second: build(node: second))
        }
    }

    private func makeSplit(direction: SplitDirection, first: NSView, second: NSView) -> NSSplitView {
        let split = BentoSplitView()
        split.isVertical = (direction == .right) // .right == side-by-side == vertical divider
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(first)
        split.addArrangedSubview(second)
        // Default to a 50/50 split. NSSplitView restores the divider when
        // the user drags it, but a freshly built tree starts even.
        DispatchQueue.main.async { [weak split] in
            guard let split, split.arrangedSubviews.count == 2 else { return }
            let total = split.isVertical ? split.bounds.width : split.bounds.height
            if total > 0 {
                split.setPosition((total - split.dividerThickness) / 2, ofDividerAt: 0)
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
            onFocus: onFocus
        )
        shell.installContent(host.view)
        shell.title = pane?.name ?? "pane"
        shell.titleColor = NSColor(hex: theme.chrome.text.hex)
        shell.headerBackground = NSColor(hex: theme.chrome.background.hex)
        shell.badge = badge(for: pane)
        shell.badgeColor = NSColor(hex: theme.chrome.dimText.hex)
        return shell
    }

    private func badge(for pane: PaneDescriptor?) -> String {
        switch pane?.kind {
        case .editor: return "STTextView"
        case .terminal: return "libghostty"
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
    private let header = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
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
        onFocus: @escaping @MainActor (PaneID) -> Void
    ) {
        self.paneID = paneID
        self.isFocused = isFocused
        self.activeColor = activeColor
        self.inactiveColor = inactiveColor
        self.onFocus = onFocus
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

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentContainer)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 26),

            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            badgeLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            badgeLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            contentContainer.topAnchor.constraint(equalTo: header.bottomAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
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

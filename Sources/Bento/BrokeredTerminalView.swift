import AppKit
import BentoCore
import CoreText
import Darwin
import Foundation
import GhosttyVt

/// PTY-backed terminal NSView that talks to the out-of-process `BentoAgent`
/// broker via `AgentClient` instead of owning a `LivePseudoTerminal`
/// directly.
///
/// Public surface mirrors `GhosttyTerminalView` so the SwiftUI wrapper
/// (`TerminalPaneView`) can swap one for the other:
///   - `Configuration` controls colors / font.
///   - `ShellSpec` describes which executable + args + cwd to run.
///   - `paneID` is the stable identity used by the broker. Reusing the
///     same `paneID` across UI relaunches lets the broker replay its
///     ring buffer onto the new view.
///
/// On `viewDidMoveToWindow` the view:
///   1. Creates a Ghostty VT terminal for local rendering.
///   2. Asks the broker to create the pane (best-effort — if the pane
///      already exists on the agent, that error is benign and we just
///      attach to it).
///   3. Subscribes to the pane's output stream. The broker first emits a
///      single replay chunk drawn from its ring buffer, then live PTY
///      output. Both are fed into the same Ghostty terminal, so the
///      grid catches up with whatever the shell rendered before the UI
///      came back.
///   4. Forwards keyboard input via `AgentClient.writeInput` and resize
///      events via `AgentClient.resize`.
///
/// On `viewDidMoveToWindow(nil)` the view cancels its subscription task
/// and frees the local Ghostty handle. The broker keeps the PTY alive,
/// so attaching a fresh `BrokeredTerminalView` with the same `paneID`
/// will reattach.
@MainActor
public final class BrokeredTerminalView: NSView {

    // MARK: - Public configuration

    /// Same shape as `GhosttyTerminalView.Configuration` so callers can
    /// swap the two views without touching their config plumbing.
    public struct Configuration: Sendable {
        public var foreground: NSColor
        public var background: NSColor
        public var cursor: NSColor
        public var fontSize: CGFloat
        public var fontName: String?

        public init(
            foreground: NSColor = .white,
            background: NSColor = NSColor(white: 0.07, alpha: 1.0),
            cursor: NSColor = NSColor(calibratedRed: 0.4, green: 0.85, blue: 1.0, alpha: 1.0),
            fontSize: CGFloat = 13,
            fontName: String? = nil
        ) {
            self.foreground = foreground
            self.background = background
            self.cursor = cursor
            self.fontSize = fontSize
            self.fontName = fontName
        }
    }

    /// PTY-side configuration (forwarded to the broker via createPane).
    public struct ShellSpec: Sendable {
        public var executable: String
        public var arguments: [String]
        public var cwd: String
        public var environment: [String: String]

        public init(
            executable: String = "/bin/zsh",
            arguments: [String] = ["-il"],
            cwd: String = NSHomeDirectory(),
            environment: [String: String] = [:]
        ) {
            self.executable = executable
            self.arguments = arguments
            self.cwd = cwd
            self.environment = environment
        }
    }

    public private(set) var configuration: Configuration
    private let shellSpec: ShellSpec
    private let paneID: PaneID
    private let agentClient: AgentClient

    // MARK: - Internal state

    private let bridge = GhosttyBridge()
    private var session: GhosttySessionHandle?
    private var subscriptionTask: Task<Void, Never>?

    private var cellWidth: CGFloat = 8
    private var cellHeight: CGFloat = 16
    private var ascent: CGFloat = 12
    private var font: NSFont

    private var cols: UInt16 = 80
    private var rows: UInt16 = 24

    private var textAttributes: [NSAttributedString.Key: Any] = [:]

    // MARK: - Init

    /// Build a brokered terminal view. The pane is created on the broker
    /// when the view is added to a window. Until then this is just an
    /// `NSView`.
    public init(
        frame: NSRect = .zero,
        paneID: PaneID = PaneID(),
        shell: ShellSpec = ShellSpec(),
        configuration: Configuration = Configuration(),
        agentClient: AgentClient
    ) {
        self.paneID = paneID
        self.shellSpec = shell
        self.configuration = configuration
        self.agentClient = agentClient
        self.font = Self.resolveFont(name: configuration.fontName, size: configuration.fontSize)
        super.init(frame: frame)
        self.wantsLayer = true
        self.layer?.backgroundColor = configuration.background.cgColor
        recomputeCellMetrics()
        rebuildAttributes()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrokeredTerminalView does not support NSCoder")
    }

    deinit {
        // `deinit` is nonisolated. We can cancel the task and free the
        // Ghostty handle (Sendable) without hopping back to MainActor;
        // the broker keeps the underlying PTY around regardless.
        subscriptionTask?.cancel()
        if let session {
            try? bridge.close(session)
        }
    }

    // MARK: - Configuration

    public func configure(_ configuration: Configuration) {
        self.configuration = configuration
        self.font = Self.resolveFont(name: configuration.fontName, size: configuration.fontSize)
        self.layer?.backgroundColor = configuration.background.cgColor
        recomputeCellMetrics()
        rebuildAttributes()
        applyResizeIfNeeded(forceRedraw: true)
        needsDisplay = true
    }

    private static func resolveFont(name: String?, size: CGFloat) -> NSFont {
        if let name, let f = NSFont(name: name, size: size) { return f }
        if let sfMono = NSFont(name: "SFMono-Regular", size: size) { return sfMono }
        if let menlo = NSFont(name: "Menlo", size: size) { return menlo }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private func recomputeCellMetrics() {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let probe = NSAttributedString(string: "M", attributes: attrs)
        let line = CTLineCreateWithAttributedString(probe)
        var asc: CGFloat = 0
        var desc: CGFloat = 0
        var leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &asc, &desc, &leading)
        cellWidth = max(1, CGFloat(width))
        cellHeight = max(1, ceil(asc + desc + leading))
        ascent = asc
    }

    private func rebuildAttributes() {
        textAttributes = [
            .font: font,
            .foregroundColor: configuration.foreground,
        ]
    }

    // MARK: - NSView overrides

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func becomeFirstResponder() -> Bool { true }
    public override func resignFirstResponder() -> Bool { true }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startIfNeeded()
        } else {
            teardown()
        }
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyResizeIfNeeded(forceRedraw: false)
    }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        applyResizeIfNeeded(forceRedraw: true)
    }

    // MARK: - Startup / teardown

    private func startIfNeeded() {
        guard session == nil else { return }
        let (c, r) = computeGridSize(for: bounds.size)
        cols = c
        rows = r

        let handle: GhosttySessionHandle
        do {
            handle = try bridge.createSession(
                id: paneID,
                cwd: shellSpec.cwd,
                command: nil,
                cols: cols,
                rows: rows
            )
            try bridge.resize(
                handle,
                columns: Int(cols),
                rows: Int(rows),
                cellWidthPx: UInt32(max(1, cellWidth.rounded())),
                cellHeightPx: UInt32(max(1, cellHeight.rounded()))
            )
        } catch {
            NSLog("BrokeredTerminalView: failed to create Ghostty session: \(error)")
            return
        }
        self.session = handle

        subscriptionTask = Task { [weak self] in
            await self?.runBrokerLoop()
        }
    }

    /// One round-trip with the broker: ensure the pane exists, then keep
    /// pumping output into the local Ghostty terminal until the
    /// subscription stream finishes (pane exits, connection drops, view
    /// torn down).
    private func runBrokerLoop() async {
        let client = agentClient
        let spec = shellSpec
        let id = paneID
        let initialCols = cols
        let initialRows = rows

        // Best-effort createPane. If the pane already exists on the
        // broker (e.g. UI relaunched), the error is benign — we'll
        // attach via subscribe. Any other server error short-circuits
        // the loop.
        do {
            _ = try await client.createPane(
                paneID: id,
                command: spec.executable,
                args: spec.arguments,
                cwd: spec.cwd,
                columns: initialCols,
                rows: initialRows,
                env: spec.environment
            )
        } catch let AgentClient.ClientError.server(err) where err.code == "already_exists" {
            // Reattach path — fine.
        } catch {
            NSLog("BrokeredTerminalView: createPane failed: \(error)")
            return
        }

        let stream: AsyncThrowingStream<IPCEvent, Error>
        do {
            stream = try await client.subscribe(paneID: id)
        } catch {
            NSLog("BrokeredTerminalView: subscribe failed: \(error)")
            return
        }

        do {
            for try await event in stream {
                if Task.isCancelled { break }
                switch event {
                case let .output(_, data):
                    self.feedOutput(data)
                case .exited:
                    return
                }
            }
        } catch {
            // Stream ended (typically: client closed). Nothing to do —
            // the next view that attaches with this paneID will get a
            // fresh replay from the ring buffer.
        }
    }

    /// Feed broker output into the local Ghostty terminal and request a
    /// repaint. Already on `@MainActor` because the whole view is.
    private func feedOutput(_ data: Data) {
        guard let session else { return }
        try? bridge.feed(data, to: session)
        needsDisplay = true
    }

    private func teardown() {
        subscriptionTask?.cancel()
        subscriptionTask = nil
        if let session {
            try? bridge.close(session)
        }
        session = nil
    }

    // MARK: - Resize

    private func computeGridSize(for size: NSSize) -> (UInt16, UInt16) {
        let c = max(1, Int(floor(size.width / max(1, cellWidth))))
        let r = max(1, Int(floor(size.height / max(1, cellHeight))))
        return (UInt16(min(c, Int(UInt16.max))), UInt16(min(r, Int(UInt16.max))))
    }

    private func applyResizeIfNeeded(forceRedraw: Bool) {
        let (newCols, newRows) = computeGridSize(for: bounds.size)
        guard newCols > 0, newRows > 0 else { return }
        let sizeChanged = (newCols != cols) || (newRows != rows)
        cols = newCols
        rows = newRows
        if let session {
            try? bridge.resize(
                session,
                columns: Int(cols),
                rows: Int(rows),
                cellWidthPx: UInt32(max(1, cellWidth.rounded())),
                cellHeightPx: UInt32(max(1, cellHeight.rounded()))
            )
        }
        if sizeChanged || forceRedraw {
            needsDisplay = true
            // Tell the broker about the new window size. Failures are
            // logged but non-fatal — the next resize will retry.
            let id = paneID
            let columns = cols
            let rowsCopy = rows
            let client = agentClient
            Task {
                do {
                    try await client.resize(paneID: id, columns: columns, rows: rowsCopy)
                } catch {
                    NSLog("BrokeredTerminalView: resize failed: \(error)")
                }
            }
        }
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        GhosttyRenderer.draw(
            bridge: bridge,
            session: session,
            bounds: bounds,
            ctx: ctx,
            style: GhosttyRenderer.Style(
                foreground: configuration.foreground,
                background: configuration.background,
                cursor: configuration.cursor
            ),
            textAttributes: textAttributes,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            ascent: ascent
        )
    }

    // MARK: - Keyboard input

    public override func keyDown(with event: NSEvent) {
        interpretKeyEvents([event])
    }

    public override func insertText(_ insertString: Any) {
        let bytes: [UInt8]
        if let str = insertString as? String {
            bytes = Array(str.utf8)
        } else if let attr = insertString as? NSAttributedString {
            bytes = Array(attr.string.utf8)
        } else {
            return
        }
        sendBytes(bytes)
    }

    public override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            sendBytes([0x0d])
        case #selector(NSResponder.insertTab(_:)):
            sendBytes([0x09])
        case #selector(NSResponder.insertBacktab(_:)):
            sendBytes([0x1b, 0x5b, 0x5a])
        case #selector(NSResponder.deleteBackward(_:)):
            sendBytes([0x7f])
        case #selector(NSResponder.deleteForward(_:)):
            sendBytes([0x1b, 0x5b, 0x33, 0x7e])
        case #selector(NSResponder.cancelOperation(_:)):
            sendBytes([0x1b])
        case #selector(NSResponder.moveLeft(_:)):
            sendBytes([0x1b, 0x5b, 0x44])
        case #selector(NSResponder.moveRight(_:)):
            sendBytes([0x1b, 0x5b, 0x43])
        case #selector(NSResponder.moveUp(_:)):
            sendBytes([0x1b, 0x5b, 0x41])
        case #selector(NSResponder.moveDown(_:)):
            sendBytes([0x1b, 0x5b, 0x42])
        case #selector(NSResponder.moveToBeginningOfLine(_:)),
             #selector(NSResponder.moveToLeftEndOfLine(_:)):
            sendBytes([0x01])
        case #selector(NSResponder.moveToEndOfLine(_:)),
             #selector(NSResponder.moveToRightEndOfLine(_:)):
            sendBytes([0x05])
        case #selector(NSResponder.deleteWordBackward(_:)):
            sendBytes([0x17])
        default:
            break
        }
    }

    private func sendBytes(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let data = Data(bytes)
        let id = paneID
        let client = agentClient
        Task {
            try? await client.writeInput(paneID: id, data: data)
        }
    }
}

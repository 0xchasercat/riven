import AppKit
import BentoCore
import CoreText
import Darwin
import Foundation
import GhosttyVt

/// A live `NSView` that owns a real PTY-backed shell, a `libghostty-vt`
/// terminal emulator, and a CoreText renderer.
///
/// Lifecycle:
///   1. `init(...)` constructs the view but does **not** spawn anything.
///   2. On `viewDidMoveToWindow` (window != nil) the view computes its
///      initial cell metrics, creates the Ghostty terminal, spawns the
///      PTY child, and starts the output pump.
///   3. PTY output streams asynchronously into `ghostty_terminal_vt_write`,
///      which mutates the grid; the view marks itself dirty and CoreText
///      re-renders.
///   4. Keyboard input from the view is written back into the PTY master.
///   5. Frame changes recompute (cols, rows), call `ghostty_terminal_resize`
///      and `ioctl(TIOCSWINSZ)` so the shell sees the new size.
///   6. `removeFromSuperview` / `viewDidMoveToWindow(nil)` tears down the
///      PTY and frees the terminal handle via `GhosttyBridge.close`.
///
/// Rendering today is intentionally minimal: monospaced (SFMono → Menlo
/// fallback), single foreground color, single background color. SGR styling,
/// truecolor, hyperlinks, kitty graphics, etc. are out of scope for this
/// slice but the grid-read path is structured to grow into them.
@MainActor
public final class GhosttyTerminalView: NSView {

    // MARK: - Public configuration

    /// Visual configuration. Mutate via `configure(_:)` to trigger a redraw.
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

    /// PTY-side configuration: which shell, with which args, in which cwd.
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

    // MARK: - Internal state

    private let bridge = GhosttyBridge()
    private var session: GhosttySessionHandle?
    private var pty: LivePseudoTerminal?
    private var pumpTask: Task<Void, Never>?

    /// Cached cell metrics derived from the active font. Updated whenever
    /// `configuration.fontSize` or `fontName` changes.
    private var cellWidth: CGFloat = 8
    private var cellHeight: CGFloat = 16
    private var ascent: CGFloat = 12
    private var font: NSFont

    /// Current (cols, rows). Updated on resize.
    private var cols: UInt16 = 80
    private var rows: UInt16 = 24

    /// Cached attributes used by the CoreText draw path.
    private var textAttributes: [NSAttributedString.Key: Any] = [:]

    // MARK: - Init

    /// Build a terminal view. The PTY and Ghostty terminal are created when
    /// the view is added to a window. Until then this is just an `NSView`.
    public init(
        frame: NSRect = .zero,
        paneID: PaneID = PaneID(),
        shell: ShellSpec = ShellSpec(),
        configuration: Configuration = Configuration()
    ) {
        self.paneID = paneID
        self.shellSpec = shell
        self.configuration = configuration
        self.font = Self.resolveFont(name: configuration.fontName, size: configuration.fontSize)
        super.init(frame: frame)
        self.wantsLayer = true
        self.layer?.backgroundColor = configuration.background.cgColor
        recomputeCellMetrics()
        rebuildAttributes()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GhosttyTerminalView does not support NSCoder")
    }

    deinit {
        // `deinit` is nonisolated, but all the resources we touch here are
        // either Sendable structs (`GhosttyBridge`) or `@unchecked Sendable`
        // reference types (`LivePseudoTerminal`, `Task`, `GhosttySessionHandle`).
        // No main-actor methods are called.
        pumpTask?.cancel()
        pty?.terminate()
        if let session {
            try? bridge.close(session)
        }
    }

    // MARK: - Configuration

    /// Replace the visual configuration and trigger a redraw / metrics update.
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
            NSLog("GhosttyTerminalView: failed to create Ghostty session: \(error)")
            return
        }
        self.session = handle

        let spec = LivePseudoTerminal.Spec(
            executable: shellSpec.executable,
            arguments: shellSpec.arguments,
            cwd: shellSpec.cwd,
            environment: shellSpec.environment,
            columns: cols,
            rows: rows
        )
        let pty = LivePseudoTerminal(spec: spec)
        do {
            try pty.start()
        } catch {
            NSLog("GhosttyTerminalView: failed to start PTY: \(error)")
            try? bridge.close(handle)
            self.session = nil
            return
        }
        self.pty = pty

        // Pump PTY output → Ghostty (on main actor so we don't race the
        // draw path or input writes against the C library).
        let stream = pty.output
        pumpTask = Task { [weak self] in
            for await chunk in stream {
                await MainActor.run {
                    guard let self else { return }
                    guard let session = self.session else { return }
                    try? self.bridge.feed(chunk, to: session)
                    self.needsDisplay = true
                }
                if Task.isCancelled { break }
            }
        }
    }

    private func teardown() {
        pumpTask?.cancel()
        pumpTask = nil
        pty?.terminate()
        pty = nil
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
        pty?.resize(columns: cols, rows: rows)
        if sizeChanged || forceRedraw {
            needsDisplay = true
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
        // Let the input system handle character composition (insertText:)
        // first; if it doesn't consume it, fall through to raw-byte handling
        // for control keys via doCommand(by:).
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
            sendBytes([0x1b, 0x5b, 0x5a]) // ESC [ Z
        case #selector(NSResponder.deleteBackward(_:)):
            sendBytes([0x7f])
        case #selector(NSResponder.deleteForward(_:)):
            sendBytes([0x1b, 0x5b, 0x33, 0x7e]) // ESC [ 3 ~
        case #selector(NSResponder.cancelOperation(_:)):
            sendBytes([0x1b])
        case #selector(NSResponder.moveLeft(_:)):
            sendBytes([0x1b, 0x5b, 0x44]) // ESC [ D
        case #selector(NSResponder.moveRight(_:)):
            sendBytes([0x1b, 0x5b, 0x43]) // ESC [ C
        case #selector(NSResponder.moveUp(_:)):
            sendBytes([0x1b, 0x5b, 0x41]) // ESC [ A
        case #selector(NSResponder.moveDown(_:)):
            sendBytes([0x1b, 0x5b, 0x42]) // ESC [ B
        case #selector(NSResponder.moveToBeginningOfLine(_:)),
             #selector(NSResponder.moveToLeftEndOfLine(_:)):
            sendBytes([0x01]) // ctrl-a
        case #selector(NSResponder.moveToEndOfLine(_:)),
             #selector(NSResponder.moveToRightEndOfLine(_:)):
            sendBytes([0x05]) // ctrl-e
        case #selector(NSResponder.deleteWordBackward(_:)):
            sendBytes([0x17]) // ctrl-w
        default:
            break
        }
    }

    private func sendBytes(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        pty?.write(Data(bytes))
    }
}

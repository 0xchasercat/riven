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
        /// H1: multiplier applied to the typographic line height to add
        /// inter-line breathing room. 1.0 is the tight CoreText default
        /// (`ceil(asc + desc + leading)`); 1.15 matches Warp's resting
        /// "comfortable" setting and is the Bento default. The glyph
        /// baseline stays centered inside the bumped cell so the extra
        /// gutter lands evenly above + below each row of text — cursor,
        /// underline, overline all derive from `cellHeight` / `ascent`
        /// so they scale with this value automatically.
        public var lineHeightMultiplier: CGFloat

        public init(
            foreground: NSColor = .white,
            background: NSColor = NSColor(white: 0.07, alpha: 1.0),
            cursor: NSColor = NSColor(calibratedRed: 0.4, green: 0.85, blue: 1.0, alpha: 1.0),
            fontSize: CGFloat = 13,
            fontName: String? = nil,
            lineHeightMultiplier: CGFloat = 1.15
        ) {
            self.foreground = foreground
            self.background = background
            self.cursor = cursor
            self.fontSize = fontSize
            self.fontName = fontName
            self.lineHeightMultiplier = lineHeightMultiplier
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

    /// Fired when the shell's reported current working directory changes
    /// (via OSC 7). Called on the main actor. See `lastReportedCwd` below
    /// for the dedupe behaviour.
    public var onCwdChanged: (String) -> Void

    // MARK: - Internal state

    private let bridge = GhosttyBridge()
    private var session: GhosttySessionHandle?
    private var subscriptionTask: Task<Void, Never>?

    /// Last cwd value we surfaced via `onCwdChanged`. We only fire the
    /// callback when the new value is non-nil *and* differs from this. A
    /// `nil` read from `readCurrentCwd` means "no OSC 7 received yet" —
    /// we leave the previous value in place rather than resetting the
    /// sidebar to nothing.
    private var lastReportedCwd: String?

    private var cellWidth: CGFloat = 8
    private var cellHeight: CGFloat = 16
    private var ascent: CGFloat = 12
    private var font: NSFont

    private var cols: UInt16 = 80
    private var rows: UInt16 = 24

    private var textAttributes: [NSAttributedString.Key: Any] = [:]

    /// Timer that ticks `needsDisplay = true` while blink cells are on
    /// screen so the next draw can swap the alpha. Lazily started by
    /// `draw(_:)` when it sees blink content, lazily stopped when no
    /// blink content is present. nil = not running.
    ///
    /// `nonisolated(unsafe)` because `deinit` (nonisolated) needs to
    /// invalidate it and Timer isn't Sendable. `Timer.invalidate()` is
    /// documented to be safe from any thread, and the only mutator
    /// (`syncBlinkTimer`) is main-actor-isolated.
    private nonisolated(unsafe) var blinkTimer: Timer?
    /// Half-cycle duration for SGR 5 / 6 blink. 500 ms matches xterm
    /// and Warp; <300 ms reads as flicker, >1 s feels broken.
    private static let blinkHalfCycle: TimeInterval = 0.5

    /// H2: padding baked into the terminal view so the leftmost glyph
    /// doesn't sit flush against the pane chrome. The terminal
    /// background still fills the view edge-to-edge (so the dark
    /// surface meets the divider); only the cell grid is inset.
    /// Bottom is 0 because the command bar's own divider already
    /// closes the bottom edge of the terminal area.
    private static let textInset = NSEdgeInsets(top: 8, left: 12, bottom: 0, right: 12)

    // MARK: - Init

    /// Build a brokered terminal view. The pane is created on the broker
    /// when the view is added to a window. Until then this is just an
    /// `NSView`.
    public init(
        frame: NSRect = .zero,
        paneID: PaneID = PaneID(),
        shell: ShellSpec = ShellSpec(),
        configuration: Configuration = Configuration(),
        agentClient: AgentClient,
        onCwdChanged: @escaping (String) -> Void = { _ in }
    ) {
        self.paneID = paneID
        self.shellSpec = shell
        self.configuration = configuration
        self.agentClient = agentClient
        self.onCwdChanged = onCwdChanged
        self.font = Self.resolveFont(name: configuration.fontName, size: configuration.fontSize)
        super.init(frame: frame)
        self.wantsLayer = true
        self.layer?.backgroundColor = configuration.background.cgColor
        recomputeCellMetrics()
        rebuildAttributes()

        // H-11: force a synchronous redraw on system wake. Without
        // this, a long sleep leaves the renderer holding the
        // pre-sleep snapshot until the next mouse move or PTY event
        // — visible as a stale frame for several seconds.
        wakeObserver = NotificationCenter.default.addObserver(
            forName: .bentoSystemDidWake,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.needsDisplay = true
                self?.displayIfNeeded()
            }
        }
    }

    private nonisolated(unsafe) var wakeObserver: NSObjectProtocol?

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrokeredTerminalView does not support NSCoder")
    }

    deinit {
        // `deinit` is nonisolated. We can cancel the task and free the
        // Ghostty handle (Sendable) without hopping back to MainActor;
        // the broker keeps the underlying PTY around regardless.
        subscriptionTask?.cancel()
        // `blinkTimer` is main-actor-isolated state; the only way it
        // exists is if `startBlinkTimerIfNeeded` ran. By the time we
        // hit deinit no one is keeping the view alive so the timer's
        // weak self capture will already be releasing on next tick —
        // explicit invalidate keeps it from firing once after deinit.
        blinkTimer?.invalidate()
        if let wakeObserver {
            NotificationCenter.default.removeObserver(wakeObserver)
        }
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
        // H1: bump the cell height by the configured line-height
        // multiplier (default 1.15) so glyphs get inter-line breathing
        // room. The tight typographic height (`tightHeight`) is what
        // CoreText needs to lay a single line out cleanly; the extra
        // gutter is distributed evenly above + below by shifting the
        // ascent we hand to the renderer. The renderer positions
        // baselines as `yTop + ascent`, so adding `extra/2` to the
        // ascent centers the typographic line within the bumped cell.
        let tightHeight = ceil(asc + desc + leading)
        let bumped = ceil(tightHeight * max(1, configuration.lineHeightMultiplier))
        cellHeight = max(1, bumped)
        let extra = max(0, cellHeight - tightHeight)
        ascent = asc + extra / 2
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

    /// Bento's focus model: the command bar is the default writing
    /// surface. A plain click on the terminal (no drag) bounces focus
    /// to the command bar via `.bentoFocusCommandBar`. A click + drag
    /// keeps focus on the terminal so future text-selection work has a
    /// place to land. Today we don't implement text selection, so the
    /// drag branch is reserved — every mouseDown bounces.
    public override func mouseDown(with event: NSEvent) {
        // Post immediately; the command bar listens on the same window.
        // No need to wait for mouseUp — the user's intent is clear from
        // the first click that the terminal pane is the target context.
        NotificationCenter.default.post(name: .bentoFocusCommandBar, object: nil)
        super.mouseDown(with: event)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Only START on window-attach. We deliberately do NOT teardown on
        // window-detach, because SwiftUI's NSHostingController briefly
        // moves views out of the window during ordinary updates (e.g.
        // when the workspace re-renders for a cwd change). Tearing down +
        // re-starting on every update would force the broker to replay
        // its entire ring buffer into a fresh Ghostty session each time,
        // producing visible prompt-stacking at the top of the grid.
        // The session is cleaned up properly in `deinit`.
        if window != nil {
            startIfNeeded()
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

        // H-10: if the user resized the window after the view
        // computed its initial grid size but before createPane
        // landed on the broker, the in-flight `applyResizeIfNeeded`
        // calls would have failed with `unknown_pane` and been
        // swallowed. Re-send the current grid size now that the
        // broker is guaranteed to know about this pane — same call
        // path as a normal resize. If `(cols, rows)` haven't
        // changed since construction this is a no-op; if they have,
        // the broker (and the child's TIOCSWINSZ) catch up to what
        // the user is actually looking at, with no input from the
        // user required.
        let liveCols = await MainActor.run { self.cols }
        let liveRows = await MainActor.run { self.rows }
        if liveCols != initialCols || liveRows != initialRows {
            try? await client.resize(paneID: id, columns: liveCols, rows: liveRows)
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
    ///
    /// Setting `needsDisplay = true` alone is fragile when the source
    /// of the update is a purely-async event (broker stream → for-await
    /// → feedOutput) and the window is otherwise idle: AppKit's display
    /// loop coalesces dirty rects and only flushes them when the
    /// runloop processes a UI event. If nothing moves the mouse and no
    /// other timer fires, the terminal sits stale until the user types
    /// or hovers — which is the exact "doesn't refresh until I do
    /// something" bug. `displayIfNeeded()` pumps the redraw
    /// synchronously on the next CATransaction commit so each output
    /// chunk lands on screen immediately.
    private func feedOutput(_ data: Data) {
        guard let session else { return }
        try? bridge.feed(data, to: session)
        needsDisplay = true
        displayIfNeeded()
    }

    /// Pull the shell's OSC 7 cwd from the Ghostty bridge and, if it
    /// genuinely changed since the last report, fire `onCwdChanged`.
    ///
    /// Dedupe contract:
    ///   - `nil` (no OSC 7 received yet) means "no change", not "reset
    ///     to nothing" — keep the previously reported value in place so
    ///     the sidebar doesn't go blank before the shell prints its
    ///     first prompt.
    ///   - We only fire when the new non-nil value differs from
    ///     `lastReportedCwd`. Hammering the callback every frame would
    ///     thrash the workspace controller's persistence + the
    ///     sidebar's file-tree scan.
    ///
    /// Called from `draw(_:)` so we already hold the main actor. The
    /// callback runs synchronously inside the draw pass; the orchestrator
    /// is responsible for any deferred work it needs (e.g. dispatching
    /// model mutations off the render).
    private func reportCwdIfChanged(on session: GhosttySessionHandle) {
        guard let newCwd = try? bridge.readCurrentCwd(session),
              !newCwd.isEmpty,
              newCwd != lastReportedCwd
        else { return }
        lastReportedCwd = newCwd
        onCwdChanged(newCwd)
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
        // H2: subtract the baked text inset before deriving the cell
        // count so the grid sizes against the area the renderer can
        // actually paint into, not the full pane.
        let inset = Self.textInset
        let usableWidth = max(0, size.width - inset.left - inset.right)
        let usableHeight = max(0, size.height - inset.top - inset.bottom)
        let c = max(1, Int(floor(usableWidth / max(1, cellWidth))))
        let r = max(1, Int(floor(usableHeight / max(1, cellHeight))))
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
                } catch let AgentClient.ClientError.server(err) where err.code == "unknown_pane" {
                    // Transient: `createPane` is still in flight. The next
                    // layout pass / live-resize end will retry with the
                    // current dimensions and succeed once the broker
                    // catches up. Swallow silently — surfacing this as a
                    // log line is just noise.
                } catch {
                    NSLog("BrokeredTerminalView: resize failed: \(error)")
                }
            }
        }
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Snapshot the live terminal via the libghostty-vt render-state
        // API. The broker streams PTY bytes into our local Ghostty
        // session, so the same snapshot path works whether terminals
        // live in-process or out-of-process.
        let frame: GhosttyRenderFrame
        if let session, let live = try? bridge.snapshotFrame(session) {
            frame = live
            // Piggy-back on the snapshot to read the shell's OSC 7 cwd.
            // The read is cheap (a single libghostty call returning a
            // borrowed pointer copied into Swift) and only matters when
            // it actually changes — see `reportCwdIfChanged` for dedupe.
            reportCwdIfChanged(on: session)
        } else {
            frame = GhosttyRenderFrame.empty(cols: cols, rows: rows)
        }

        // H2: paint the terminal background edge-to-edge so the dark
        // surface meets the surrounding pane chrome with no gutter.
        // The renderer will paint its own (inset) bounds over the top,
        // but that just repaints the same color across the smaller
        // rect — no visual difference, and it keeps the renderer
        // self-contained.
        ctx.setFillColor(configuration.background.cgColor)
        ctx.fill(bounds)

        // SGR 5/6 blink: arm a self-redraw timer while blink cells are
        // on screen, and compute the current alpha from the wall clock.
        // No blink content → no timer → zero CPU.
        let hasBlink = frame.hasBlinkingContent
        let blinkAlpha: CGFloat = hasBlink ? Self.currentBlinkAlpha() : 1.0
        syncBlinkTimer(active: hasBlink)

        // H2: shift the renderer's coordinate space to the inset
        // origin and shrink its bounds to the inset rect. The renderer
        // paints cells at `col * cellWidth` starting at x=0, so
        // translating here is the cleanest way to inset every glyph,
        // cursor, separator, and decoration in one shot.
        let inset = Self.textInset
        let insetBounds = NSRect(
            x: 0,
            y: 0,
            width: max(0, bounds.width - inset.left - inset.right),
            height: max(0, bounds.height - inset.top - inset.bottom)
        )
        ctx.saveGState()
        ctx.translateBy(x: inset.left, y: inset.top)

        GhosttyRenderer.draw(
            frame: frame,
            configuration: GhosttyRenderer.TerminalRenderConfiguration(
                defaultForeground: configuration.foreground,
                defaultBackground: configuration.background,
                cursorColor: configuration.cursor,
                fontSize: configuration.fontSize,
                fontName: configuration.fontName,
                blinkAlpha: blinkAlpha
            ),
            metrics: GhosttyRenderer.TerminalCellMetrics(
                cellWidth: cellWidth,
                cellHeight: cellHeight,
                ascent: ascent
            ),
            in: ctx,
            bounds: insetBounds
        )

        ctx.restoreGState()
    }

    // MARK: - Blink animation

    /// Wall-clock-driven blink alpha. The half-cycle is `blinkHalfCycle`
    /// (500 ms); during the ON phase the value is 1.0, during the OFF
    /// phase it's 0.3 (matches what xterm and Warp settle on — fully
    /// invisible is illegible, fully visible is no animation). Using a
    /// shared clock means adjacent panes blink in phase, which reads
    /// cleaner than each pane running its own random offset.
    private static func currentBlinkAlpha() -> CGFloat {
        let t = Date().timeIntervalSinceReferenceDate
        let phase = Int(floor(t / blinkHalfCycle))
        return (phase % 2 == 0) ? 1.0 : 0.3
    }

    /// Arm or disarm the blink redraw timer to match `active`. Idempotent
    /// — calling with the same state in a row is a no-op so `draw(_:)`
    /// can invoke it on every paint without ceremony.
    private func syncBlinkTimer(active: Bool) {
        if active {
            guard blinkTimer == nil else { return }
            // Tick at the same cadence as the half-cycle so each tick
            // straddles exactly one phase boundary; this guarantees the
            // alpha visibly changes on every redraw and we don't waste
            // a frame on a redraw that paints the same value as before.
            let timer = Timer(timeInterval: Self.blinkHalfCycle, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.needsDisplay = true
                }
            }
            // Use .common mode so the redraw still fires while the user
            // is in a tracking loop (live-resize, menu open). Default
            // mode would stall the animation in those cases.
            RunLoop.main.add(timer, forMode: .common)
            blinkTimer = timer
        } else {
            blinkTimer?.invalidate()
            blinkTimer = nil
        }
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

import AppKit
import RivenCore
import CoreText
import Darwin
import Foundation
import GhosttyVt

/// PTY-backed terminal NSView that talks to the out-of-process `RivenAgent`
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
    public struct Configuration: Sendable, Equatable {
        public var foreground: NSColor
        public var background: NSColor
        public var cursor: NSColor
        public var fontSize: CGFloat
        public var fontName: String?
        /// H1: multiplier applied to the typographic line height to add
        /// inter-line breathing room. 1.0 is the tight CoreText default
        /// (`ceil(asc + desc + leading)`); 1.15 matches Warp's resting
        /// "comfortable" setting and is the Riven default. The glyph
        /// baseline stays centered inside the bumped cell so the extra
        /// gutter lands evenly above + below each row of text — cursor,
        /// underline, overline all derive from `cellHeight` / `ascent`
        /// so they scale with this value automatically.
        public var lineHeightMultiplier: CGFloat
        /// Translucent fill used to highlight cells under the active
        /// text selection. Sourced from `theme.chrome.selectionBg`
        /// (the 8-digit alpha-bearing hex token added in T-1) so the
        /// highlight automatically matches whatever theme is active —
        /// Amber's warm amber-22%, Tokyo's electric-violet-15%, etc.
        /// Defaults to white@15% so the selection still renders if a
        /// caller forgets to thread the theme color through.
        public var selectionBackground: NSColor

        public init(
            foreground: NSColor = .white,
            background: NSColor = NSColor(white: 0.07, alpha: 1.0),
            cursor: NSColor = NSColor(calibratedRed: 0.4, green: 0.85, blue: 1.0, alpha: 1.0),
            fontSize: CGFloat = 13,
            fontName: String? = nil,
            lineHeightMultiplier: CGFloat = 1.15,
            selectionBackground: NSColor = NSColor(white: 1.0, alpha: 0.15)
        ) {
            self.foreground = foreground
            self.background = background
            self.cursor = cursor
            self.fontSize = fontSize
            self.fontName = fontName
            self.lineHeightMultiplier = lineHeightMultiplier
            self.selectionBackground = selectionBackground
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

    /// Drag-to-select state. `dragAnchor` is set on mouseDown; the
    /// active `selection` updates on mouseDragged and survives mouseUp
    /// so the user can Cmd+C the result. A plain click (no drag past
    /// `dragThresholdPx`) clears the selection on mouseUp and bounces
    /// focus to the command bar — the longstanding Riven gesture for
    /// "I want to type a new command, not interact with the buffer."
    private var dragAnchor: CellCoord?
    private var dragDidMove: Bool = false
    private(set) var selection: TerminalSelection?
    /// Minimum pixel movement before a mouseDown promotes to a drag.
    /// 3 px matches macOS-wide click-vs-drag conventions and avoids
    /// "fingertip drift" registering as a 1-cell phantom selection.
    private static let dragThresholdPx: CGFloat = 3

    /// Cell coordinate in grid space. (0, 0) is top-left.
    struct CellCoord: Equatable {
        let row: Int
        let col: Int
    }

    /// True iff the underlying terminal is currently on the alt
    /// screen (vim, nano, less, htop, claude-code, …). Cached and
    /// refreshed on every snapshot in `draw(_:)`. Used as the gate
    /// for Riven's "click bounces to command bar" + "Tab snaps to
    /// command bar" behaviors — neither applies inside a fullscreen
    /// TUI, where keystrokes + mouse have to flow to the program.
    ///
    /// Default false so the bounce-to-bar UX is preserved any time
    /// we don't have a live session to query.
    private(set) var isInAltScreen: Bool = false

    /// Half-open range describing the active text selection. Stored
    /// in the order the user dragged so a backward drag selects the
    /// same text as a forward one (we normalize for rendering / copy).
    struct TerminalSelection: Equatable {
        var anchor: CellCoord
        var head: CellCoord

        /// Top-left / bottom-right of the selection in reading order.
        var ordered: (start: CellCoord, end: CellCoord) {
            if anchor.row < head.row || (anchor.row == head.row && anchor.col <= head.col) {
                return (anchor, head)
            }
            return (head, anchor)
        }
    }

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
            forName: .rivenSystemDidWake,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.needsDisplay = true
                self?.displayIfNeeded()
            }
        }

        // Window-becomes-key → restore first-responder when the
        // notification carries our own paneID. The app delegate
        // only fires this when the focused tab is on the alt screen
        // (vim, nano, etc.) so a regular shell-prompt click doesn't
        // get hijacked.
        focusRestoreObserver = NotificationCenter.default.addObserver(
            forName: .rivenRestoreTerminalFocus,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Copy the typed payload out before crossing the actor
            // hop — `note` itself is Sendable-suspicious so we read
            // its object on the calling queue (main, set above) and
            // pass the value-typed PaneID into the assumeIsolated
            // block. PaneID is a struct of a String, Sendable.
            let target = note.object as? PaneID
            MainActor.assumeIsolated {
                guard let self,
                      let target,
                      target == self.paneID else { return }
                self.window?.makeFirstResponder(self)
            }
        }
    }

    private nonisolated(unsafe) var wakeObserver: NSObjectProtocol?
    private nonisolated(unsafe) var focusRestoreObserver: NSObjectProtocol?

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
        if let focusRestoreObserver {
            NotificationCenter.default.removeObserver(focusRestoreObserver)
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

    /// Riven's focus model: the command bar is the default writing
    /// surface. A plain click on the terminal (no drag past
    /// `dragThresholdPx`) bounces focus to the command bar via
    /// `.rivenFocusCommandBar` on mouseUp. A click + drag enters
    /// text-selection mode — the renderer paints a translucent
    /// `theme.chrome.selectionBg` overlay across the selected cells
    /// and Cmd+C copies the text.
    ///
    /// We deliberately wait for mouseUp before bouncing focus so a
    /// drag-to-select gesture doesn't flash the cursor into the
    /// command bar mid-drag.
    public override func mouseDown(with event: NSEvent) {
        // A click on the terminal pane means "I want to interact
        // with what's running here" — for a TUI (vim, nano, htop)
        // that's literal mouse forwarding; for a shell at a prompt
        // OR a long-running interactive program (ssh, python REPL,
        // a `read -p` script) it means "park focus on the terminal
        // so my keystrokes reach the PTY." Either way we grab
        // first-responder unconditionally.
        //
        // Previously this bounced to the command bar on mouseUp,
        // which made ssh / repls / any character-at-a-time program
        // impossible to drive (every keystroke landed in the bar
        // and only reached the PTY after Enter). Tab still snaps
        // to the command bar from anywhere, so users who prefer
        // the typed-command flow keep their muscle memory.
        window?.makeFirstResponder(self)

        if isInAltScreen {
            super.mouseDown(with: event)
            return
        }
        let local = convert(event.locationInWindow, from: nil)
        dragAnchor = cellCoord(at: local)
        dragDidMove = false
        // Clear any pre-existing selection so the next drag starts
        // fresh; clicking outside the selection should always reset.
        if selection != nil {
            selection = nil
            needsDisplay = true
        }
        super.mouseDown(with: event)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let anchor = dragAnchor else { return }
        let local = convert(event.locationInWindow, from: nil)
        // Promote to a real drag only after the cursor has moved past
        // the click-vs-drag threshold. Without this guard, a hand
        // tremor on mouseDown would register as a 1-cell selection
        // and steal focus from the command bar.
        if !dragDidMove {
            let downPoint = convert(event.locationInWindow, from: nil)
            let pixelDelta = hypot(
                downPoint.x - (CGFloat(anchor.col) * cellWidth + Self.textInset.left),
                downPoint.y - (CGFloat(anchor.row) * cellHeight + Self.textInset.top)
            )
            if pixelDelta < Self.dragThresholdPx { return }
            dragDidMove = true
        }
        let head = cellCoord(at: local)
        let updated = TerminalSelection(anchor: anchor, head: head)
        if selection != updated {
            selection = updated
            needsDisplay = true
        }
        super.mouseDragged(with: event)
    }

    public override func mouseUp(with event: NSEvent) {
        defer {
            dragAnchor = nil
            dragDidMove = false
        }
        // No focus-bounce here anymore. mouseDown already took
        // first-responder; if the gesture was a drag the selection
        // overlay is in place, if it was a plain click focus stays
        // on the terminal so keystrokes reach the PTY. Users who
        // want the command bar can Tab from anywhere or click into
        // the bar directly.
        super.mouseUp(with: event)
    }

    /// Translate a view-local point into a cell grid coordinate.
    /// Clamps into bounds so an edge-of-view drag still produces a
    /// usable selection at the corner cell.
    private func cellCoord(at point: NSPoint) -> CellCoord {
        let inset = Self.textInset
        let x = max(0, point.x - inset.left)
        let y = max(0, point.y - inset.top)
        let col = min(max(0, Int(x / max(1, cellWidth))), max(0, Int(cols) - 1))
        let row = min(max(0, Int(y / max(1, cellHeight))), max(0, Int(rows) - 1))
        return CellCoord(row: row, col: col)
    }

    // MARK: - Copy selection

    /// Standard responder-chain `copy:` action. macOS's Edit menu
    /// item for Copy is wired to this selector at key-equivalent
    /// resolution time, which runs BEFORE the view's `keyDown` ever
    /// sees the event — so without this method, Cmd+C from the
    /// menu (and the system's default Cmd+C grab) would just bounce
    /// off the responder chain and end in a beep. The keyDown
    /// override remains as a belt-and-braces path for users who
    /// disable the menu via accessibility prefs.
    @objc public func copy(_ sender: Any?) {
        copySelection()
    }

    /// Cmd+A — select the entire visible terminal grid. Sets the
    /// selection to (0, 0) → (rows-1, lastCol). Triggers a repaint
    /// so the selection overlay shows up immediately. `override`
    /// because NSResponder ships its own (no-op for plain NSView)
    /// `selectAll` that AppKit calls via responder-chain dispatch.
    @objc public override func selectAll(_ sender: Any?) {
        guard rows > 0, cols > 0 else { return }
        // Reach for the live frame's row widths so the last column
        // matches whatever libghostty thinks the grid is right now
        // (could differ from `cols` mid-resize).
        let rowCount = Int(rows)
        let colCount = Int(cols)
        selection = TerminalSelection(
            anchor: CellCoord(row: 0, col: 0),
            head: CellCoord(row: rowCount - 1, col: max(0, colCount - 1))
        )
        needsDisplay = true
    }

    /// Cmd+V — paste pasteboard text into the PTY's stdin. Native
    /// macOS apps expose paste via the Edit menu; terminals do the
    /// same thing by forwarding the bytes as if the user typed
    /// them. We strip carriage returns + newlines into a single
    /// `\n` form because pasted multi-line content from browsers /
    /// editors uses CRLF on Windows-flavored sources, which most
    /// shells then interpret as two newlines.
    @objc public func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.isEmpty else { return }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        sendBytes(Array(normalized.utf8))
    }

    /// Cut on a read-only buffer doesn't make sense; map to copy as
    /// a courtesy so users with muscle-memory Cmd+X get something
    /// reasonable instead of a beep.
    @objc public func cut(_ sender: Any?) {
        copySelection()
    }

    /// Greys out / enables Edit-menu items based on the live
    /// selection + pasteboard state. NSView doesn't override
    /// `validateMenuItem`, so we expose it directly; the responder-
    /// chain validation pass calls this every time the menu opens.
    @objc public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(BrokeredTerminalView.copy(_:)),
             #selector(BrokeredTerminalView.cut(_:)):
            return selection != nil
        case #selector(BrokeredTerminalView.paste(_:)):
            return NSPasteboard.general.string(forType: .string)?.isEmpty == false
        case #selector(BrokeredTerminalView.selectAll(_:)):
            return rows > 0 && cols > 0
        default:
            return true
        }
    }

    /// Pulls the cell text under the active selection from the most
    /// recent frame snapshot and writes it to `NSPasteboard.general`.
    /// Trailing whitespace is stripped per row so the user doesn't
    /// paste invisible padding that confuses the next shell.
    private func copySelection() {
        guard let sel = selection,
              let session,
              let frame = try? bridge.snapshotFrame(session) else { return }
        let (start, end) = sel.ordered
        guard start.row < frame.cells.count else { return }
        var lines: [String] = []
        for rowIdx in start.row...min(end.row, frame.cells.count - 1) {
            let row = frame.cells[rowIdx]
            let firstCol = rowIdx == start.row ? start.col : 0
            let lastCol = rowIdx == end.row ? min(end.col, row.count - 1) : row.count - 1
            guard firstCol <= lastCol, lastCol >= 0 else { continue }
            var line = ""
            for col in firstCol...lastCol {
                if col < row.count {
                    line.append(row[col].text.isEmpty ? " " : row[col].text)
                }
            }
            // Strip trailing spaces — terminals pad every row to the
            // viewport width, copying that padding would paste a wall
            // of whitespace.
            while line.hasSuffix(" ") { line.removeLast() }
            lines.append(line)
        }
        let text = lines.joined(separator: "\n")
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
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
    /// Earlier this ran `displayIfNeeded()` synchronously after every
    /// broker chunk to defeat AppKit's idle-coalescing — without it
    /// the terminal would sit stale when no other UI event was firing.
    /// That worked but turned heavy output (`npm install`, `cargo
    /// build`, vim repaints, claude-code redraws) into hundreds of
    /// full-grid renders per second, all blocking the main thread.
    ///
    /// New strategy: feed the bytes immediately (so libghostty's
    /// internal state is up to date) and schedule a single
    /// `displayIfNeeded()` for the next runloop tick via
    /// `RunLoop.main.perform(inModes: [.common])`. Multiple
    /// `feedOutput` calls within the same tick coalesce — only one
    /// redraw fires per tick, no matter how many chunks arrive. The
    /// CATransaction-coupled flush still happens; AppKit just no
    /// longer paints the intermediate frames.
    ///
    /// The `pendingDisplay` flag prevents us scheduling redundant
    /// `perform` blocks.
    private func feedOutput(_ data: Data) {
        guard let session else { return }
        try? bridge.feed(data, to: session)
        detectCommandState(in: data)
        needsDisplay = true
        guard !pendingDisplay else { return }
        pendingDisplay = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            guard let self else { return }
            self.pendingDisplay = false
            self.displayIfNeeded()
        }
    }

    /// Set to true between `feedOutput` enqueuing a redraw and the
    /// runloop tick that fires it. Suppresses redundant scheduling
    /// during a burst.
    private var pendingDisplay: Bool = false

    // MARK: - OSC 133 command-state tracking

    // ESC ] 1 3 3 ; C  — shell integration's "command started running"
    // mark (emitted from preexec). ESC ] 1 3 3 ; D — "command finished,
    // back at the prompt" (emitted from precmd). We scan the raw output
    // stream for these because Riven's command bar is the default input
    // surface, which is wrong while a command is actively running: an
    // inline interactive program (claude --resume's session picker,
    // fzf, gh prompts, npm init, ssh password, a REPL) reads keystrokes
    // in raw mode WITHOUT switching to the alt screen, so the alt-screen
    // latch never fires and the user's arrows/Enter went to the command
    // bar instead of the program. Tracking command-running state lets us
    // behave like a normal terminal — keystrokes go to the PTY while a
    // command runs — and hand input back to the command bar at the prompt.
    private static let osc133CmdStart: [UInt8] = [0x1b, 0x5d, 0x31, 0x33, 0x33, 0x3b, 0x43]
    private static let osc133CmdEnd: [UInt8]   = [0x1b, 0x5d, 0x31, 0x33, 0x33, 0x3b, 0x44]
    private(set) var isCommandRunning: Bool = false
    /// Set when WE grabbed first-responder because a command started,
    /// so we only hand focus back to the command bar for grabs we made
    /// (not when the user deliberately clicked into the terminal).
    private var grabbedForCommand: Bool = false
    /// Carryover of the last few output bytes so an OSC 133 marker
    /// split across two broker chunks is still detected. Length is
    /// markerLength-1 (6) — enough to bridge any single split.
    private var oscScanTail: [UInt8] = []

    private func detectCommandState(in data: Data) {
        var buf = oscScanTail
        buf.append(contentsOf: data)
        let lastStart = Self.lastIndex(of: Self.osc133CmdStart, in: buf)
        let lastEnd = Self.lastIndex(of: Self.osc133CmdEnd, in: buf)
        if lastStart != nil || lastEnd != nil {
            // The most recent of the two marks wins — that's the
            // current state.
            let running: Bool
            switch (lastStart, lastEnd) {
            case let (.some(s), .some(e)): running = s > e
            case (.some, nil): running = true
            default: running = false
            }
            setCommandRunning(running)
        }
        // Retain a 6-byte tail to bridge a marker split across chunks.
        let keep = Self.osc133CmdStart.count - 1
        oscScanTail = buf.count > keep ? Array(buf.suffix(keep)) : buf
    }

    /// Last start index of `pattern` within `haystack`, or nil. Simple
    /// reverse scan short-circuited on the leading ESC byte — cheap
    /// even for large output chunks (OSC marks only land at command
    /// boundaries, never mid-burst).
    private static func lastIndex(of pattern: [UInt8], in haystack: [UInt8]) -> Int? {
        guard haystack.count >= pattern.count else { return nil }
        let first = pattern[0]
        var i = haystack.count - pattern.count
        while i >= 0 {
            if haystack[i] == first {
                var match = true
                for j in 1..<pattern.count where haystack[i + j] != pattern[j] {
                    match = false
                    break
                }
                if match { return i }
            }
            i -= 1
        }
        return nil
    }

    /// Deferred focus-grab for a running command. Cancelled if the
    /// command finishes before it fires (fast non-interactive
    /// commands), so we don't flicker the command bar's focus for an
    /// `ls`.
    private var commandFocusGrabTask: Task<Void, Never>?

    private func setCommandRunning(_ running: Bool) {
        guard running != isCommandRunning else { return }
        isCommandRunning = running
        if running {
            // Defer the grab ~150 ms. A fast non-interactive command
            // (ls, git status) emits C then D within tens of ms, and
            // grabbing + returning focus that fast would flicker the
            // command-bar focus ring for no reason. Only commands
            // still running after the delay — i.e. plausibly
            // interactive ones (claude --resume, fzf, a REPL, ssh) —
            // actually pull focus to the terminal. Imperceptible
            // latency for the interactive case (the picker takes
            // longer than 150 ms to render + the user to react).
            commandFocusGrabTask?.cancel()
            commandFocusGrabTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled, let self, self.isCommandRunning,
                      let win = self.window else { return }
                if win.firstResponder is CommandInputTextView {
                    win.makeFirstResponder(self)
                    self.grabbedForCommand = true
                }
            }
        } else {
            // Command finished — back at the shell prompt. Cancel any
            // pending grab; if we DID grab focus for this command,
            // still hold it, and aren't in an alt-screen TUI, return
            // input to the command bar (Riven's default at a prompt).
            commandFocusGrabTask?.cancel()
            if grabbedForCommand,
               window?.firstResponder === self,
               !isInAltScreen {
                NotificationCenter.default.post(name: .rivenFocusCommandBar, object: nil)
            }
            grabbedForCommand = false
        }
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
            // Refresh the alt-screen latch on every draw. Cheap probe
            // (one libghostty mode_get per draw, ~ns) so we don't need
            // to subscribe to a change event. The next focus-stealing
            // gesture reads `self.isInAltScreen` and the renderer
            // makes the rest of the workspace responsive to whichever
            // TUI is currently on top.
            let nextAltScreen = bridge.isInAltScreen(session)
            if nextAltScreen != isInAltScreen {
                isInAltScreen = nextAltScreen
                NotificationCenter.default.post(
                    name: .rivenAltScreenChanged,
                    object: AltScreenChange(paneID: paneID, isInAltScreen: nextAltScreen)
                )
                // On a fresh enter into alt-screen, if the user is
                // still parked in the command bar (the common case —
                // they typed `nano`, hit Enter, and the TUI just
                // booted), pull first-responder over so subsequent
                // keystrokes go to the TUI rather than the bar.
                // We deliberately only steal from the bar — if the
                // user is in an editor pane or another terminal we
                // leave their focus alone.
                if nextAltScreen,
                   let win = window,
                   win.firstResponder is CommandInputTextView {
                    win.makeFirstResponder(self)
                }
            }
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

        // Translate our cell-coord selection into the renderer's
        // inclusive `SelectionRange`. Normalized + clamped to the
        // active frame so a selection that survived a viewport resize
        // can't paint outside the grid.
        let renderSelection: GhosttyRenderer.SelectionRange? = {
            guard let sel = self.selection else { return nil }
            let (start, end) = sel.ordered
            return GhosttyRenderer.SelectionRange(
                startRow: start.row,
                startCol: start.col,
                endRow: end.row,
                endCol: end.col
            )
        }()

        GhosttyRenderer.draw(
            frame: frame,
            configuration: GhosttyRenderer.TerminalRenderConfiguration(
                defaultForeground: configuration.foreground,
                defaultBackground: configuration.background,
                cursorColor: configuration.cursor,
                fontSize: configuration.fontSize,
                fontName: configuration.fontName,
                blinkAlpha: blinkAlpha,
                selection: renderSelection,
                selectionColor: configuration.selectionBackground
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
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Cmd+C copies the active selection if one exists. We check
        // before forwarding to interpretKeyEvents so the user's
        // selection-copy gesture never accidentally lands as a Ctrl+C
        // SIGINT on the running command.
        if mods == .command,
           event.charactersIgnoringModifiers?.lowercased() == "c",
           selection != nil {
            copySelection()
            return
        }

        // Ctrl+letter (or Ctrl+Shift+letter) → ASCII control byte.
        //
        // AppKit's `interpretKeyEvents` translates most Ctrl+letter
        // combos into editing selectors (`cut:` for Ctrl+X,
        // `pageDown:` for Ctrl+V, etc.). Our `doCommand` switch only
        // covers the handful that map to TUI-shaped behaviors, which
        // means Ctrl+X / Ctrl+O / Ctrl+W / Ctrl+K / Ctrl+R / …
        // silently fall through the default branch — and nano /
        // less / emacs / readline-driven shells lose their entire
        // shortcut surface.
        //
        // The ASCII control byte for any letter is `letter & 0x1F`
        // (so Ctrl+X = 0x18, Ctrl+O = 0x0F, Ctrl+W = 0x17, …).
        // Sending that byte directly to the PTY is what every other
        // terminal emulator does — short-circuiting interpretKeyEvents
        // is the only way to keep AppKit from claiming the keystroke
        // for its own editing pipeline.
        //
        // We explicitly skip C/D/Z here because the global key
        // monitor in RivenApp already intercepts those and routes
        // them through `.rivenSendCtrlByte` (so they work even when
        // the command bar / sidebar holds first-responder). Other
        // Ctrl combos with non-letter chars (`[`, `]`, `\`, etc.)
        // fall through to interpretKeyEvents so the standard
        // ESC / quit / group-switch handling still applies.
        if mods == .control,
           let chars = event.charactersIgnoringModifiers,
           chars.count == 1,
           let scalar = chars.unicodeScalars.first,
           scalar.isASCII {
            let lowered = scalar.value | 0x20  // a-z normalize
            if lowered >= 0x61 && lowered <= 0x7A {
                // C/D/Z handled upstream by the global monitor.
                if lowered != 0x63, lowered != 0x64, lowered != 0x7A {
                    let ctrlByte = UInt8(lowered & 0x1F)
                    sendBytes([ctrlByte])
                    return
                }
            }
        }

        // Function keys (F1-F12). AppKit doesn't route these through
        // `doCommand` — they arrive as NSEvent.charactersIgnoringModifiers
        // containing the magic NSFunctionKey unicode scalars
        // (0xF704+). nano uses the whole row (F1=help, F2=exit, F3=save,
        // …) so they have to reach the PTY.
        //
        // F1-F4 use the older SS3 form (ESC O P/Q/R/S) — that's what
        // every terminfo entry agrees on. F5+ uses the CSI <n> ~ form
        // with parameter numbers that skip a few values for historical
        // reasons (no, that gap isn't a typo — F5=15, F6=17, F11=23).
        if let bytes = functionKeySequence(from: event) {
            sendBytes(bytes)
            return
        }

        interpretKeyEvents([event])
    }

    /// Map an NSEvent representing F1-F12 to the xterm escape
    /// sequence the PTY expects, or nil if the event isn't a
    /// function key. Pulled out of `keyDown` so the dispatch reads
    /// cleanly.
    private func functionKeySequence(from event: NSEvent) -> [UInt8]? {
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else {
            return nil
        }
        // NSF1FunctionKey == 0xF704 and they march sequentially up to
        // F12 == 0xF70F. AppKit unfortunately exposes these as
        // OpenStep-era constants typed as `Int`, so we compare raw.
        let v = scalar.value
        guard v >= 0xF704 && v <= 0xF70F else { return nil }
        switch v {
        case 0xF704: return [0x1B, 0x4F, 0x50] // F1  ESC O P
        case 0xF705: return [0x1B, 0x4F, 0x51] // F2  ESC O Q
        case 0xF706: return [0x1B, 0x4F, 0x52] // F3  ESC O R
        case 0xF707: return [0x1B, 0x4F, 0x53] // F4  ESC O S
        case 0xF708: return [0x1B, 0x5B, 0x31, 0x35, 0x7E] // F5
        case 0xF709: return [0x1B, 0x5B, 0x31, 0x37, 0x7E] // F6
        case 0xF70A: return [0x1B, 0x5B, 0x31, 0x38, 0x7E] // F7
        case 0xF70B: return [0x1B, 0x5B, 0x31, 0x39, 0x7E] // F8
        case 0xF70C: return [0x1B, 0x5B, 0x32, 0x30, 0x7E] // F9
        case 0xF70D: return [0x1B, 0x5B, 0x32, 0x31, 0x7E] // F10
        case 0xF70E: return [0x1B, 0x5B, 0x32, 0x33, 0x7E] // F11
        case 0xF70F: return [0x1B, 0x5B, 0x32, 0x34, 0x7E] // F12
        default: return nil
        }
    }

    // MARK: - Scroll wheel → PTY arrows

    /// Translate scroll-wheel input into Up / Down arrow sequences
    /// when the terminal is on the alt screen. Convention every
    /// modern terminal honors (iTerm, Warp, kitty, alacritty): if a
    /// fullscreen TUI doesn't know how to listen for mouse-tracking
    /// events, scroll gestures are synthesized into arrow keys so
    /// `less` / `man` / `nano` scroll their viewport the way users
    /// expect.
    ///
    /// On the primary screen (regular shell prompt), there's no
    /// natural target for forwarded scrolls — Riven doesn't yet
    /// expose a scrollback viewport — so we just no-op there rather
    /// than spam arrow keys into the shell.
    public override func scrollWheel(with event: NSEvent) {
        guard isInAltScreen else {
            super.scrollWheel(with: event)
            return
        }
        // Trackpads emit precise deltaY in pixels; mouse wheels emit
        // discrete line-sized ticks. Both already go through
        // `event.scrollingDeltaY`, which is logical-pixel-ish, so we
        // bucket into "lines" using cellHeight. Macs report positive
        // deltaY for "wheel rolled up / fingers swiped down" (i.e.
        // natural scrolling), which maps to scrolling the document
        // UP — which in turn means sending Up-arrow sequences.
        let pixels = event.scrollingDeltaY
        guard abs(pixels) >= 1 else { return }
        // Cap so a fast flick doesn't dump 200 arrow keys into the
        // PTY. 6 lines per dispatch matches what Warp + iTerm settle
        // on; a follow-up flick will arrive shortly after.
        let lines = max(1, min(6, Int(abs(pixels) / max(1, cellHeight))))
        let arrow: [UInt8] = pixels > 0
            ? [0x1B, 0x5B, 0x41]    // ESC [ A — Up
            : [0x1B, 0x5B, 0x42]    // ESC [ B — Down
        var payload = [UInt8]()
        payload.reserveCapacity(arrow.count * lines)
        for _ in 0..<lines { payload.append(contentsOf: arrow) }
        sendBytes(payload)
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
        case #selector(NSResponder.deleteWordForward(_:)):
            // readline `kill-word` — ESC d.
            sendBytes([0x1b, 0x64])
        case #selector(NSResponder.moveWordLeft(_:)),
             #selector(NSResponder.moveWordBackward(_:)):
            // readline `backward-word` — ESC b.
            sendBytes([0x1b, 0x62])
        case #selector(NSResponder.moveWordRight(_:)),
             #selector(NSResponder.moveWordForward(_:)):
            // readline `forward-word` — ESC f.
            sendBytes([0x1b, 0x66])
        // Page Up / Page Down — xterm CSI 5 ~ / CSI 6 ~. AppKit maps
        // both `pageUp:`/`pageDown:` (NSView) and `scrollPageUp:`/
        // `scrollPageDown:` (NSResponder) to the same physical key
        // depending on context, so we handle both selectors.
        case #selector(NSResponder.pageUp(_:)),
             #selector(NSResponder.scrollPageUp(_:)):
            sendBytes([0x1b, 0x5b, 0x35, 0x7e])
        case #selector(NSResponder.pageDown(_:)),
             #selector(NSResponder.scrollPageDown(_:)):
            sendBytes([0x1b, 0x5b, 0x36, 0x7e])
        // Home / End on Mac usually fire via the function-modifier
        // layer (Fn+Left/Right) which AppKit reports as the
        // BeginningOf / EndOf Document selectors. Send xterm Home /
        // End sequences (CSI H / CSI F). Most TUIs accept both
        // these and the `CSI 1 ~` / `CSI 4 ~` alternates.
        case #selector(NSResponder.moveToBeginningOfDocument(_:)),
             #selector(NSResponder.scrollToBeginningOfDocument(_:)):
            sendBytes([0x1b, 0x5b, 0x48])
        case #selector(NSResponder.moveToEndOfDocument(_:)),
             #selector(NSResponder.scrollToEndOfDocument(_:)):
            sendBytes([0x1b, 0x5b, 0x46])
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

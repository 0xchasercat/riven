import Foundation
import Testing
@testable import BentoCore

/// Tests for `GhosttyBridge.snapshotFrame(_:)`, which builds a
/// `GhosttyRenderFrame` via the libghostty-vt Render State API.
///
/// These exercise the full chain: feed VT bytes -> render-state update ->
/// per-cell read of codepoint, foreground / background, and SGR flags.
@Suite("Ghostty render-state snapshot")
struct GhosttySnapshotTests {

    // MARK: - Helpers

    private func makeSession(
        cols: UInt16 = 40,
        rows: UInt16 = 6
    ) throws -> (GhosttyBridge, GhosttySessionHandle) {
        let bridge = GhosttyBridge()
        let session = try bridge.createSession(
            id: PaneID("snapshot-\(UUID().uuidString)"),
            cwd: "/tmp",
            command: nil,
            cols: cols,
            rows: rows
        )
        return (bridge, session)
    }

    /// Find the first cell whose grapheme is `text` in row `row`.
    private func cellIndex(
        of text: String,
        in frame: GhosttyRenderFrame,
        row: Int = 0
    ) -> Int? {
        guard row < frame.cells.count else { return nil }
        return frame.cells[row].firstIndex { $0.text == text }
    }

    // MARK: - Tests

    @Test("snapshot returns a frame with the configured viewport dimensions")
    func dimensionsMatchViewport() throws {
        let (bridge, session) = try makeSession(cols: 40, rows: 6)
        defer { try? bridge.close(session) }

        let frame = try bridge.snapshotFrame(session)

        #expect(frame.cols == 40)
        #expect(frame.rows == 6)
        #expect(frame.cells.count == 6)
        for row in frame.cells {
            #expect(row.count == 40)
        }
    }

    @Test("feeding plain ASCII bytes produces cells with that text and no styling")
    func plainAsciiNoStyling() throws {
        let (bridge, session) = try makeSession()
        defer { try? bridge.close(session) }

        try bridge.feed(Data("HELLO".utf8), to: session)

        let frame = try bridge.snapshotFrame(session)
        let chars = ["H", "E", "L", "L", "O"]
        for (i, ch) in chars.enumerated() {
            let cell = frame.cells[0][i]
            #expect(cell.text == ch, "col \(i) text")
            #expect(cell.foreground == nil, "col \(i) fg should be default")
            #expect(cell.background == nil, "col \(i) bg should be default")
            #expect(cell.bold == false)
            #expect(cell.italic == false)
            #expect(cell.underline == false)
            #expect(cell.strikethrough == false)
            #expect(cell.inverse == false)
            #expect(cell.isWideTail == false)
        }
    }

    @Test("ESC[31m HELLO ESC[0m produces cells with red foreground")
    func redForegroundForHello() throws {
        let (bridge, session) = try makeSession()
        defer { try? bridge.close(session) }

        // ESC[31m = set foreground to color index 1 (red), then "HELLO",
        // then ESC[0m to reset.
        let bytes: [UInt8] = Array("\u{1B}[31mHELLO\u{1B}[0m".utf8)
        try bridge.feed(Data(bytes), to: session)

        let frame = try bridge.snapshotFrame(session)
        // First five cells should have a non-nil foreground that is "redder
        // than green or blue". We don't assert exact RGB because the active
        // palette might be tweaked by terminal defaults — but red(1) always
        // resolves to a color where R > G and R > B.
        for i in 0..<5 {
            let cell = frame.cells[0][i]
            guard let fg = cell.foreground else {
                Issue.record("cell \(i) has no foreground — expected red")
                continue
            }
            #expect(fg.r > fg.g, "col \(i) expected R > G in red palette entry")
            #expect(fg.r > fg.b, "col \(i) expected R > B in red palette entry")
        }
    }

    @Test("ESC[1m BOLD produces cells with bold = true")
    func boldFlagSet() throws {
        let (bridge, session) = try makeSession()
        defer { try? bridge.close(session) }

        let bytes: [UInt8] = Array("\u{1B}[1mBOLD".utf8)
        try bridge.feed(Data(bytes), to: session)

        let frame = try bridge.snapshotFrame(session)
        let chars = ["B", "O", "L", "D"]
        for (i, ch) in chars.enumerated() {
            let cell = frame.cells[0][i]
            #expect(cell.text == ch, "col \(i) text")
            #expect(cell.bold == true, "col \(i) expected bold")
        }
    }

    @Test("ESC[44m   ESC[0m produces cells with blue background")
    func blueBackgroundForSpaces() throws {
        let (bridge, session) = try makeSession()
        defer { try? bridge.close(session) }

        // ESC[44m = set background to color index 4 (blue), then 3 spaces,
        // then reset.
        let bytes: [UInt8] = Array("\u{1B}[44m   \u{1B}[0m".utf8)
        try bridge.feed(Data(bytes), to: session)

        let frame = try bridge.snapshotFrame(session)
        for i in 0..<3 {
            let cell = frame.cells[0][i]
            guard let bg = cell.background else {
                Issue.record("col \(i) has no background — expected blue")
                continue
            }
            #expect(bg.b > bg.r, "col \(i) expected B > R in blue palette entry")
            #expect(bg.b > bg.g, "col \(i) expected B > G in blue palette entry")
        }
    }

    @Test("ESC[2m FAINT produces cells with faint = true")
    func faintFlagSet() throws {
        let (bridge, session) = try makeSession()
        defer { try? bridge.close(session) }

        // SGR 2 = faint (decreased intensity).
        let bytes: [UInt8] = Array("\u{1B}[2mFAINT".utf8)
        try bridge.feed(Data(bytes), to: session)

        let frame = try bridge.snapshotFrame(session)
        let chars = ["F", "A", "I", "N", "T"]
        for (i, ch) in chars.enumerated() {
            let cell = frame.cells[0][i]
            #expect(cell.text == ch, "col \(i) text")
            #expect(cell.faint == true, "col \(i) expected faint")
        }
    }

    @Test("ESC[5m BLINK produces cells with blink = true")
    func blinkFlagSet() throws {
        let (bridge, session) = try makeSession()
        defer { try? bridge.close(session) }

        // SGR 5 = slow blink.
        let bytes: [UInt8] = Array("\u{1B}[5mBLINK".utf8)
        try bridge.feed(Data(bytes), to: session)

        let frame = try bridge.snapshotFrame(session)
        let chars = ["B", "L", "I", "N", "K"]
        for (i, ch) in chars.enumerated() {
            let cell = frame.cells[0][i]
            #expect(cell.text == ch, "col \(i) text")
            #expect(cell.blink == true, "col \(i) expected blink")
        }
    }

    @Test("ESC[8m INVISIBLE produces cells with invisible = true")
    func invisibleFlagSet() throws {
        let (bridge, session) = try makeSession()
        defer { try? bridge.close(session) }

        let bytes: [UInt8] = Array("\u{1B}[8mHIDE".utf8)
        try bridge.feed(Data(bytes), to: session)

        let frame = try bridge.snapshotFrame(session)
        let chars = ["H", "I", "D", "E"]
        for (i, ch) in chars.enumerated() {
            let cell = frame.cells[0][i]
            // Cell text is still present in the resolved cell — the
            // renderer is the layer that decides not to draw it.
            #expect(cell.text == ch, "col \(i) text")
            #expect(cell.invisible == true, "col \(i) expected invisible")
        }
    }

    @Test("ESC[53m OVERLINE produces cells with overline = true")
    func overlineFlagSet() throws {
        let (bridge, session) = try makeSession()
        defer { try? bridge.close(session) }

        // SGR 53 = overline.
        let bytes: [UInt8] = Array("\u{1B}[53mOVER".utf8)
        try bridge.feed(Data(bytes), to: session)

        let frame = try bridge.snapshotFrame(session)
        let chars = ["O", "V", "E", "R"]
        for (i, ch) in chars.enumerated() {
            let cell = frame.cells[0][i]
            #expect(cell.text == ch, "col \(i) text")
            #expect(cell.overline == true, "col \(i) expected overline")
        }
    }

    @Test("ESC[21m DOUBLE produces cells with underlineStyle == .double")
    func doubleUnderlineFlowsThrough() throws {
        let (bridge, session) = try makeSession()
        defer { try? bridge.close(session) }

        // SGR 21 is the historic double-underline code; libghostty also
        // accepts the modern `4:2` form. We use 21 here because it's a
        // simpler one-token sequence.
        let bytes: [UInt8] = Array("\u{1B}[21mDBL".utf8)
        try bridge.feed(Data(bytes), to: session)

        let frame = try bridge.snapshotFrame(session)
        let chars = ["D", "B", "L"]
        for (i, ch) in chars.enumerated() {
            let cell = frame.cells[0][i]
            #expect(cell.text == ch, "col \(i) text")
            #expect(cell.underlineStyle == .double, "col \(i) expected .double")
            // Convenience flag must agree.
            #expect(cell.underline == true, "col \(i) underline convenience flag")
        }
    }

    @Test("ESC[4:3m CURLY produces cells with underlineStyle == .curly")
    func curlyUnderlineFlowsThrough() throws {
        let (bridge, session) = try makeSession()
        defer { try? bridge.close(session) }

        // 4:3 is the colon-separated form for curly underline (the form
        // used by editors / linters for spell-check squiggles).
        let bytes: [UInt8] = Array("\u{1B}[4:3mCURL".utf8)
        try bridge.feed(Data(bytes), to: session)

        let frame = try bridge.snapshotFrame(session)
        let chars = ["C", "U", "R", "L"]
        for (i, ch) in chars.enumerated() {
            let cell = frame.cells[0][i]
            #expect(cell.text == ch, "col \(i) text")
            #expect(cell.underlineStyle == .curly, "col \(i) expected .curly")
        }
    }

    @Test("ESC[58:2::R:G:Bm sets a per-cell underline color")
    func underlineColorFlowsThrough() throws {
        let (bridge, session) = try makeSession()
        defer { try? bridge.close(session) }

        // Combine `4` (single underline) with `58:2::255:0:0` (set
        // underline color to direct RGB red). The empty colorspace
        // slot (`::`) is the standard form for "default colorspace".
        let seq = "\u{1B}[4;58:2::255:0:0mTAG"
        try bridge.feed(Data(seq.utf8), to: session)

        let frame = try bridge.snapshotFrame(session)
        let chars = ["T", "A", "G"]
        for (i, ch) in chars.enumerated() {
            let cell = frame.cells[0][i]
            #expect(cell.text == ch, "col \(i) text")
            #expect(cell.underlineStyle == .single, "col \(i) expected .single")
            guard let uc = cell.underlineColor else {
                Issue.record("col \(i) expected non-nil underline color")
                continue
            }
            #expect(uc == GhosttyRGB(r: 255, g: 0, b: 0),
                    "col \(i) expected red underline color")
        }
    }

    @Test("hyperlink URI is currently always nil (render-state API does not expose it)")
    func hyperlinkURIIsNil() throws {
        let (bridge, session) = try makeSession()
        defer { try? bridge.close(session) }

        // OSC 8 hyperlink-start: `ESC ] 8 ; ; URI ESC \`. Then text,
        // then OSC 8 close: `ESC ] 8 ; ; ESC \`.
        let seq = "\u{1B}]8;;https://example.com\u{1B}\\LINK\u{1B}]8;;\u{1B}\\"
        try bridge.feed(Data(seq.utf8), to: session)

        let frame = try bridge.snapshotFrame(session)
        // The text still flows through normally; only the URI is dropped.
        for (i, ch) in ["L", "I", "N", "K"].enumerated() {
            let cell = frame.cells[0][i]
            #expect(cell.text == ch, "col \(i) text")
            // Always nil because the libghostty-vt render-state API
            // doesn't expose hyperlink URIs at the row-cells level.
            // Documented limitation: the only path is
            // `ghostty_grid_ref_hyperlink_uri` on the slow grid_ref
            // API, which the bridge deliberately moved off of.
            #expect(cell.hyperlinkURI == nil, "col \(i) hyperlinkURI must be nil today")
        }
    }

    @Test("the cursor position reported in the snapshot tracks ghostty_terminal_get(CURSOR_X/Y)")
    func cursorPositionMatchesTerminal() throws {
        let (bridge, session) = try makeSession()
        defer { try? bridge.close(session) }

        // Write 7 characters; cursor should sit at column 7 on row 0.
        try bridge.feed(Data("hello, ".utf8), to: session)

        let frame = try bridge.snapshotFrame(session)
        let cursor = try bridge.readCursor(session)

        #expect(frame.cursor.x == cursor.x)
        #expect(frame.cursor.y == cursor.y)
        #expect(frame.cursor.x == 7)
        #expect(frame.cursor.y == 0)

        // Now drop to row 1 via newline + carriage return and write more.
        try bridge.feed(Data("\r\nworld".utf8), to: session)
        let frame2 = try bridge.snapshotFrame(session)
        let cursor2 = try bridge.readCursor(session)
        #expect(frame2.cursor.x == cursor2.x)
        #expect(frame2.cursor.y == cursor2.y)
        #expect(frame2.cursor.y == 1)
        #expect(frame2.cursor.x == 5)
    }
}

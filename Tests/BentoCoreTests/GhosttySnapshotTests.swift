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

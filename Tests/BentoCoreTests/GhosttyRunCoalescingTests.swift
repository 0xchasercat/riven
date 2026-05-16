import Foundation
import Testing
@testable import BentoCore

/// Coverage for `TerminalRunCoalescer.runs(in:)`. The renderer relies on
/// this being purely structural — same row in, same runs out — so every
/// observable contract is pinned here.
@Suite("Ghostty run coalescing")
struct GhosttyRunCoalescingTests {

    // MARK: - Helpers

    /// Convenience for building a plain ASCII cell with optional styling.
    private func cell(
        _ text: String,
        fg: GhosttyRGB? = nil,
        bg: GhosttyRGB? = nil,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        strikethrough: Bool = false,
        inverse: Bool = false,
        isWideTail: Bool = false,
        faint: Bool = false,
        blink: Bool = false,
        invisible: Bool = false,
        overline: Bool = false,
        underlineStyle: GhosttyUnderlineStyle? = nil,
        underlineColor: GhosttyRGB? = nil,
        hyperlinkURI: String? = nil
    ) -> GhosttyResolvedCell {
        GhosttyResolvedCell(
            text: text,
            foreground: fg,
            background: bg,
            bold: bold,
            italic: italic,
            underline: underline,
            strikethrough: strikethrough,
            inverse: inverse,
            isWideTail: isWideTail,
            faint: faint,
            blink: blink,
            invisible: invisible,
            overline: overline,
            underlineStyle: underlineStyle,
            underlineColor: underlineColor,
            hyperlinkURI: hyperlinkURI
        )
    }

    private let red = GhosttyRGB(r: 255, g: 0, b: 0)
    private let green = GhosttyRGB(r: 0, g: 255, b: 0)
    private let blue = GhosttyRGB(r: 0, g: 0, b: 255)

    // MARK: - Empty / trivial

    @Test("an empty row produces no runs")
    func emptyRow() {
        let runs = TerminalRunCoalescer.runs(in: [])
        #expect(runs.isEmpty)
    }

    @Test("a single cell produces a single run covering one column")
    func singleCell() {
        let row = [cell("a")]
        let runs = TerminalRunCoalescer.runs(in: row)
        #expect(runs.count == 1)
        #expect(runs[0].text == "a")
        #expect(runs[0].startColumn == 0)
        #expect(runs[0].endColumn == 1)
    }

    // MARK: - Coalescing

    @Test("consecutive cells with identical style produce a single run")
    func consecutiveIdenticalCellsCoalesce() {
        let row = [
            cell("h"),
            cell("e"),
            cell("l"),
            cell("l"),
            cell("o"),
        ]
        let runs = TerminalRunCoalescer.runs(in: row)
        #expect(runs.count == 1)
        #expect(runs[0].text == "hello")
        #expect(runs[0].startColumn == 0)
        #expect(runs[0].endColumn == 5)
        #expect(runs[0].foregroundRGB == nil)
        #expect(runs[0].backgroundRGB == nil)
    }

    @Test("a foreground-color change starts a new run")
    func foregroundChangeBreaksRun() {
        let row = [
            cell("a", fg: red),
            cell("b", fg: red),
            cell("c", fg: green),
        ]
        let runs = TerminalRunCoalescer.runs(in: row)
        #expect(runs.count == 2)
        #expect(runs[0].text == "ab")
        #expect(runs[0].foregroundRGB == red)
        #expect(runs[0].startColumn == 0)
        #expect(runs[0].endColumn == 2)
        #expect(runs[1].text == "c")
        #expect(runs[1].foregroundRGB == green)
        #expect(runs[1].startColumn == 2)
        #expect(runs[1].endColumn == 3)
    }

    @Test("a background-color change starts a new run")
    func backgroundChangeBreaksRun() {
        let row = [
            cell("a", bg: red),
            cell("b", bg: blue),
        ]
        let runs = TerminalRunCoalescer.runs(in: row)
        #expect(runs.count == 2)
        #expect(runs[0].backgroundRGB == red)
        #expect(runs[1].backgroundRGB == blue)
    }

    @Test("toggling bold starts a new run")
    func boldChangeBreaksRun() {
        let row = [
            cell("a", bold: true),
            cell("b", bold: true),
            cell("c", bold: false),
        ]
        let runs = TerminalRunCoalescer.runs(in: row)
        #expect(runs.count == 2)
        #expect(runs[0].bold == true)
        #expect(runs[0].text == "ab")
        #expect(runs[1].bold == false)
        #expect(runs[1].text == "c")
    }

    @Test("toggling italic starts a new run")
    func italicChangeBreaksRun() {
        let row = [
            cell("a", italic: false),
            cell("b", italic: true),
        ]
        let runs = TerminalRunCoalescer.runs(in: row)
        #expect(runs.count == 2)
        #expect(runs[0].italic == false)
        #expect(runs[1].italic == true)
    }

    @Test("toggling underline starts a new run")
    func underlineChangeBreaksRun() {
        let row = [
            cell("a", underline: false),
            cell("b", underline: true),
        ]
        let runs = TerminalRunCoalescer.runs(in: row)
        #expect(runs.count == 2)
        #expect(runs[0].underline == false)
        #expect(runs[1].underline == true)
    }

    @Test("toggling strikethrough starts a new run")
    func strikethroughChangeBreaksRun() {
        let row = [
            cell("a", strikethrough: true),
            cell("b", strikethrough: false),
        ]
        let runs = TerminalRunCoalescer.runs(in: row)
        #expect(runs.count == 2)
        #expect(runs[0].strikethrough == true)
        #expect(runs[1].strikethrough == false)
    }

    // MARK: - Trailing defaults

    @Test("trailing default-styled cells are coalesced into a final run")
    func trailingDefaultsCoalesce() {
        let row = [
            cell("a", fg: red),
            cell("b", fg: red),
            cell(" "),
            cell(" "),
            cell(" "),
        ]
        let runs = TerminalRunCoalescer.runs(in: row)
        #expect(runs.count == 2)
        #expect(runs[0].text == "ab")
        #expect(runs[0].foregroundRGB == red)
        #expect(runs[1].text == "   ")
        #expect(runs[1].foregroundRGB == nil)
        #expect(runs[1].startColumn == 2)
        #expect(runs[1].endColumn == 5)
    }

    // MARK: - Wide characters

    @Test("wide-tail cells are folded into the preceding wide cell's run, not standalone")
    func wideTailFoldsIntoPreviousRun() {
        // Wide character "漢" + its tail, followed by an ASCII letter.
        let row = [
            cell("漢", fg: green),
            cell("", fg: green, isWideTail: true),
            cell("a", fg: green),
        ]
        let runs = TerminalRunCoalescer.runs(in: row)
        #expect(runs.count == 1)
        #expect(runs[0].text == "漢a")
        #expect(runs[0].startColumn == 0)
        #expect(runs[0].endColumn == 3)
    }

    @Test("wide-tail extends the preceding run even when the tail's nominal style differs")
    func wideTailIgnoresOwnStyle() {
        // The bridge sometimes stamps the tail with its own style; the
        // renderer must still treat it as part of the wide cell's run.
        let row = [
            cell("漢", fg: green),
            cell("", fg: red, bg: blue, isWideTail: true),
        ]
        let runs = TerminalRunCoalescer.runs(in: row)
        #expect(runs.count == 1)
        #expect(runs[0].text == "漢")
        #expect(runs[0].foregroundRGB == green)
        #expect(runs[0].startColumn == 0)
        // endColumn extends to cover the tail's footprint so the
        // background pass paints both columns with the wide cell's bg.
        #expect(runs[0].endColumn == 2)
    }

    // MARK: - Inverse

    @Test("inverse cells produce a run with an inverse flag (swap is applied at draw time)")
    func inverseCarriedAsFlag() {
        let row = [
            cell("a", fg: red, bg: blue, inverse: false),
            cell("b", fg: red, bg: blue, inverse: true),
            cell("c", fg: red, bg: blue, inverse: true),
            cell("d", fg: red, bg: blue, inverse: false),
        ]
        let runs = TerminalRunCoalescer.runs(in: row)
        #expect(runs.count == 3)
        #expect(runs[0].inverse == false)
        #expect(runs[0].text == "a")
        #expect(runs[1].inverse == true)
        #expect(runs[1].text == "bc")
        // The colors are NOT swapped here — that's the renderer's job.
        // The run carries the original fg/bg verbatim plus the flag.
        #expect(runs[1].foregroundRGB == red)
        #expect(runs[1].backgroundRGB == blue)
        #expect(runs[2].inverse == false)
        #expect(runs[2].text == "d")
    }

    // MARK: - Mixed

    @Test("eight color changes produce eight runs covering every column")
    func eightColorRow() {
        let palette = [
            GhosttyRGB(r: 1, g: 0, b: 0),
            GhosttyRGB(r: 2, g: 0, b: 0),
            GhosttyRGB(r: 3, g: 0, b: 0),
            GhosttyRGB(r: 4, g: 0, b: 0),
            GhosttyRGB(r: 5, g: 0, b: 0),
            GhosttyRGB(r: 6, g: 0, b: 0),
            GhosttyRGB(r: 7, g: 0, b: 0),
            GhosttyRGB(r: 8, g: 0, b: 0),
        ]
        let row = palette.map { cell("x", fg: $0) }
        let runs = TerminalRunCoalescer.runs(in: row)
        #expect(runs.count == 8)
        for (idx, run) in runs.enumerated() {
            #expect(run.startColumn == idx)
            #expect(run.endColumn == idx + 1)
            #expect(run.foregroundRGB == palette[idx])
        }
    }

    @Test("rectangularity is preserved: column indices are contiguous and cover the row")
    func columnIndicesCoverRow() {
        let row = [
            cell("a", fg: red),
            cell("b", fg: red),
            cell("c", fg: green),
            cell("d", fg: green),
            cell("e"),
        ]
        let runs = TerminalRunCoalescer.runs(in: row)
        #expect(runs.first?.startColumn == 0)
        #expect(runs.last?.endColumn == row.count)
        for pair in zip(runs, runs.dropFirst()) {
            #expect(pair.0.endColumn == pair.1.startColumn)
        }
    }

    @Test("a leading wide-tail with no preceding cell becomes a standalone run")
    func leadingWideTailIsStandalone() {
        // Degenerate but possible — make sure we don't crash and don't
        // silently drop the cell.
        let row = [
            cell("", fg: red, isWideTail: true),
            cell("a"),
        ]
        let runs = TerminalRunCoalescer.runs(in: row)
        #expect(runs.count == 2)
        #expect(runs[0].startColumn == 0)
        #expect(runs[0].endColumn == 1)
        #expect(runs[1].text == "a")
    }

    // MARK: - Extended SGR attributes

    @Test("two adjacent cells with different underline styles produce two runs")
    func underlineStyleChangeBreaksRun() {
        let row = [
            cell("a", underlineStyle: .single),
            cell("b", underlineStyle: .single),
            cell("c", underlineStyle: .double),
            cell("d", underlineStyle: .curly),
        ]
        let runs = TerminalRunCoalescer.runs(in: row)
        #expect(runs.count == 3)
        #expect(runs[0].text == "ab")
        #expect(runs[0].underlineStyle == .single)
        #expect(runs[1].text == "c")
        #expect(runs[1].underlineStyle == .double)
        #expect(runs[2].text == "d")
        #expect(runs[2].underlineStyle == .curly)
    }

    @Test("two adjacent cells with same fg/bg but different faint produce two runs")
    func faintChangeBreaksRun() {
        let row = [
            cell("a", fg: red, bg: blue, faint: false),
            cell("b", fg: red, bg: blue, faint: true),
            cell("c", fg: red, bg: blue, faint: true),
            cell("d", fg: red, bg: blue, faint: false),
        ]
        let runs = TerminalRunCoalescer.runs(in: row)
        #expect(runs.count == 3)
        #expect(runs[0].text == "a")
        #expect(runs[0].faint == false)
        #expect(runs[1].text == "bc")
        #expect(runs[1].faint == true)
        // fg/bg are still preserved verbatim across the boundary.
        #expect(runs[1].foregroundRGB == red)
        #expect(runs[1].backgroundRGB == blue)
        #expect(runs[2].text == "d")
        #expect(runs[2].faint == false)
    }

    @Test("toggling blink starts a new run")
    func blinkChangeBreaksRun() {
        let row = [
            cell("a"),
            cell("b", blink: true),
        ]
        let runs = TerminalRunCoalescer.runs(in: row)
        #expect(runs.count == 2)
        #expect(runs[0].blink == false)
        #expect(runs[1].blink == true)
    }

    @Test("toggling invisible starts a new run")
    func invisibleChangeBreaksRun() {
        let row = [
            cell("a"),
            cell("b", invisible: true),
            cell("c", invisible: true),
        ]
        let runs = TerminalRunCoalescer.runs(in: row)
        #expect(runs.count == 2)
        #expect(runs[0].invisible == false)
        #expect(runs[1].text == "bc")
        #expect(runs[1].invisible == true)
    }

    @Test("toggling overline starts a new run")
    func overlineChangeBreaksRun() {
        let row = [
            cell("a", overline: true),
            cell("b"),
        ]
        let runs = TerminalRunCoalescer.runs(in: row)
        #expect(runs.count == 2)
        #expect(runs[0].overline == true)
        #expect(runs[1].overline == false)
    }

    @Test("a change in underline color starts a new run")
    func underlineColorChangeBreaksRun() {
        let row = [
            cell("a", underlineStyle: .single, underlineColor: red),
            cell("b", underlineStyle: .single, underlineColor: red),
            cell("c", underlineStyle: .single, underlineColor: green),
        ]
        let runs = TerminalRunCoalescer.runs(in: row)
        #expect(runs.count == 2)
        #expect(runs[0].text == "ab")
        #expect(runs[0].underlineColor == red)
        #expect(runs[1].text == "c")
        #expect(runs[1].underlineColor == green)
    }

    @Test("a change in hyperlink URI starts a new run (forward-compat)")
    func hyperlinkChangeBreaksRun() {
        let row = [
            cell("a", hyperlinkURI: "https://example.com/a"),
            cell("b", hyperlinkURI: "https://example.com/a"),
            cell("c", hyperlinkURI: "https://example.com/b"),
            cell("d", hyperlinkURI: nil),
        ]
        let runs = TerminalRunCoalescer.runs(in: row)
        #expect(runs.count == 3)
        #expect(runs[0].text == "ab")
        #expect(runs[0].hyperlinkURI == "https://example.com/a")
        #expect(runs[1].text == "c")
        #expect(runs[1].hyperlinkURI == "https://example.com/b")
        #expect(runs[2].text == "d")
        #expect(runs[2].hyperlinkURI == nil)
    }

    @Test("the single-underline convenience flag still works for legacy callsites")
    func legacyUnderlineFlagStillWorks() {
        // Old call sites can keep passing `underline: true` and get
        // `.single` for free; coalescing must still match identical
        // underline-bool runs.
        let row = [
            cell("a", underline: true),
            cell("b", underline: true),
            cell("c", underline: false),
        ]
        let runs = TerminalRunCoalescer.runs(in: row)
        #expect(runs.count == 2)
        #expect(runs[0].text == "ab")
        #expect(runs[0].underline == true)
        #expect(runs[0].underlineStyle == .single)
        #expect(runs[1].text == "c")
        #expect(runs[1].underline == false)
        #expect(runs[1].underlineStyle == .none)
    }
}

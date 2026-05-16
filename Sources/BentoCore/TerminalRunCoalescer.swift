import Foundation

/// One contiguous horizontal run of terminal cells that share the same
/// visual style. Produced by `TerminalRunCoalescer.runs(in:)` from a row
/// of `GhosttyResolvedCell`s.
///
/// Coalescing is the single biggest performance win in the renderer: a
/// row that switches between eight colors becomes ~8 styled runs (and
/// therefore ~8 CTLine draws), not 80 separate per-cell draws. The
/// renderer then walks `[StyledRun]` twice — once to fill backgrounds,
/// once to draw glyphs.
///
/// Color is carried as `GhosttyRGB?` (nil = "use the renderer's default")
/// rather than as `NSColor` so this type can live in `BentoCore`, which
/// has no AppKit dependency. The renderer resolves nil → its theme
/// default and `GhosttyRGB` → `NSColor` at draw time.
///
/// `inverse` is preserved as a flag (rather than being applied at
/// coalesce time by swapping fg/bg). Two reasons:
///   1. The renderer needs `inverse` separately for cursor inversion
///      semantics later in the pipeline.
///   2. It keeps `runs(in:)` purely structural — same input always
///      produces the same output without depending on whatever the
///      renderer happens to be using for its defaults that frame.
/// The renderer applies the swap once, just before drawing.
public struct StyledRun: Equatable, Sendable {
    /// Concatenated grapheme clusters for the cells in this run. Wide-tail
    /// cells contribute nothing here (their glyph is drawn by the
    /// preceding wide cell), but they DO extend `endColumn` so the
    /// background pass paints their cell.
    public var text: String
    /// nil means "use the renderer's default foreground". Otherwise an
    /// explicit truecolor value resolved by libghostty.
    public var foregroundRGB: GhosttyRGB?
    /// nil means "use the renderer's default background".
    public var backgroundRGB: GhosttyRGB?
    public var bold: Bool
    public var italic: Bool
    /// True iff `underlineStyle != .none`. Kept for ergonomic access at
    /// callsites that don't care which underline variant they got.
    public var underline: Bool
    /// Underline visual style (single, double, curly, dotted, dashed, none).
    public var underlineStyle: GhosttyUnderlineStyle
    /// Explicit underline color (SGR 58). nil = "use foreground".
    public var underlineColor: GhosttyRGB?
    public var strikethrough: Bool
    /// SGR 7 (reverse video). The renderer swaps fg/bg at draw time.
    public var inverse: Bool
    /// SGR 2 — dimmed glyph (drawn at reduced alpha by the renderer).
    public var faint: Bool
    /// SGR 5/6 — blinking glyph (renderer currently does not animate).
    public var blink: Bool
    /// SGR 8 — invisible glyph (renderer skips the draw).
    public var invisible: Bool
    /// SGR 53 — overline (1-px line at the top of each cell).
    public var overline: Bool
    /// OSC 8 hyperlink URI for this run, or nil. Always nil today (the
    /// libghostty-vt render-state API does not expose this per-cell);
    /// the field is here so future interactive-hyperlink work doesn't
    /// have to widen the type.
    public var hyperlinkURI: String?
    /// OSC 133 semantic-content tag for every cell in this run.
    /// A run never spans across a semantic transition: the coalescer
    /// starts a fresh run whenever the tag changes. The renderer uses
    /// this to detect output → prompt transitions at the row level
    /// (a row's first non-blank run carries the row's "leading" tag).
    public var semanticContent: GhosttySemanticContent
    /// Inclusive start column.
    public var startColumn: Int
    /// Exclusive end column. `endColumn - startColumn` is the number of
    /// terminal cells covered by this run (which may be greater than the
    /// number of grapheme clusters in `text` when wide characters or
    /// wide-tail cells are involved).
    public var endColumn: Int

    public init(
        text: String,
        foregroundRGB: GhosttyRGB? = nil,
        backgroundRGB: GhosttyRGB? = nil,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        strikethrough: Bool = false,
        inverse: Bool = false,
        faint: Bool = false,
        blink: Bool = false,
        invisible: Bool = false,
        overline: Bool = false,
        underlineStyle: GhosttyUnderlineStyle? = nil,
        underlineColor: GhosttyRGB? = nil,
        hyperlinkURI: String? = nil,
        semanticContent: GhosttySemanticContent = .output,
        startColumn: Int,
        endColumn: Int
    ) {
        self.text = text
        self.foregroundRGB = foregroundRGB
        self.backgroundRGB = backgroundRGB
        self.bold = bold
        self.italic = italic
        let resolved: GhosttyUnderlineStyle
        if let explicit = underlineStyle {
            resolved = explicit
        } else {
            resolved = underline ? .single : .none
        }
        self.underlineStyle = resolved
        self.underline = (resolved != .none)
        self.underlineColor = underlineColor
        self.strikethrough = strikethrough
        self.inverse = inverse
        self.faint = faint
        self.blink = blink
        self.invisible = invisible
        self.overline = overline
        self.hyperlinkURI = hyperlinkURI
        self.semanticContent = semanticContent
        self.startColumn = startColumn
        self.endColumn = endColumn
    }
}

/// Pure, AppKit-free run coalescer. Lives in `BentoCore` so the renderer
/// in `Sources/Bento/` can call it AND so the test target can exercise
/// it without dragging in AppKit.
public enum TerminalRunCoalescer {

    /// Walk a single row of cells left-to-right and merge consecutive
    /// cells that share the same style into a single `StyledRun`.
    ///
    /// Wide-character handling: a "wide tail" cell (the right half of a
    /// CJK character) is folded into the preceding cell's run. We do
    /// NOT emit it as a standalone run, even when its style differs from
    /// the wide cell's style — the orchestrator's contract is that the
    /// wide cell's glyph and background cover both columns. We extend
    /// `endColumn` so the background pass paints the full footprint of
    /// the wide character. We also do not contribute the tail's text
    /// (which is conventionally empty) to the run's `text`.
    ///
    /// Wide tail at the start of a row (no preceding cell) is treated as
    /// a regular blank cell; this only happens in degenerate frames but
    /// we don't want to crash on them.
    public static func runs(in row: [GhosttyResolvedCell]) -> [StyledRun] {
        guard !row.isEmpty else { return [] }

        var result: [StyledRun] = []
        result.reserveCapacity(8)

        var current: StyledRun? = nil

        for (column, cell) in row.enumerated() {
            // Wide-tail cells: fold into the previous run if there is
            // one, regardless of the tail's nominal style. The wide cell
            // to the left owns the visuals.
            if cell.isWideTail, current != nil {
                current!.endColumn = column + 1
                continue
            }

            let cellFg = cell.foreground
            let cellBg = cell.background

            if var run = current,
               run.foregroundRGB == cellFg,
               run.backgroundRGB == cellBg,
               run.bold == cell.bold,
               run.italic == cell.italic,
               run.underlineStyle == cell.underlineStyle,
               run.underlineColor == cell.underlineColor,
               run.strikethrough == cell.strikethrough,
               run.inverse == cell.inverse,
               run.faint == cell.faint,
               run.blink == cell.blink,
               run.invisible == cell.invisible,
               run.overline == cell.overline,
               run.hyperlinkURI == cell.hyperlinkURI,
               run.semanticContent == cell.semanticContent {
                run.text.append(cell.text)
                run.endColumn = column + 1
                current = run
            } else {
                if let finished = current {
                    result.append(finished)
                }
                current = StyledRun(
                    text: cell.text,
                    foregroundRGB: cellFg,
                    backgroundRGB: cellBg,
                    bold: cell.bold,
                    italic: cell.italic,
                    strikethrough: cell.strikethrough,
                    inverse: cell.inverse,
                    faint: cell.faint,
                    blink: cell.blink,
                    invisible: cell.invisible,
                    overline: cell.overline,
                    underlineStyle: cell.underlineStyle,
                    underlineColor: cell.underlineColor,
                    hyperlinkURI: cell.hyperlinkURI,
                    semanticContent: cell.semanticContent,
                    startColumn: column,
                    endColumn: column + 1
                )
            }
        }

        if let finished = current {
            result.append(finished)
        }
        return result
    }
}

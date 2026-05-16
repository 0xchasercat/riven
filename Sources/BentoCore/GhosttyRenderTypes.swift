import Foundation

/// Pure-data types that flow between `GhosttyBridge` (which talks to the
/// libghostty-vt C render-state API) and `GhosttyRenderer` (which draws
/// the result with CoreText).
///
/// These deliberately have no AppKit dependency so the bridge layer stays
/// testable in isolation and so the renderer can be swapped or rewritten
/// without changing the bridge.

/// 24-bit RGB color. Mirrors `GhosttyColorRgb`.
public struct GhosttyRGB: Equatable, Hashable, Sendable {
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }
}

/// Semantic-content tag for a single cell. Mirrors
/// `GhosttyCellSemanticContent` from
/// `External/ghostty-vt-install/include/ghostty/vt/screen.h`:
///   0 = OUTPUT, 1 = INPUT, 2 = PROMPT.
///
/// Set by libghostty's OSC 133 (semantic prompt) handling — see
/// `scripts/bento-shell-integration.{zsh,bash,fish}` for the markers
/// the shell emits. Cells default to `.output`, which means "not
/// part of a prompt or user input" — i.e. command output (or just
/// idle cells before any integration runs). The renderer uses this
/// to draw a 1-px separator between command blocks (output → prompt
/// transitions). When no shell integration is sourced, every cell is
/// `.output` and no separators ever draw — the right behavior for
/// shells that don't know about OSC 133.
public enum GhosttySemanticContent: UInt8, Sendable, Equatable, Hashable {
    case output = 0
    case input = 1
    case prompt = 2

    /// Map a raw `GhosttyCellSemanticContent` value to the Swift enum.
    /// Unknown values fall back to `.output` because that's the libghostty
    /// default for an uninitialized / never-tagged cell.
    public static func from(raw: Int) -> GhosttySemanticContent {
        switch raw {
        case 1: return .input
        case 2: return .prompt
        default: return .output
        }
    }
}

/// Underline visual style. Mirrors `GhosttySgrUnderline` from
/// `External/ghostty-vt-install/include/ghostty/vt/sgr.h`:
///   0 = NONE, 1 = SINGLE, 2 = DOUBLE, 3 = CURLY,
///   4 = DOTTED, 5 = DASHED.
///
/// The legacy `GhosttyResolvedCell.underline: Bool` is kept as a
/// derived convenience (`underlineStyle != .none`) so existing call
/// sites compile unchanged.
public enum GhosttyUnderlineStyle: Sendable, Equatable, Hashable {
    case none
    case single
    case double
    case curly
    case dotted
    case dashed

    /// Map a raw `style.underline` int (a `GhosttySgrUnderline` value)
    /// to the Swift enum. Unknown values fall back to `.single` because
    /// libghostty has already accepted them as "some underline".
    public static func from(raw: Int) -> GhosttyUnderlineStyle {
        switch raw {
        case 0: return .none
        case 1: return .single
        case 2: return .double
        case 3: return .curly
        case 4: return .dotted
        case 5: return .dashed
        default: return .single
        }
    }
}

/// One terminal cell after libghostty has resolved palette indices and
/// SGR styling into final colors and style flags.
///
/// `foreground` and `background` are nil when the cell uses the
/// terminal's default; the renderer substitutes its own default colors
/// in that case.
public struct GhosttyResolvedCell: Equatable, Hashable, Sendable {
    /// Grapheme cluster for this cell. Empty string for blank cells.
    public let text: String
    public let foreground: GhosttyRGB?
    public let background: GhosttyRGB?
    public let bold: Bool
    public let italic: Bool
    /// Convenience: `underlineStyle != .none`. Pinned for older
    /// callers that only care whether the cell is underlined at all.
    public let underline: Bool
    public let strikethrough: Bool
    public let inverse: Bool
    /// True for the trailing half of a wide (CJK) character; the renderer
    /// must not draw glyphs for these (the wide cell to the left already
    /// covers them).
    public let isWideTail: Bool

    // MARK: - SGR additions

    /// SGR 2 — dimmed text. Renderer draws the glyph at reduced alpha.
    public let faint: Bool
    /// SGR 5/6 — blinking text. The renderer currently leaves blinking
    /// glyphs at full opacity (no animation); see `GhosttyRenderer` for
    /// the rationale.
    public let blink: Bool
    /// SGR 8 — invisible text. Renderer skips the glyph but still paints
    /// the background.
    public let invisible: Bool
    /// SGR 53 — overline (a 1-px line at the top of each cell).
    public let overline: Bool
    /// Underline visual style. `.none` matches the legacy `underline = false`.
    public let underlineStyle: GhosttyUnderlineStyle
    /// Explicit underline color (SGR 58). nil = "use foreground".
    public let underlineColor: GhosttyRGB?
    /// OSC 8 hyperlink URI for this cell, or nil if the cell isn't part
    /// of a hyperlink. Currently always nil — the libghostty render-state
    /// API does not expose hyperlink URIs at the row-cells level (the
    /// only path is `ghostty_grid_ref_hyperlink_uri`, which is the slow
    /// per-cell `grid_ref` API we just got off). Wired through the data
    /// model so the future interactive-hyperlink feature has a place to
    /// land without a second contract change.
    public let hyperlinkURI: String?
    /// OSC 133 semantic-content tag — `.output`, `.input`, or `.prompt`.
    /// Defaults to `.output`. Used by the renderer to detect command-block
    /// boundaries (output → prompt) and draw a subtle separator line.
    public let semanticContent: GhosttySemanticContent

    public init(
        text: String,
        foreground: GhosttyRGB? = nil,
        background: GhosttyRGB? = nil,
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
        hyperlinkURI: String? = nil,
        semanticContent: GhosttySemanticContent = .output
    ) {
        self.text = text
        self.foreground = foreground
        self.background = background
        self.bold = bold
        self.italic = italic
        // Resolve `underlineStyle` from either the new explicit param
        // or the legacy `underline: Bool` so old call sites still work.
        let resolvedStyle: GhosttyUnderlineStyle
        if let explicit = underlineStyle {
            resolvedStyle = explicit
        } else {
            resolvedStyle = underline ? .single : .none
        }
        self.underlineStyle = resolvedStyle
        self.underline = (resolvedStyle != .none)
        self.strikethrough = strikethrough
        self.inverse = inverse
        self.isWideTail = isWideTail
        self.faint = faint
        self.blink = blink
        self.invisible = invisible
        self.overline = overline
        self.underlineColor = underlineColor
        self.hyperlinkURI = hyperlinkURI
        self.semanticContent = semanticContent
    }

    /// Convenience: a fully-default empty cell. Useful for tests and as
    /// a placeholder in the render loop.
    public static let blank = GhosttyResolvedCell(text: " ")
}

/// Cursor visual style. Mirrors `GhosttyRenderStateCursorVisualStyle`.
public enum GhosttyCursorVisualStyle: Sendable, Equatable {
    case block
    case bar
    case underline
    case blockHollow
}

/// Cursor state inside a render frame.
public struct GhosttyCursorState: Equatable, Hashable, Sendable {
    public let visible: Bool
    public let blinking: Bool
    public let style: GhosttyCursorVisualStyle
    /// Viewport position in cells. Only meaningful when `visible` is true.
    public let x: UInt16
    public let y: UInt16
    /// Whether the cursor is on the trailing half of a wide character —
    /// the renderer should fill the full wide cell, not just one column.
    public let isOnWideTail: Bool

    public init(
        visible: Bool,
        blinking: Bool,
        style: GhosttyCursorVisualStyle,
        x: UInt16,
        y: UInt16,
        isOnWideTail: Bool = false
    ) {
        self.visible = visible
        self.blinking = blinking
        self.style = style
        self.x = x
        self.y = y
        self.isOnWideTail = isOnWideTail
    }
}

extension GhosttyCursorVisualStyle {
    public static func from(_ raw: Int32) -> GhosttyCursorVisualStyle {
        // Mirrors the GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_* enum
        // (see render.h):
        //   0 = BAR, 1 = BLOCK, 2 = UNDERLINE, 3 = BLOCK_HOLLOW
        switch raw {
        case 0: return .bar
        case 2: return .underline
        case 3: return .blockHollow
        default: return .block
        }
    }
}

/// One complete frame ready to render: dimensions, default colors, the
/// cell grid, and cursor state. The renderer draws this verbatim.
public struct GhosttyRenderFrame: Equatable, Sendable {
    public let cols: UInt16
    public let rows: UInt16
    public let defaultForeground: GhosttyRGB
    public let defaultBackground: GhosttyRGB
    public let cursor: GhosttyCursorState
    /// 2D cell grid. Outer index is the row (0 = top), inner is the
    /// column (0 = left). Always rectangular: every row has `cols` cells.
    public let cells: [[GhosttyResolvedCell]]

    public init(
        cols: UInt16,
        rows: UInt16,
        defaultForeground: GhosttyRGB,
        defaultBackground: GhosttyRGB,
        cursor: GhosttyCursorState,
        cells: [[GhosttyResolvedCell]]
    ) {
        self.cols = cols
        self.rows = rows
        self.defaultForeground = defaultForeground
        self.defaultBackground = defaultBackground
        self.cursor = cursor
        self.cells = cells
    }

    /// True iff at least one cell in the grid has `blink == true`. The
    /// host view uses this to decide whether to keep a redraw timer
    /// armed for SGR 5/6 animation — when nothing's blinking, no timer
    /// fires and CPU stays at zero.
    ///
    /// Scans cells in row-major order and short-circuits on the first
    /// hit, so the common no-blink case is `O(rows × cols)` worst-case
    /// and `O(1)` in practice once a blink cell is seen.
    public var hasBlinkingContent: Bool {
        for row in cells {
            for cell in row where cell.blink && !cell.isWideTail {
                return true
            }
        }
        return false
    }

    /// An empty frame of the given size. Mostly useful for tests and as
    /// a "before-first-update" placeholder.
    public static func empty(
        cols: UInt16,
        rows: UInt16,
        defaultForeground: GhosttyRGB = GhosttyRGB(r: 220, g: 220, b: 220),
        defaultBackground: GhosttyRGB = GhosttyRGB(r: 18, g: 18, b: 18)
    ) -> GhosttyRenderFrame {
        let row = Array(repeating: GhosttyResolvedCell.blank, count: Int(cols))
        let cells = Array(repeating: row, count: Int(rows))
        return GhosttyRenderFrame(
            cols: cols,
            rows: rows,
            defaultForeground: defaultForeground,
            defaultBackground: defaultBackground,
            cursor: GhosttyCursorState(
                visible: false,
                blinking: false,
                style: .block,
                x: 0,
                y: 0
            ),
            cells: cells
        )
    }
}

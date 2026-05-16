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
    public let underline: Bool
    public let strikethrough: Bool
    public let inverse: Bool
    /// True for the trailing half of a wide (CJK) character; the renderer
    /// must not draw glyphs for these (the wide cell to the left already
    /// covers them).
    public let isWideTail: Bool

    public init(
        text: String,
        foreground: GhosttyRGB? = nil,
        background: GhosttyRGB? = nil,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        strikethrough: Bool = false,
        inverse: Bool = false,
        isWideTail: Bool = false
    ) {
        self.text = text
        self.foreground = foreground
        self.background = background
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strikethrough = strikethrough
        self.inverse = inverse
        self.isWideTail = isWideTail
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

import AppKit
import BentoCore
import CoreText
import Foundation

/// Stateless CoreText draw helper shared by the in-process
/// (`GhosttyTerminalView`) and broker-backed (`BrokeredTerminalView`)
/// terminal views.
///
/// The renderer consumes a fully-resolved `GhosttyRenderFrame` produced
/// by `GhosttyBridge` and paints it into a `CGContext`. Per-cell SGR
/// styling is honored: bold and italic resolve to font variants via
/// `NSFontManager.convert(_:toHaveTrait:)`, strikethrough flows through
/// an `NSAttributedString` attribute, inverse swaps fg/bg at draw time,
/// and a styled cursor is overlaid in one of four shapes (`block`,
/// `blockHollow`, `bar`, `underline`).
///
/// Underline variants (single, double, curly, dotted, dashed) and
/// overline are drawn directly into the context — `NSAttributedString`
/// only knows about a single underline variant. SGR 58 underline color
/// is applied separately from the foreground.
///
/// Per-row coalescing is delegated to `BentoCore.TerminalRunCoalescer`
/// so the pure data path is testable without dragging in AppKit. A row
/// that switches between eight colors becomes ~8 styled `CTLine` draws
/// instead of 80 per-cell draws — that's the main performance win over
/// the previous monochrome implementation.
///
/// SGR semantics worth pinning down:
/// - **faint (SGR 2)** — glyph drawn at 60% alpha of its resolved
///   foreground (after inverse resolution).
/// - **invisible (SGR 8)** — glyph skipped entirely; background and
///   underline/overline are still painted because the cell still
///   "occupies space".
/// - **blink (SGR 5/6)** — currently a no-op visually: the glyph is
///   drawn at full opacity. The renderer is stateless and the views
///   that wrap it don't run a redraw timer, so true animated blink
///   needs a frame-driven repaint scheme that doesn't exist yet. The
///   data flows end-to-end so it's a pure renderer change once the
///   view layer ticks.
/// - **hyperlink (OSC 8)** — the URI is wired through the data model
///   (so it's available to the future hover/click feature) but the
///   renderer doesn't currently style hyperlinked text differently.
///
/// The renderer holds zero state between frames; everything it needs is
/// passed in as parameters. Callers cache `TerminalCellMetrics` and the
/// `TerminalRenderConfiguration` themselves.
@MainActor
enum GhosttyRenderer {

    // MARK: - Public configuration

    /// Theme overrides + font selection. The theme's foreground and
    /// background only apply to cells whose libghostty-resolved color
    /// is `nil` (i.e., the cell is using the terminal default). Cells
    /// that carry an explicit RGB are drawn with that exact RGB — we
    /// never second-guess libghostty when it tells us the program asked
    /// for SGR 38;2;r;g;b. This matches what every other terminal does
    /// and is the only sensible behavior for `ls --color`, vim themes,
    /// etc.
    struct TerminalRenderConfiguration: Sendable {
        var defaultForeground: NSColor
        var defaultBackground: NSColor
        var cursorColor: NSColor
        var fontSize: CGFloat
        var fontName: String?

        init(
            defaultForeground: NSColor,
            defaultBackground: NSColor,
            cursorColor: NSColor,
            fontSize: CGFloat,
            fontName: String? = nil
        ) {
            self.defaultForeground = defaultForeground
            self.defaultBackground = defaultBackground
            self.cursorColor = cursorColor
            self.fontSize = fontSize
            self.fontName = fontName
        }
    }

    /// Cached per-cell sizing. The owning view computes these from its
    /// font once (and recomputes on font/size changes) so the renderer
    /// doesn't re-measure every frame.
    struct TerminalCellMetrics: Sendable {
        var cellWidth: CGFloat
        var cellHeight: CGFloat
        var ascent: CGFloat

        init(cellWidth: CGFloat, cellHeight: CGFloat, ascent: CGFloat) {
            self.cellWidth = cellWidth
            self.cellHeight = cellHeight
            self.ascent = ascent
        }
    }

    // MARK: - Entry point

    /// Draw `frame` into `ctx`, filling `bounds` (which is assumed to be
    /// the bounds of an `isFlipped == true` NSView, so y=0 is at the top).
    ///
    /// Pipeline:
    ///   1. Fill `bounds` with `configuration.defaultBackground`.
    ///   2. Per row, coalesce cells into `[StyledRun]`.
    ///   3. Pass 1: paint per-run backgrounds (skipped when the run uses
    ///      the default background — already painted by step 1).
    ///   4. Pass 2: build one `NSAttributedString` per run and draw it
    ///      as a single `CTLine` at the row's baseline.
    ///   5. Cursor overlay, in the shape requested by `frame.cursor`.
    static func draw(
        frame: GhosttyRenderFrame,
        configuration: TerminalRenderConfiguration,
        metrics: TerminalCellMetrics,
        in ctx: CGContext,
        bounds: NSRect
    ) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        // 1. Background.
        ctx.setFillColor(configuration.defaultBackground.cgColor)
        ctx.fill(bounds)

        let cellWidth = metrics.cellWidth
        let cellHeight = metrics.cellHeight
        let ascent = metrics.ascent

        // Resolve the active font once; bold/italic variants are derived
        // from it lazily inside the row loop.
        let baseFont = Self.resolveFont(
            name: configuration.fontName,
            size: configuration.fontSize
        )

        // Cache for run-color → NSColor conversions inside the frame.
        // Every row is processed fresh, but within a frame the same
        // RGB shows up dozens of times (e.g. one syntax theme color
        // across an entire file). Caching saves a lot of NSColor
        // allocations.
        var colorCache = ColorCache()

        // 2 + 3 + 4. Per-row passes.
        ctx.textMatrix = .identity
        for (rowIdx, row) in frame.cells.enumerated() {
            let runs = TerminalRunCoalescer.runs(in: row)
            let yTop = CGFloat(rowIdx) * cellHeight

            // Pass 1: backgrounds. Skip runs whose effective background
            // is the renderer's default — `bounds` is already that color.
            for run in runs {
                let (_, bg) = effectiveColors(
                    for: run,
                    configuration: configuration,
                    frame: frame,
                    cache: &colorCache
                )
                let isDefaultBg = (bg == configuration.defaultBackground)
                guard !isDefaultBg else { continue }
                let rect = NSRect(
                    x: CGFloat(run.startColumn) * cellWidth,
                    y: yTop,
                    width: CGFloat(run.endColumn - run.startColumn) * cellWidth,
                    height: cellHeight
                )
                ctx.setFillColor(bg.cgColor)
                ctx.fill(rect)
            }

            // Pass 2: glyphs. Build one CTLine per run. Skip empty-text
            // runs (which can happen when a row consists entirely of
            // wide-tail or zero-width cells — extremely rare but cheap
            // to guard).
            for run in runs {
                let (fg, _) = effectiveColors(
                    for: run,
                    configuration: configuration,
                    frame: frame,
                    cache: &colorCache
                )

                // Resolve the underline / overline color: explicit SGR 58
                // wins, otherwise the run's foreground (after inverse
                // resolution).
                let lineColor: NSColor
                if let rgb = run.underlineColor {
                    lineColor = colorCache.color(for: rgb)
                } else {
                    lineColor = fg
                }

                // Decorations (underline variants + overline) draw
                // independently of the glyph; they cover the run's
                // full column footprint, including wide-tail and any
                // invisible cells.
                let runOriginX = CGFloat(run.startColumn) * cellWidth
                let runWidth = CGFloat(run.endColumn - run.startColumn) * cellWidth

                if run.overline {
                    drawOverline(
                        x: runOriginX,
                        y: yTop,
                        width: runWidth,
                        color: lineColor,
                        in: ctx
                    )
                }

                if run.underlineStyle != .none {
                    drawUnderline(
                        style: run.underlineStyle,
                        x: runOriginX,
                        yTop: yTop,
                        width: runWidth,
                        cellHeight: cellHeight,
                        cellWidth: cellWidth,
                        color: lineColor,
                        in: ctx
                    )
                }

                // SGR 8 invisible: skip the glyph entirely. Background
                // (above) and decorations (just rendered) are still
                // honored.
                guard !run.invisible else { continue }
                guard !run.text.isEmpty else { continue }

                // SGR 2 faint: dim the glyph color to 60% alpha. This is
                // applied AFTER inverse resolution so a faint+inverse
                // cell dims its (swapped) foreground rather than the
                // original.
                let glyphColor = run.faint
                    ? fg.withAlphaComponent(0.6)
                    : fg

                let runFont = Self.font(
                    base: baseFont,
                    bold: run.bold,
                    italic: run.italic
                )

                // Underline + strikethrough on the attributed string
                // would draw a single straight line — we already
                // hand-drew the underline above (so we get the right
                // style), so don't ask CoreText to draw another. We
                // keep the strikethrough attribute because there's
                // only one variant.
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: runFont,
                    .foregroundColor: glyphColor,
                ]
                if run.strikethrough {
                    attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    attrs[.strikethroughColor] = glyphColor
                }

                let attr = NSAttributedString(string: run.text, attributes: attrs)
                let ctLine = CTLineCreateWithAttributedString(attr)

                let baselineFromTop = yTop + ascent

                ctx.saveGState()
                ctx.translateBy(x: runOriginX, y: baselineFromTop)
                ctx.scaleBy(x: 1, y: -1)
                ctx.textPosition = .zero
                CTLineDraw(ctLine, ctx)
                ctx.restoreGState()
            }
        }

        // 5. Cursor.
        drawCursor(
            cursor: frame.cursor,
            configuration: configuration,
            metrics: metrics,
            frame: frame,
            ctx: ctx,
            baseFont: baseFont,
            colorCache: &colorCache
        )
    }

    // MARK: - Color resolution

    /// Resolve `(foreground, background)` for a run, accounting for
    /// nil → theme defaults and for `inverse` (which swaps the two at
    /// draw time, after defaults are applied).
    private static func effectiveColors(
        for run: StyledRun,
        configuration: TerminalRenderConfiguration,
        frame: GhosttyRenderFrame,
        cache: inout ColorCache
    ) -> (foreground: NSColor, background: NSColor) {
        let fg: NSColor
        if let rgb = run.foregroundRGB {
            fg = cache.color(for: rgb)
        } else {
            // Theme override: the explicit theme foreground always wins
            // over the libghostty-reported default. This is what users
            // expect when they pick a theme color in Bento — it should
            // actually show up.
            fg = configuration.defaultForeground
        }
        let bg: NSColor
        if let rgb = run.backgroundRGB {
            bg = cache.color(for: rgb)
        } else {
            bg = configuration.defaultBackground
        }
        if run.inverse {
            return (bg, fg)
        }
        return (fg, bg)
    }

    /// Convert one cell's foreground/background plus its style flags into
    /// concrete `NSColor`s. Used by the cursor overlay (which doesn't
    /// have a `StyledRun` to work from).
    private static func effectiveCellColors(
        cell: GhosttyResolvedCell,
        configuration: TerminalRenderConfiguration,
        cache: inout ColorCache
    ) -> (foreground: NSColor, background: NSColor) {
        let fg: NSColor = cell.foreground.map { cache.color(for: $0) }
            ?? configuration.defaultForeground
        let bg: NSColor = cell.background.map { cache.color(for: $0) }
            ?? configuration.defaultBackground
        if cell.inverse {
            return (bg, fg)
        }
        return (fg, bg)
    }

    // MARK: - Cursor

    private static func drawCursor(
        cursor: GhosttyCursorState,
        configuration: TerminalRenderConfiguration,
        metrics: TerminalCellMetrics,
        frame: GhosttyRenderFrame,
        ctx: CGContext,
        baseFont: NSFont,
        colorCache: inout ColorCache
    ) {
        guard cursor.visible else { return }
        // Cursor outside the visible grid: bail rather than crash. The
        // bridge clamps in practice but defensive bounds checks here
        // keep the renderer robust against contract drift.
        guard cursor.y < frame.cells.count else { return }
        let row = frame.cells[Int(cursor.y)]
        guard cursor.x < row.count else { return }
        let cell = row[Int(cursor.x)]

        let cellWidth = metrics.cellWidth
        let cellHeight = metrics.cellHeight

        // Wide tail: render the cursor over BOTH columns so the user
        // sees a cursor that matches the wide character's footprint.
        let cursorWidthCells: CGFloat = cursor.isOnWideTail ? 2 : 1
        let cursorOriginX: CGFloat
        if cursor.isOnWideTail && cursor.x > 0 {
            cursorOriginX = CGFloat(cursor.x - 1) * cellWidth
        } else {
            cursorOriginX = CGFloat(cursor.x) * cellWidth
        }
        let cellRect = NSRect(
            x: cursorOriginX,
            y: CGFloat(cursor.y) * cellHeight,
            width: cellWidth * cursorWidthCells,
            height: cellHeight
        )

        let cursorColor = configuration.cursorColor

        switch cursor.style {
        case .block:
            // Fill the cell with the cursor color, then re-draw the
            // cell's glyph in the inverse color so it stays legible.
            ctx.setFillColor(cursorColor.cgColor)
            ctx.fill(cellRect)
            if !cell.text.isEmpty {
                let (fg, _) = effectiveCellColors(
                    cell: cell,
                    configuration: configuration,
                    cache: &colorCache
                )
                let glyphColor = inverseColor(of: cursorColor, fallback: fg)
                drawGlyph(
                    cell.text,
                    color: glyphColor,
                    font: Self.font(base: baseFont, bold: cell.bold, italic: cell.italic),
                    originX: cursorOriginX,
                    baselineFromTop: CGFloat(cursor.y) * cellHeight + metrics.ascent,
                    in: ctx
                )
            }

        case .blockHollow:
            ctx.setStrokeColor(cursorColor.cgColor)
            ctx.setLineWidth(1)
            // Inset by 0.5 so the 1px stroke lands on whole pixels.
            let stroked = cellRect.insetBy(dx: 0.5, dy: 0.5)
            ctx.stroke(stroked)

        case .bar:
            let barRect = NSRect(
                x: cellRect.minX,
                y: cellRect.minY,
                width: 2,
                height: cellRect.height
            )
            ctx.setFillColor(cursorColor.cgColor)
            ctx.fill(barRect)

        case .underline:
            let underlineRect = NSRect(
                x: cellRect.minX,
                y: cellRect.maxY - 2,
                width: cellRect.width,
                height: 2
            )
            ctx.setFillColor(cursorColor.cgColor)
            ctx.fill(underlineRect)
        }
    }

    /// Pick a readable foreground for a glyph drawn on top of the
    /// cursor's background fill. We don't try to be clever — a
    /// luminance flip is enough to keep the character legible against
    /// any cursor color the theme picks.
    private static func inverseColor(of color: NSColor, fallback: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return fallback }
        let luminance = 0.2126 * rgb.redComponent
            + 0.7152 * rgb.greenComponent
            + 0.0722 * rgb.blueComponent
        return luminance > 0.5 ? .black : .white
    }

    private static func drawGlyph(
        _ text: String,
        color: NSColor,
        font: NSFont,
        originX: CGFloat,
        baselineFromTop: CGFloat,
        in ctx: CGContext
    ) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attr)
        ctx.saveGState()
        ctx.translateBy(x: originX, y: baselineFromTop)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // MARK: - Decorations (overline / underline variants)

    /// Draw a 1-px overline along the top edge of the run.
    private static func drawOverline(
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        color: NSColor,
        in ctx: CGContext
    ) {
        // 0.5 inset so the 1-px stroke lands on whole pixels.
        let rect = NSRect(x: x, y: y + 0.5, width: width, height: 1)
        ctx.setFillColor(color.cgColor)
        ctx.fill(rect)
    }

    /// Draw an underline of the requested SGR style under a run.
    /// Single uses a 1-px line at the bottom of the cell; double stacks
    /// two; curly is a sine-wave squiggle (the standard for spell-check);
    /// dotted is 1-px on / 1-px off; dashed is 3-px on / 2-px off.
    ///
    /// Visual quirk: at very small font sizes a curly underline can
    /// degenerate into a near-straight line because there's only ~2 px
    /// of vertical space between the baseline descent and the cell
    /// bottom. That's expected — the squiggle's amplitude is tied to
    /// the available space.
    private static func drawUnderline(
        style: GhosttyUnderlineStyle,
        x: CGFloat,
        yTop: CGFloat,
        width: CGFloat,
        cellHeight: CGFloat,
        cellWidth: CGFloat,
        color: NSColor,
        in ctx: CGContext
    ) {
        guard style != .none, width > 0 else { return }

        // Baseline of the underline: 1-px above the bottom of the cell.
        let yBaseline = yTop + cellHeight - 1.5

        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(1)

        switch style {
        case .none:
            return

        case .single:
            ctx.fill(NSRect(x: x, y: yBaseline, width: width, height: 1))

        case .double:
            // Two parallel 1-px lines, 1 px apart. Place them so the
            // pair sits inside the cell — the lower one at the
            // standard underline position, the upper one 2 px above.
            ctx.fill(NSRect(x: x, y: yBaseline, width: width, height: 1))
            ctx.fill(NSRect(x: x, y: yBaseline - 2, width: width, height: 1))

        case .curly:
            // Sine-wave squiggle: one full period per cell column. We
            // approximate the sine with two quad curves per period
            // (peak above, trough below) which is cheap and looks
            // smooth at typical terminal sizes.
            let amplitude: CGFloat = 1.5
            let midY = yBaseline + 0.5
            let period = max(cellWidth, 4)
            let halfPeriod = period / 2
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x, y: midY))
            var cx = x
            var goingUp = true
            while cx < x + width {
                let nextX = min(cx + halfPeriod, x + width)
                let controlX = cx + halfPeriod / 2
                let controlY = goingUp ? midY - amplitude : midY + amplitude
                path.addQuadCurve(
                    to: CGPoint(x: nextX, y: midY),
                    control: CGPoint(x: controlX, y: controlY)
                )
                cx = nextX
                goingUp.toggle()
            }
            ctx.addPath(path)
            ctx.strokePath()

        case .dotted:
            // 1 px on / 1 px off, walked across the run.
            var dx = x
            while dx < x + width {
                ctx.fill(NSRect(x: dx, y: yBaseline, width: 1, height: 1))
                dx += 2
            }

        case .dashed:
            // 3 px on / 2 px off.
            let onLen: CGFloat = 3
            let offLen: CGFloat = 2
            var dx = x
            while dx < x + width {
                let segLen = min(onLen, x + width - dx)
                ctx.fill(NSRect(x: dx, y: yBaseline, width: segLen, height: 1))
                dx += onLen + offLen
            }
        }
    }

    // MARK: - Font resolution

    /// Resolve the base font: explicit name → SFMono-Regular → Menlo →
    /// monospaced system. Mirrors what the live views do today; kept
    /// here so the renderer is self-contained for callers that don't
    /// pre-resolve a font.
    private static func resolveFont(name: String?, size: CGFloat) -> NSFont {
        if let name, let f = NSFont(name: name, size: size) { return f }
        if let sfMono = NSFont(name: "SFMono-Regular", size: size) { return sfMono }
        if let menlo = NSFont(name: "Menlo", size: size) { return menlo }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Apply bold + italic traits to `base` via `NSFontManager`. If a
    /// requested variant doesn't exist for the chosen typeface (e.g.
    /// SFMono-Regular has no italic), `convert(_:toHaveTrait:)` returns
    /// the closest available font, which is fine — we'd rather draw an
    /// upright glyph than throw.
    private static func font(base: NSFont, bold: Bool, italic: Bool) -> NSFont {
        var f = base
        let manager = NSFontManager.shared
        if bold {
            f = manager.convert(f, toHaveTrait: .boldFontMask)
        }
        if italic {
            f = manager.convert(f, toHaveTrait: .italicFontMask)
        }
        return f
    }

    // MARK: - Color cache

    /// Cheap per-frame `GhosttyRGB` → `NSColor` cache. Building an
    /// `NSColor` for every cell would be wasteful (`ls --color` outputs
    /// the same handful of palette entries hundreds of times per frame).
    /// We use sRGB explicitly so colors don't drift through whatever the
    /// CGContext's working colorspace happens to be.
    private struct ColorCache {
        private var entries: [GhosttyRGB: NSColor] = [:]

        mutating func color(for rgb: GhosttyRGB) -> NSColor {
            if let existing = entries[rgb] {
                return existing
            }
            let made = NSColor(
                srgbRed: CGFloat(rgb.r) / 255,
                green: CGFloat(rgb.g) / 255,
                blue: CGFloat(rgb.b) / 255,
                alpha: 1
            )
            entries[rgb] = made
            return made
        }
    }
}

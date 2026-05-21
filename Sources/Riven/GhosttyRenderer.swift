import AppKit
import RivenCore
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
/// Per-row coalescing is delegated to `RivenCore.TerminalRunCoalescer`
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
        /// Color used to draw the 1-px separator line at command-block
        /// boundaries (OSC 133 output → prompt transitions). Should be
        /// `theme.chrome.border` at low alpha so the line is subtle.
        /// When the shell has no integration sourced, no cells are
        /// tagged as `.prompt` so the separator never draws.
        var blockSeparator: NSColor
        /// Multiplier applied to the glyph alpha of cells with `blink ==
        /// true`. 1.0 = fully ON (indistinguishable from non-blink), 0.0
        /// = fully invisible. The host view computes this from a system
        /// clock (~500 ms half-cycle) and passes it on each draw. When
        /// no cell on the frame has `blink`, this value has no effect.
        var blinkAlpha: CGFloat
        /// Active text selection, or nil when nothing is selected. The
        /// renderer paints `selectionColor` over the cells covered by
        /// this range between the background pass and the glyph pass,
        /// so the underlying glyphs stay legible. Coordinates are
        /// inclusive cell indices in reading order (start <= end).
        var selection: SelectionRange?
        /// Translucent fill for the selection overlay. Typically the
        /// theme's `chrome.selectionBg` token — Amber's amber-22%,
        /// Tokyo's violet-15%, etc.
        var selectionColor: NSColor

        init(
            defaultForeground: NSColor,
            defaultBackground: NSColor,
            cursorColor: NSColor,
            fontSize: CGFloat,
            fontName: String? = nil,
            blockSeparator: NSColor? = nil,
            blinkAlpha: CGFloat = 1.0,
            selection: SelectionRange? = nil,
            selectionColor: NSColor = NSColor(white: 1.0, alpha: 0.15)
        ) {
            self.defaultForeground = defaultForeground
            self.defaultBackground = defaultBackground
            self.cursorColor = cursorColor
            self.fontSize = fontSize
            self.fontName = fontName
            // Default: the renderer's foreground at very low alpha. Callers
            // that have a theme.chrome.border value should pass it through
            // (also at low alpha) — this default just keeps things sensible
            // for callers that don't know about block separators yet.
            //
            // H6: alpha lowered 0.18 → 0.10 so the per-block divider reads
            // as a subtle cue rather than a hard rule. Callers that pass
            // an explicit `blockSeparator` still own their own alpha.
            self.blockSeparator = blockSeparator
                ?? defaultForeground.withAlphaComponent(0.10)
            // Clamp defensively so a misbehaving host doesn't blow past
            // 0..1 and produce a negative-alpha glyph.
            self.blinkAlpha = max(0, min(1, blinkAlpha))
            self.selection = selection
            self.selectionColor = selectionColor
        }
    }

    /// Inclusive cell range painted by the selection overlay pass.
    /// Two callers: `BrokeredTerminalView` (drag-to-select) and any
    /// future "select all" / programmatic-highlight feature.
    struct SelectionRange: Equatable, Sendable {
        var startRow: Int
        var startCol: Int
        var endRow: Int
        var endCol: Int
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

        // H5: Pin glyph rasterization knobs on the context so subpixel
        // positioning is deterministic across window positions. Without
        // these, CoreText inherits whatever the layer-backed view's host
        // CGContext was configured with, which can shift glyphs by a
        // half pixel as the window moves — that reads as "shimmer" on
        // scroll. Disabling subpixel positioning snaps every glyph to
        // integer x, which keeps wide runs pixel-aligned (this is the
        // same trade Warp makes).
        ctx.setShouldAntialias(true)
        ctx.setAllowsFontSubpixelPositioning(false)
        ctx.setShouldSubpixelPositionFonts(false)

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

        // 2 + 3 + 4. Per-row passes. We pre-coalesce all rows once so the
        // separator pass (which compares row N's leading semantic against
        // row N-1's trailing semantic) doesn't have to re-coalesce.
        ctx.textMatrix = .identity
        let perRowRuns: [[StyledRun]] = frame.cells.map { TerminalRunCoalescer.runs(in: $0) }

        // Pre-compute the selection rects (one per covered row). The
        // selection passes draws BEFORE the per-row backgrounds get
        // their own overlays so a translucent selection tint blends
        // cleanly across mixed-color runs. Multi-row selections produce
        // up to three rects: a partial first row, full middle rows
        // (drawn as one combined rect), and a partial last row.
        let selectionRects = computeSelectionRects(
            selection: configuration.selection,
            frame: frame,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            viewWidth: bounds.width
        )
        if !selectionRects.isEmpty {
            ctx.setFillColor(configuration.selectionColor.cgColor)
            for rect in selectionRects { ctx.fill(rect) }
        }

        for (rowIdx, row) in frame.cells.enumerated() {
            let runs = perRowRuns[rowIdx]
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

            // Pass 1.5: block separator (OSC 133 output → prompt).
            //
            // Draw a 1-px line along the TOP edge of row N when the row's
            // leading non-blank semantic is `.prompt` AND the previous
            // row's trailing non-blank semantic is `.output`. The line
            // sits between backgrounds and glyphs so cell backgrounds
            // don't paint over it. Width spans the full terminal so the
            // visual rhythm matches the row grid.
            //
            // No-shell-integration case is implicit: every cell defaults
            // to `.output` and `leadingSemantic` never returns `.prompt`,
            // so nothing draws.
            if rowIdx > 0,
               let leading = leadingSemantic(runs: runs, cells: row),
               leading == .prompt,
               let trailing = trailingSemantic(
                   runs: perRowRuns[rowIdx - 1],
                   cells: frame.cells[rowIdx - 1]
               ),
               trailing == .output {
                let sepRect = NSRect(
                    x: 0,
                    y: yTop,
                    width: bounds.width,
                    height: 1
                )
                ctx.setFillColor(configuration.blockSeparator.cgColor)
                ctx.fill(sepRect)
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
                //
                // SGR 5/6 blink: multiply the resulting alpha by
                // configuration.blinkAlpha (1.0 on the OFF phase boundary
                // means no animation — see TerminalRenderConfiguration).
                var glyphAlpha: CGFloat = run.faint ? 0.6 : 1.0
                if run.blink {
                    glyphAlpha *= configuration.blinkAlpha
                }
                let glyphColor: NSColor = (glyphAlpha < 0.999)
                    ? fg.withAlphaComponent(glyphAlpha)
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

    // MARK: - Block-separator detection

    /// The semantic-content tag of the row's first non-blank cell, or
    /// nil if the row is entirely blank. Used to detect output → prompt
    /// transitions for the block separator. We walk the cell array rather
    /// than the runs because a blank cell still carries a semantic tag,
    /// and runs are coalesced by tag — but we want the visually-first
    /// printable cell to decide a row's character.
    ///
    /// "Blank" here means an empty grapheme or a literal space with no
    /// background color override: those cells are usually just padding
    /// between commands and shouldn't drive the boundary.
    /// Translate an inclusive `SelectionRange` into 1–3 fill rects,
    /// one per covered row (or one combined rect for full-width
    /// middle rows). Returns empty for a nil / empty selection.
    ///
    /// Coordinate space: the renderer's frame, with y=0 at the top
    /// (the host pinned `isFlipped = true` so AppKit's bottom-origin
    /// math doesn't apply). Cells outside the frame are clipped.
    private static func computeSelectionRects(
        selection: SelectionRange?,
        frame: GhosttyRenderFrame,
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        viewWidth: CGFloat
    ) -> [NSRect] {
        guard let sel = selection,
              !frame.cells.isEmpty,
              sel.startRow <= sel.endRow,
              sel.startRow < frame.cells.count else { return [] }

        let firstRow = max(0, sel.startRow)
        let lastRow = min(sel.endRow, frame.cells.count - 1)
        guard firstRow <= lastRow else { return [] }

        var rects: [NSRect] = []
        for rowIdx in firstRow...lastRow {
            let row = frame.cells[rowIdx]
            let rowWidthCols = max(0, row.count)
            let firstCol: Int
            let lastCol: Int
            if rowIdx == sel.startRow && rowIdx == sel.endRow {
                // Single-row selection.
                firstCol = max(0, min(sel.startCol, sel.endCol))
                lastCol = max(sel.startCol, sel.endCol)
            } else if rowIdx == sel.startRow {
                firstCol = max(0, sel.startCol)
                lastCol = max(0, rowWidthCols - 1)
            } else if rowIdx == sel.endRow {
                firstCol = 0
                lastCol = max(0, sel.endCol)
            } else {
                // Middle row — full width.
                firstCol = 0
                lastCol = max(0, rowWidthCols - 1)
            }
            // Inclusive col span → width of (last - first + 1) cells.
            let widthCols = lastCol - firstCol + 1
            guard widthCols > 0 else { continue }
            // Middle rows + the trailing edge of multi-row selections
            // extend to the full viewport width so the highlight looks
            // like a continuous block, the way every other terminal
            // renders text selection.
            let extendToEdge = (rowIdx != sel.endRow) || (rowIdx != sel.startRow && rowIdx < sel.endRow)
            let x = CGFloat(firstCol) * cellWidth
            let width: CGFloat
            if extendToEdge {
                width = max(viewWidth - x, CGFloat(widthCols) * cellWidth)
            } else {
                width = CGFloat(widthCols) * cellWidth
            }
            rects.append(NSRect(
                x: x,
                y: CGFloat(rowIdx) * cellHeight,
                width: width,
                height: cellHeight
            ))
        }
        return rects
    }

    private static func leadingSemantic(
        runs: [StyledRun],
        cells: [GhosttyResolvedCell]
    ) -> GhosttySemanticContent? {
        for cell in cells {
            if cellIsPrintable(cell) {
                return cell.semanticContent
            }
        }
        // Fall back to runs: if every cell was "blank" but a run still
        // exists with a prompt/input tag (e.g. a colored-background
        // prompt block with spaces), honor the first run's tag.
        return runs.first?.semanticContent
    }

    /// The semantic-content tag of the row's last non-blank cell. Mirror
    /// of `leadingSemantic` but walking backwards.
    private static func trailingSemantic(
        runs: [StyledRun],
        cells: [GhosttyResolvedCell]
    ) -> GhosttySemanticContent? {
        for cell in cells.reversed() {
            if cellIsPrintable(cell) {
                return cell.semanticContent
            }
        }
        return runs.last?.semanticContent
    }

    /// Cell counts as printable for boundary detection when it has visible
    /// text or a non-default background. Wide tails follow their leading
    /// cell so we deliberately skip them — the wide cell already decided
    /// the boundary for both columns.
    private static func cellIsPrintable(_ cell: GhosttyResolvedCell) -> Bool {
        if cell.isWideTail { return false }
        if cell.background != nil { return true }
        let trimmed = cell.text.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty
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
            // expect when they pick a theme color in Riven — it should
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

        // H4: when DECTCEM blink is OFF, draw a 1-px inner outline at the
        // cursor color plus a 40% fill so the cursor reads as "input is
        // here" without screaming. When blink is ON, multiply the fill
        // alpha by `configuration.blinkAlpha` so the cursor animates in
        // lockstep with SGR 5/6 cells (same wall-clock signal).
        //
        // The `.blockHollow` cursor style is left alone — it's already an
        // outline by definition, and the user explicitly asked for it
        // (e.g. unfocused window), so we shouldn't second-guess the
        // shape. Block / bar / underline all get the fade.
        let blinkMultiplier: CGFloat = cursor.blinking ? configuration.blinkAlpha : 1.0
        // Steady-state outline alpha for non-blink cursors. 0.4 fill +
        // 1-px outline is the "subtle but present" look.
        let steadyFillAlpha: CGFloat = 0.4
        let fillAlpha: CGFloat = cursor.blinking
            ? blinkMultiplier
            : steadyFillAlpha
        let outlineColor: NSColor = cursor.blinking
            ? cursorColor.withAlphaComponent(blinkMultiplier)
            : cursorColor

        switch cursor.style {
        case .block:
            // Steady (non-blink) state: subtle fill + 1-px inner outline,
            // and the cell's underlying glyph stays in its normal color
            // so it's still readable. Blink state: a fully-filled block
            // (modulated by blinkAlpha) with an inverse glyph on top —
            // that matches the previous behavior at the ON phase and
            // fades naturally at the OFF phase.
            if cursor.blinking {
                ctx.setFillColor(cursorColor.withAlphaComponent(fillAlpha).cgColor)
                ctx.fill(cellRect)
                if !cell.text.isEmpty {
                    let (fg, _) = effectiveCellColors(
                        cell: cell,
                        configuration: configuration,
                        cache: &colorCache
                    )
                    let glyphColor = inverseColor(of: cursorColor, fallback: fg)
                    // The glyph color also fades with the cursor so it
                    // doesn't pop while the fill is mid-blink.
                    let fadedGlyph = glyphColor.withAlphaComponent(blinkMultiplier)
                    drawGlyph(
                        cell.text,
                        color: fadedGlyph,
                        font: Self.font(base: baseFont, bold: cell.bold, italic: cell.italic),
                        originX: cursorOriginX,
                        baselineFromTop: CGFloat(cursor.y) * cellHeight + metrics.ascent,
                        in: ctx
                    )
                }
            } else {
                // Steady state: 40% fill + 1-px inner outline. The cell's
                // glyph is NOT redrawn — the original draw pass already
                // painted it in its normal color, and the translucent
                // fill lets it show through.
                ctx.setFillColor(cursorColor.withAlphaComponent(fillAlpha).cgColor)
                ctx.fill(cellRect)
                ctx.setStrokeColor(outlineColor.cgColor)
                ctx.setLineWidth(1)
                // Inset by 0.5 so the 1-px stroke lands on whole pixels.
                let stroked = cellRect.insetBy(dx: 0.5, dy: 0.5)
                ctx.stroke(stroked)
            }

        case .blockHollow:
            // Outline-only by definition — left as-is, the shape itself
            // already communicates "unfocused / inactive".
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
            ctx.setFillColor(cursorColor.withAlphaComponent(fillAlpha).cgColor)
            ctx.fill(barRect)

        case .underline:
            let underlineRect = NSRect(
                x: cellRect.minX,
                y: cellRect.maxY - 2,
                width: cellRect.width,
                height: 2
            )
            ctx.setFillColor(cursorColor.withAlphaComponent(fillAlpha).cgColor)
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

    /// Resolve bold + italic variants of `base`.
    ///
    /// H7: SF Mono on macOS ships explicit `SFMono-Bold`,
    /// `SFMono-RegularItalic`, and `SFMono-BoldItalic` faces but they
    /// aren't always discoverable via `NSFontManager.convert(_:toHaveTrait:)`
    /// — that path can silently return the regular face when the font
    /// descriptor registry doesn't have the bold trait wired up for the
    /// active typeface. The user-visible symptom is "SGR 1 doesn't make
    /// text bolder, only brighter".
    ///
    /// Fix is an explicit chain: try the known face names by hand first,
    /// fall back to the trait-convert path so non-SF-Mono typefaces still
    /// work. For bold+italic we also fall back to applying italic on top
    /// of the resolved bold (the typical case for non-SF typefaces with
    /// only a single combined face — `convert` handles that fine).
    private static func font(base: NSFont, bold: Bool, italic: Bool) -> NSFont {
        let size = base.pointSize
        let manager = NSFontManager.shared

        switch (bold, italic) {
        case (false, false):
            return base

        case (true, false):
            if let f = NSFont(name: "SFMono-Bold", size: size) { return f }
            if let f = NSFont(name: "SF Mono Bold", size: size) { return f }
            return manager.convert(base, toHaveTrait: .boldFontMask)

        case (false, true):
            if let f = NSFont(name: "SFMono-RegularItalic", size: size) { return f }
            if let f = NSFont(name: "SF Mono Italic", size: size) { return f }
            return manager.convert(base, toHaveTrait: .italicFontMask)

        case (true, true):
            if let f = NSFont(name: "SFMono-BoldItalic", size: size) { return f }
            if let f = NSFont(name: "SF Mono Bold Italic", size: size) { return f }
            // Fall back: resolve bold first (using the same explicit
            // chain), then layer italic on top via NSFontManager.
            let boldFont: NSFont = NSFont(name: "SFMono-Bold", size: size)
                ?? NSFont(name: "SF Mono Bold", size: size)
                ?? manager.convert(base, toHaveTrait: .boldFontMask)
            return manager.convert(boldFont, toHaveTrait: .italicFontMask)
        }
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

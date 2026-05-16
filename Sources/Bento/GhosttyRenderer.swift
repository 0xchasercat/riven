import AppKit
import BentoCore
import CoreText
import Foundation
import GhosttyVt

/// Stateless CoreText draw helper shared by the in-process
/// (`GhosttyTerminalView`) and broker-backed (`BrokeredTerminalView`)
/// terminal views.
///
/// The renderer doesn't own any state; callers pass in a live
/// `GhosttySessionHandle`, the cached cell metrics, the active text
/// attributes, and a `Configuration`. We snapshot the grid as plain text
/// (one row per line) via `GhosttyBridge.readGridText`, draw each row
/// with CoreText, and then paint the cursor on top.
///
/// Rendering today is intentionally minimal: monospaced font, single
/// foreground color, single background color, single cursor color. The
/// SGR / truecolor / hyperlink paths are a future upgrade.
@MainActor
enum GhosttyRenderer {

    /// All the bits of visual configuration the draw path needs.
    struct Style {
        var foreground: NSColor
        var background: NSColor
        var cursor: NSColor

        init(foreground: NSColor, background: NSColor, cursor: NSColor) {
            self.foreground = foreground
            self.background = background
            self.cursor = cursor
        }
    }

    /// Draw `bounds` of an `isFlipped` NSView using `ctx`. If `session` is
    /// nil or has been closed we still paint the background so the view
    /// reads as the configured terminal color rather than transparent.
    static func draw(
        bridge: GhosttyBridge,
        session: GhosttySessionHandle?,
        bounds: NSRect,
        ctx: CGContext,
        style: Style,
        textAttributes: [NSAttributedString.Key: Any],
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        ascent: CGFloat
    ) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        // Background.
        ctx.setFillColor(style.background.cgColor)
        ctx.fill(bounds)

        guard let session, bridge.isAlive(session) else { return }

        let lines = (try? bridge.readGridText(session)) ?? []

        // Draw each row. We assume the host view is `isFlipped == true`,
        // so y=0 is at the top. CoreText draws baselines, which means we
        // have to flip the CTM around the baseline for each row.
        ctx.textMatrix = .identity
        for (rowIdx, line) in lines.enumerated() {
            let baselineFromTop = CGFloat(rowIdx) * cellHeight + ascent
            let attr = NSAttributedString(string: line, attributes: textAttributes)
            let ctLine = CTLineCreateWithAttributedString(attr)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: baselineFromTop)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = .zero
            CTLineDraw(ctLine, ctx)
            ctx.restoreGState()
        }

        // Cursor.
        if let cursor = try? bridge.readCursor(session), cursor.visible {
            let rect = NSRect(
                x: CGFloat(cursor.x) * cellWidth,
                y: CGFloat(cursor.y) * cellHeight,
                width: cellWidth,
                height: cellHeight
            )
            ctx.setFillColor(style.cursor.withAlphaComponent(0.45).cgColor)
            ctx.fill(rect)
        }
    }
}

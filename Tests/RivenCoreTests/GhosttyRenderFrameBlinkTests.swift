import Foundation
import Testing
@testable import RivenCore

/// `GhosttyRenderFrame.hasBlinkingContent` is the gate that decides
/// whether `BrokeredTerminalView` arms its 500 ms redraw ticker for
/// SGR 5/6 blink animation. If the gate misfires, either the CPU burns
/// for nothing or animation just doesn't happen.
@Suite("Ghostty render-frame blink detection")
struct GhosttyRenderFrameBlinkTests {

    @Test("a frame with no blink cells reports hasBlinkingContent == false")
    func quietFrameReportsFalse() {
        let frame = GhosttyRenderFrame.empty(cols: 8, rows: 3)
        #expect(frame.hasBlinkingContent == false)
    }

    @Test("a frame with a single blink cell reports hasBlinkingContent == true")
    func oneBlinkCellReportsTrue() {
        let blinkCell = GhosttyResolvedCell(text: "!", blink: true)
        let frame = GhosttyRenderFrame(
            cols: 3,
            rows: 1,
            defaultForeground: GhosttyRGB(r: 220, g: 220, b: 220),
            defaultBackground: GhosttyRGB(r: 18, g: 18, b: 18),
            cursor: GhosttyCursorState(visible: false, blinking: false, style: .block, x: 0, y: 0),
            cells: [
                [
                    GhosttyResolvedCell.blank,
                    blinkCell,
                    GhosttyResolvedCell.blank,
                ]
            ]
        )
        #expect(frame.hasBlinkingContent == true)
    }

    @Test("wide-tail cells with blink set do NOT trigger the redraw timer")
    func wideTailBlinkIsIgnored() {
        // The trailing half of a wide character mirrors the leading
        // cell's style bits, including `blink`. The leading cell is the
        // one that actually paints; tagging the tail as "active blink
        // content" would arm the timer for content that doesn't render.
        let wideTail = GhosttyResolvedCell(text: " ", isWideTail: true, blink: true)
        let frame = GhosttyRenderFrame(
            cols: 2,
            rows: 1,
            defaultForeground: GhosttyRGB(r: 220, g: 220, b: 220),
            defaultBackground: GhosttyRGB(r: 18, g: 18, b: 18),
            cursor: GhosttyCursorState(visible: false, blinking: false, style: .block, x: 0, y: 0),
            cells: [
                [
                    GhosttyResolvedCell(text: "漢"),
                    wideTail,
                ]
            ]
        )
        #expect(frame.hasBlinkingContent == false)
    }
}

import AppKit
import SwiftUI

/// Parse a `#RGB` / `#RGBA` / `#RRGGBB` / `#RRGGBBAA` literal into channel
/// components in [0, 1]. The trailing alpha byte is optional — 6-digit hex
/// is treated as fully opaque (alpha = 1) for back-compat with every theme
/// value we shipped before mockup-parity tokens like `selectionBg` (rgba)
/// landed. Returns (1, 0, 1, 1) for unparseable input so a broken theme
/// shows up as garish magenta rather than crashing the renderer.
private func parseHexColor(_ hex: String) -> (r: Double, g: Double, b: Double, a: Double) {
    let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    var value: UInt64 = 0
    Scanner(string: trimmed).scanHexInt64(&value)
    switch trimmed.count {
    case 3: // RGB → expand each nibble to a byte
        let r = Double((value >> 8) & 0xf) / 15
        let g = Double((value >> 4) & 0xf) / 15
        let b = Double(value & 0xf) / 15
        return (r, g, b, 1)
    case 4: // RGBA short form
        let r = Double((value >> 12) & 0xf) / 15
        let g = Double((value >> 8) & 0xf) / 15
        let b = Double((value >> 4) & 0xf) / 15
        let a = Double(value & 0xf) / 15
        return (r, g, b, a)
    case 6: // RRGGBB
        let r = Double((value >> 16) & 0xff) / 255
        let g = Double((value >> 8) & 0xff) / 255
        let b = Double(value & 0xff) / 255
        return (r, g, b, 1)
    case 8: // RRGGBBAA
        let r = Double((value >> 24) & 0xff) / 255
        let g = Double((value >> 16) & 0xff) / 255
        let b = Double((value >> 8) & 0xff) / 255
        let a = Double(value & 0xff) / 255
        return (r, g, b, a)
    default:
        return (1, 0, 1, 1) // garish magenta = parse failure
    }
}

extension Color {
    init(hex: String) {
        let c = parseHexColor(hex)
        self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }
}

extension NSColor {
    convenience init(hex: String) {
        let c = parseHexColor(hex)
        self.init(
            calibratedRed: CGFloat(c.r),
            green: CGFloat(c.g),
            blue: CGFloat(c.b),
            alpha: CGFloat(c.a)
        )
    }
}

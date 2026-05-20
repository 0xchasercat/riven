import AppKit
import BentoCore
import SwiftUI

/// Theme-agnostic design tokens for the Bento UI.
///
/// Use these constants instead of magic numbers in any UI code. The goal
/// is that two surfaces using the same token always look related, and a
/// single change here propagates across the whole app.
///
/// Three axes:
///
///   - `Spacing` is the 4 pt grid (xxs/xs/s/m/l/xl/xxl/xxxl). Padding,
///     gaps, margins.
///   - `Radius` controls corner rounding. Small = pill / chip,
///     medium = surfaces, large = modal panels.
///   - `Type` carries font sizes, weights, and a `font(_:weight:design:)`
///     constructor that always returns the right SwiftUI `Font`.
///
/// Plus `Elevation` (shadow tokens) and `Animation` (motion tokens) for
/// consistent depth and transitions.

public enum BentoSpacing {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 20
    public static let xxl: CGFloat = 24
    public static let xxxl: CGFloat = 32
    public static let huge: CGFloat = 48
}

public enum BentoRadius {
    /// Pills, chips, small inline controls.
    public static let small: CGFloat = 3
    /// Cards, panels, buttons.
    public static let medium: CGFloat = 6
    /// Modal overlays, popovers.
    public static let large: CGFloat = 10
}

public enum BentoType {
    public static let caption: CGFloat = 10
    public static let small: CGFloat = 11
    public static let body: CGFloat = 12
    public static let mono: CGFloat = 13
    public static let subhead: CGFloat = 14
    public static let title: CGFloat = 16
    public static let display: CGFloat = 22

    /// Convenience: monospaced label at a given size.
    @MainActor
    public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Convenience: chrome (sans) label at a given size.
    @MainActor
    public static func chrome(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// Letter-spaced micro label (e.g. "PANES", "PROJECT") for section
    /// headers.
    @MainActor
    public static func micro() -> Font {
        .system(size: 10, weight: .semibold, design: .monospaced)
    }
}

public enum BentoElevation {
    /// 1-pixel inset shadow. Used by pane chrome on hover, button hover.
    public static let subtle: (color: Color, radius: CGFloat, x: CGFloat, y: CGFloat) =
        (Color.black.opacity(0.18), 2, 0, 1)
    /// Raised card (overlays' inner content).
    public static let card: (color: Color, radius: CGFloat, x: CGFloat, y: CGFloat) =
        (Color.black.opacity(0.30), 12, 0, 4)
    /// Modal-level shadow.
    public static let modal: (color: Color, radius: CGFloat, x: CGFloat, y: CGFloat) =
        (Color.black.opacity(0.42), 38, 0, 24)
}

public enum BentoMotion {
    /// Short ease for hover / press feedback.
    public static let hover = SwiftUI.Animation.easeInOut(duration: 0.10)
    /// Standard transition for overlay show/hide, layout switches.
    public static let standard = SwiftUI.Animation.easeInOut(duration: 0.18)
    /// Slower, for full-pane state changes.
    public static let pane = SwiftUI.Animation.easeInOut(duration: 0.24)
}

// MARK: - Surface helper

/// A themed surface with consistent inner padding, corner radius, and
/// optional border + elevation. Use as the base for cards, panels,
/// chips, etc.
public struct Surface<Content: View>: View {
    public enum Style {
        /// Sits on the canvas, with the panel color.
        case panel
        /// Lifted above the panel: command bars, headers.
        case elevated
        /// Modal-level: command palette, search, theme picker.
        case overlay
    }

    let theme: ThemeSpec
    let style: Style
    let padding: CGFloat
    let radius: CGFloat
    let bordered: Bool
    @ViewBuilder var content: Content

    public init(
        theme: ThemeSpec,
        style: Style = .panel,
        padding: CGFloat = BentoSpacing.l,
        radius: CGFloat = BentoRadius.medium,
        bordered: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.theme = theme
        self.style = style
        self.padding = padding
        self.radius = radius
        self.bordered = bordered
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color(hex: backgroundHex))
            )
            .overlay(
                bordered
                    ? RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color(hex: theme.chrome.border.hex), lineWidth: 0.5)
                    : nil
            )
            .shadow(
                color: shadow.color,
                radius: shadow.radius,
                x: shadow.x,
                y: shadow.y
            )
    }

    private var backgroundHex: String {
        switch style {
        case .panel: return theme.chrome.panel.hex
        case .elevated: return theme.chrome.elevated.hex
        case .overlay: return theme.chrome.elevated.hex
        }
    }

    private var shadow: (color: Color, radius: CGFloat, x: CGFloat, y: CGFloat) {
        switch style {
        case .panel: return (.clear, 0, 0, 0)
        case .elevated: return BentoElevation.subtle
        case .overlay: return BentoElevation.modal
        }
    }
}

// MARK: - Vibrancy background

/// SwiftUI wrapper around `NSVisualEffectView` so we can paint translucent
/// macOS "vibrancy" behind any view tree. We use this to bleed the
/// window's transparent title bar through the tab strip + toolbar so the
/// top of the window reads as a single continuous panel rather than a
/// stack of disconnected horizontal strips (see H8 in
/// `scripts/notes/warp-vs-bento-polish.md`).
///
/// `state = .followsWindowActiveState` automatically dims the vibrancy
/// when the window loses key focus — matches what every native macOS app
/// does and avoids manual active/inactive plumbing on our side.
public struct VibrancyBackground: NSViewRepresentable {
    public let material: NSVisualEffectView.Material
    public let blendingMode: NSVisualEffectView.BlendingMode

    public init(
        material: NSVisualEffectView.Material = .windowBackground,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) {
        self.material = material
        self.blendingMode = blendingMode
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        view.isEmphasized = false
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Hairline divider

/// A 1-px (looks 0.5-pt on Retina) divider in the theme's hairline color.
/// Use to separate sibling surfaces.
public struct Hairline: View {
    let theme: ThemeSpec
    let axis: Axis

    public init(theme: ThemeSpec, axis: Axis = .horizontal) {
        self.theme = theme
        self.axis = axis
    }

    public var body: some View {
        Color(hex: theme.chrome.hairline.hex)
            .frame(
                width: axis == .vertical ? 1 : nil,
                height: axis == .horizontal ? 1 : nil
            )
    }
}

// MARK: - Section label

/// Letter-spaced uppercase micro label for section headers (sidebar
/// section titles, palette group titles, etc.).
public struct SectionLabel: View {
    let theme: ThemeSpec
    let text: String

    public init(theme: ThemeSpec, _ text: String) {
        self.theme = theme
        self.text = text
    }

    public var body: some View {
        Text(text.uppercased())
            .font(BentoType.micro())
            .tracking(0.6)
            .foregroundStyle(Color(hex: theme.chrome.tertiaryText.hex))
    }
}

import AppKit
import RivenCore
import SwiftUI

/// Theme-agnostic design tokens for the Riven UI.
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

public enum RivenSpacing {
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

public enum RivenRadius {
    /// Pills, chips, small inline controls.
    public static let small: CGFloat = 3
    /// Cards, panels, buttons.
    public static let medium: CGFloat = 6
    /// Modal overlays, popovers.
    public static let large: CGFloat = 10
}

public enum RivenType {
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

public enum RivenElevation {
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

public enum RivenMotion {
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
        padding: CGFloat = RivenSpacing.l,
        radius: CGFloat = RivenRadius.medium,
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
        case .elevated: return RivenElevation.subtle
        case .overlay: return RivenElevation.modal
        }
    }
}

// MARK: - Vibrancy background

/// SwiftUI wrapper around `NSVisualEffectView` so we can paint translucent
/// macOS "vibrancy" behind any view tree. We use this to bleed the
/// window's transparent title bar through the tab strip + toolbar so the
/// top of the window reads as a single continuous panel rather than a
/// stack of disconnected horizontal strips (see H8 in
/// `scripts/notes/warp-vs-riven-polish.md`).
///
/// `state = .followsWindowActiveState` automatically dims the vibrancy
/// when the window loses key focus — matches what every native macOS app
/// does and avoids manual active/inactive plumbing on our side.
///
/// The theme-aware initializer (`init(theme:blendingMode:)`) resolves
/// `theme.material.vibrancyMaterial` (a string token kept in RivenCore so
/// the model layer stays AppKit-free) into the corresponding
/// `NSVisualEffectView.Material`. This is how Paper (`titlebar`) and the
/// dark themes (`headerView`) get different chrome translucency from a
/// single declaration in `ThemeSpec.builtIns`. The appearance is also
/// pinned to the theme's `mode`, so Paper renders with the macOS light
/// appearance even when the system is in dark mode (otherwise vibrancy
/// would pick the wrong tint and the chrome would read as muddy gray).
public struct VibrancyBackground: NSViewRepresentable {
    public let material: NSVisualEffectView.Material
    public let blendingMode: NSVisualEffectView.BlendingMode
    /// Forced appearance for the vibrancy surface. `nil` means "inherit
    /// from the window/system" (legacy behavior). When the theme-aware
    /// initializer is used we pin this to match the theme's `mode` so
    /// switching to Paper while the system is dark doesn't leak the
    /// system-dark `titlebar` material under the cream chrome.
    public let appearance: NSAppearance.Name?

    public init(
        material: NSVisualEffectView.Material = .windowBackground,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        appearance: NSAppearance.Name? = nil
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.appearance = appearance
    }

    /// Theme-aware convenience initializer. Maps the theme's
    /// `vibrancyMaterial` string into the matching AppKit case and pins
    /// the visual-effect view's appearance to the theme's light/dark
    /// mode so the chrome doesn't take on the wrong system tint mid-
    /// theme-switch.
    ///
    /// Supported string values: `windowBackground`, `headerView`,
    /// `titlebar`, `underWindowBackground`, `underPageBackground`.
    /// Anything else falls through to `.windowBackground` — the same
    /// fallback documented on `ThemeMaterial.vibrancyMaterial`.
    public init(
        theme: ThemeSpec,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) {
        self.material = Self.material(for: theme.material.vibrancyMaterial)
        self.blendingMode = blendingMode
        self.appearance = theme.material.mode == .light ? .aqua : .darkAqua
    }

    /// Map the theme's string token to the AppKit material. Kept private
    /// + static so the lookup table lives next to the SwiftUI call sites
    /// rather than inside RivenCore (which has to stay AppKit-free).
    private static func material(for token: String) -> NSVisualEffectView.Material {
        switch token {
        case "windowBackground": return .windowBackground
        case "headerView": return .headerView
        case "titlebar": return .titlebar
        case "underWindowBackground": return .underWindowBackground
        case "underPageBackground": return .underPageBackground
        default: return .windowBackground
        }
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        view.isEmphasized = false
        if let appearance {
            view.appearance = NSAppearance(named: appearance)
        }
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        if let appearance {
            nsView.appearance = NSAppearance(named: appearance)
        } else {
            nsView.appearance = nil
        }
    }
}

// MARK: - Hairline divider

/// A 1-px (looks 0.5-pt on Retina) divider in the theme's hairline color.
/// Use to separate sibling surfaces.
///
/// Pass `weight: nil` to inherit the theme's `geometry.dividerWeight`
/// (used by inter-pane / split-strip dividers — the marquee Riven
/// "compartment wall" look at 6 pt). Override with an explicit weight
/// for ordinary chrome separators (header underline, tab strip seam,
/// status-bar topline) that should stay at a true hairline regardless
/// of theme.
public struct Hairline: View {
    let theme: ThemeSpec
    let axis: Axis
    let weight: CGFloat?

    public init(theme: ThemeSpec, axis: Axis = .horizontal, weight: CGFloat? = 1) {
        self.theme = theme
        self.axis = axis
        self.weight = weight
    }

    public var body: some View {
        let w = weight ?? theme.geometry.dividerWeight
        // Sibling split strips use `border` (deeper, reads as a
        // compartment wall at 6 pt on Riven); pure hairlines fall back
        // to the lighter `hairline` token. We pick by weight rather
        // than by a separate parameter so call sites stay terse.
        let colorHex = w >= 2 ? theme.chrome.border.hex : theme.chrome.hairline.hex
        return Color(hex: colorHex)
            .frame(
                width: axis == .vertical ? w : nil,
                height: axis == .horizontal ? w : nil
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
            .font(RivenType.micro())
            .tracking(0.6)
            .foregroundStyle(Color(hex: theme.chrome.tertiaryText.hex))
    }
}

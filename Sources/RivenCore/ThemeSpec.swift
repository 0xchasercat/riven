import Foundation

// MARK: - palette tuning notes
//
// The 12 chromatic ANSI slots below (`red/green/blue/cyan/magenta/yellow`
// + their `bright*` siblings) are derived from the pure SGR-spec defaults
// (#FF0000, #00FF00, … #FFFF55) with their saturation knocked down 20%
// to keep `ls --color` and vim syntax highlighting from reading as a
// fruit-salad on Riven's surfaces. The 8 achromatic slots (black, white,
// dim foreground/background/cursor) plus `foreground`/`background`/
// `prompt`/`cursor` are *not* touched by this tune — they're picked per
// theme for contrast and identity, not for chroma.
//
// Conversion math (RGB ↔ HSL, all channels normalized to [0,1]):
//
//   rgb -> hsl:
//     mx = max(r,g,b), mn = min(r,g,b)
//     L  = (mx + mn) / 2
//     if mx == mn: H = S = 0                 // achromatic
//     else:
//       d = mx - mn
//       S = d / (mx + mn)        if L < 0.5
//           d / (2 - mx - mn)    otherwise
//       H = 60 * ((g-b)/d mod 6) if mx == r
//           60 * ((b-r)/d + 2)   if mx == g
//           60 * ((r-g)/d + 4)   if mx == b
//
//   hsl -> rgb (via chroma decomposition):
//     C  = (1 - |2L - 1|) * S
//     H' = H / 60
//     X  = C * (1 - |H' mod 2 - 1|)
//     m  = L - C/2
//     (r,g,b) = (C+m, X+m, 0+m) for H' in [0,1) and cycles through the
//               six sectors as H' increases.
//
// Tuning recipe per slot, applied mechanically:
//   1. hex -> (H, S, L)
//   2. S' = S * 0.80              // saturation knock-down
//   3. (bright variants only) if |L_bright - L_regular| < 0.10:
//          L_bright' = min(1, L_bright + 0.05)
//   4. (H, S', L') -> hex          (uppercase, 6 hex digits)
//
// Worked example for the regular `red` slot:
//   #FF0000 -> H=0,   S=1.000, L=0.500
//   S' = 0.800
//   no bright clamp (this is the regular slot)
//   (0, 0.800, 0.500) -> #E61919
//
// Worked example for the `brightRed` slot:
//   #FF5555 -> H=0,   S=1.000, L=0.667
//   S' = 0.800
//   L_red=0.500, L_brightRed=0.667 -> |Δ| = 0.167 >= 0.10, no clamp
//   (0, 0.800, 0.667) -> #EE6666
//
// To re-tune from a *different* baseline (e.g. switch from pure SGR to a
// Warp-style starting palette, or change the 0.80 factor): plug those
// hex values + the new factor into the recipe above. The macOS Color
// Picker round-trips HSL for live previewing if you want to eyeball
// without writing code. Keep this comment in sync with the literals.

public struct ThemeSpec: Equatable, Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var chrome: ThemeChrome
    public var terminal: TerminalColors
    public var syntax: SyntaxColors
    /// Layout knobs: how thick the divider between panes is, how round the
    /// corners are, how prominent the active-pane outline reads. These are
    /// what give Riven its signature "compartment wall" look (6 pt
    /// dividers, 4 pt pane radius) vs. Carbon's flat hairline (1 pt, 0 pt
    /// radius). Optional in the schema so legacy snapshots without a
    /// `geometry` field still decode — falls back to `.default`.
    public var geometry: ThemeGeometry
    /// Materials + light/dark hint. Drives which `NSVisualEffectView`
    /// material the chrome layer uses (dark themes want `.headerView`,
    /// Paper wants `.titlebar`) and tells the chrome layer whether to
    /// reach for light or dark accent fallbacks.
    public var material: ThemeMaterial

    public init(
        id: String,
        name: String,
        chrome: ThemeChrome,
        terminal: TerminalColors,
        syntax: SyntaxColors,
        geometry: ThemeGeometry = .default,
        material: ThemeMaterial = .dark
    ) {
        self.id = id
        self.name = name
        self.chrome = chrome
        self.terminal = terminal
        self.syntax = syntax
        self.geometry = geometry
        self.material = material
    }

    // Custom decoder so adding new fields (geometry, material) doesn't
    // break decoding of any ThemeSpec persisted before this commit —
    // the snapshot store roundtrips themes by id, so an older snapshot
    // would error otherwise.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.chrome = try c.decode(ThemeChrome.self, forKey: .chrome)
        self.terminal = try c.decode(TerminalColors.self, forKey: .terminal)
        self.syntax = try c.decode(SyntaxColors.self, forKey: .syntax)
        self.geometry = try c.decodeIfPresent(ThemeGeometry.self, forKey: .geometry) ?? .default
        self.material = try c.decodeIfPresent(ThemeMaterial.self, forKey: .material) ?? .dark
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, chrome, terminal, syntax, geometry, material
    }

    public static let builtIns: [ThemeSpec] = [
        ThemeSpec(
            id: "amber",
            name: "Amber",
            chrome: ThemeChrome(
                background: "#0e0a07",
                panel: "#1a130d",
                panelInactive: "#15100b",
                border: "#2a1f15",
                activeBorder: "#d9a663",
                text: "#ece1cb",
                dimText: "#8a7a62",
                elevated: "#221b13",
                overlay: "#050302",
                tertiaryText: "#5a4a30",
                invertedText: "#0e0a07",
                hairline: "#15100b",
                accent: "#d9a663",
                accentSoft: "#d9a66322",
                success: "#7a9658",
                warning: "#d9a663",
                danger: "#bf6e54",
                paneHeaderBg: "#150f0a",
                statusBg: "#0a0604",
                statusText: "#8a7a62",
                selectionBg: "#d9a6631F"
            ),
            terminal: TerminalColors(
                foreground: "#ece1cb",
                background: "#1a130d",
                prompt: "#d9a663",
                cursor: "#d9a663",
                ansi: ANSIPalette(
                    red:           "#E61919",
                    green:         "#19E619",
                    blue:          "#1919E6",
                    cyan:          "#19E6E6",
                    magenta:       "#E619E6",
                    yellow:        "#E6E619",
                    brightRed:     "#EE6666",
                    brightGreen:   "#66EE66",
                    brightBlue:    "#6666EE",
                    brightCyan:    "#66EEEE",
                    brightMagenta: "#EE66EE",
                    brightYellow:  "#EEEE66"
                )
            ),
            syntax: SyntaxColors(keyword: "#d9a663", function: "#ece1cb", string: "#a8945c", comment: "#5a4a30"),
            // Riven's signature compartment-wall look: thick dividers, mild
            // corner rounding, glowing amber active border at low alpha.
            geometry: ThemeGeometry(
                dividerWeight: 6,
                paneRadius: 4,
                windowRadius: 12,
                activeHighlightWidth: 1,
                activeHighlightAlpha: 0.55
            ),
            material: .dark
        ),
        ThemeSpec(
            id: "carbon",
            name: "Carbon",
            chrome: ThemeChrome(
                background: "#0c0c0c",
                panel: "#141414",
                panelInactive: "#0f0f0f",
                border: "#262626",
                activeBorder: "#4a4a4a",
                text: "#d4d4d4",
                dimText: "#888888",
                elevated: "#1c1c1c",
                overlay: "#060606",
                tertiaryText: "#555555",
                invertedText: "#0c0c0c",
                hairline: "#1a1a1a",
                accent: "#8a8a8a",
                accentSoft: "#8a8a8a22",
                success: "#6e8a6e",
                warning: "#b0a060",
                danger: "#b06866",
                paneHeaderBg: "#0e0e0e",
                statusBg: "#0a0a0a",
                statusText: "#7a7a7a",
                selectionBg: "#FFFFFF0F"
            ),
            terminal: TerminalColors(
                foreground: "#d4d4d4",
                background: "#141414",
                prompt: "#9a9a9a",
                cursor: "#e8e8e8",
                ansi: ANSIPalette(
                    red:           "#E61919",
                    green:         "#19E619",
                    blue:          "#1919E6",
                    cyan:          "#19E6E6",
                    magenta:       "#E619E6",
                    yellow:        "#E6E619",
                    brightRed:     "#EE6666",
                    brightGreen:   "#66EE66",
                    brightBlue:    "#6666EE",
                    brightCyan:    "#66EEEE",
                    brightMagenta: "#EE66EE",
                    brightYellow:  "#EEEE66"
                )
            ),
            syntax: SyntaxColors(keyword: "#c8c8c8", function: "#e8e8e8", string: "#9a9a9a", comment: "#4a4a4a"),
            // Flat reference grid: hairline divider, no corner rounding,
            // muted gray accent border.
            geometry: ThemeGeometry(
                dividerWeight: 1,
                paneRadius: 0,
                windowRadius: 10,
                activeHighlightWidth: 1,
                activeHighlightAlpha: 1.0
            ),
            material: .dark
        ),
        ThemeSpec(
            id: "tokyo",
            name: "Tokyo",
            chrome: ThemeChrome(
                background: "#13131c",
                panel: "#1a1b26",
                panelInactive: "#16171f",
                border: "#3a3d56",
                activeBorder: "#bb9af7",
                text: "#c0caf5",
                dimText: "#7986b8",
                elevated: "#232434",
                overlay: "#08080c",
                tertiaryText: "#4a5378",
                invertedText: "#1a1b26",
                hairline: "#2a2c40",
                accent: "#bb9af7",
                accentSoft: "#bb9af722",
                success: "#9ece6a",
                warning: "#e0af68",
                danger: "#f7768e",
                paneHeaderBg: "#16171f",
                statusBg: "#0f0f17",
                statusText: "#7a83a8",
                selectionBg: "#bb9af726"
            ),
            terminal: TerminalColors(
                foreground: "#c0caf5",
                background: "#1a1b26",
                prompt: "#bb9af7",
                cursor: "#bb9af7",
                ansi: ANSIPalette(
                    red:           "#E61919",
                    green:         "#19E619",
                    blue:          "#1919E6",
                    cyan:          "#19E6E6",
                    magenta:       "#E619E6",
                    yellow:        "#E6E619",
                    brightRed:     "#EE6666",
                    brightGreen:   "#66EE66",
                    brightBlue:    "#6666EE",
                    brightCyan:    "#66EEEE",
                    brightMagenta: "#EE66EE",
                    brightYellow:  "#EEEE66"
                )
            ),
            syntax: SyntaxColors(keyword: "#bb9af7", function: "#7aa2f7", string: "#9ece6a", comment: "#565f89"),
            geometry: ThemeGeometry(
                dividerWeight: 1,
                paneRadius: 6,
                windowRadius: 12,
                activeHighlightWidth: 1,
                activeHighlightAlpha: 1.0
            ),
            material: .dark
        ),
        ThemeSpec(
            id: "paper",
            name: "Paper",
            chrome: ThemeChrome(
                background: "#ece7da",
                panel: "#f6f2e7",
                panelInactive: "#efeadd",
                border: "#d4cdb8",
                activeBorder: "#2a2620",
                text: "#2a2620",
                dimText: "#8a8268",
                elevated: "#fbf8f0",
                overlay: "#1f1c18cc",
                tertiaryText: "#aaa28a",
                invertedText: "#f6f2e7",
                hairline: "#e2dccd",
                accent: "#6a5a30",
                accentSoft: "#6a5a3022",
                success: "#4a7a3a",
                warning: "#a07a30",
                danger: "#a04640",
                paneHeaderBg: "#efeadd",
                statusBg: "#e4dfd1",
                statusText: "#6f6650",
                selectionBg: "#2a26201A"
            ),
            terminal: TerminalColors(
                foreground: "#2a2620",
                background: "#f6f2e7",
                prompt: "#6a5a30",
                cursor: "#2a2620",
                ansi: ANSIPalette(
                    red:           "#E61919",
                    green:         "#19E619",
                    blue:          "#1919E6",
                    cyan:          "#19E6E6",
                    magenta:       "#E619E6",
                    yellow:        "#E6E619",
                    brightRed:     "#EE6666",
                    brightGreen:   "#66EE66",
                    brightBlue:    "#6666EE",
                    brightCyan:    "#66EEEE",
                    brightMagenta: "#EE66EE",
                    brightYellow:  "#EEEE66"
                )
            ),
            syntax: SyntaxColors(keyword: "#6a3a8a", function: "#2a4a8a", string: "#5a6a32", comment: "#9a907a"),
            geometry: ThemeGeometry(
                dividerWeight: 1,
                paneRadius: 3,
                windowRadius: 12,
                activeHighlightWidth: 1,
                activeHighlightAlpha: 1.0
            ),
            material: .light
        )
    ]

    public static func theme(id: String) -> ThemeSpec? {
        // Custom themes win over builtins so a user can shadow a
        // shipped palette by dropping the same `id` into their JSON
        // file. The loader caches per launch; cost is a small array
        // scan once per theme lookup.
        if let custom = CustomThemeLoader.shared.themes.first(where: { $0.id == id }) {
            return custom
        }
        return builtIns.first { $0.id == id }
    }

    /// Builtins plus user-authored custom themes. Custom themes that
    /// shadow a builtin replace it; otherwise they're appended in the
    /// order the loader returned. Use this everywhere a "pick a theme"
    /// UI needs the full visible list.
    public static func all() -> [ThemeSpec] {
        let customs = CustomThemeLoader.shared.themes
        let customIDs = Set(customs.map(\.id))
        var merged: [ThemeSpec] = []
        for theme in builtIns {
            if let override = customs.first(where: { $0.id == theme.id }) {
                merged.append(override)
            } else {
                merged.append(theme)
            }
        }
        for theme in customs where !ThemeSpec.builtIns.contains(where: { $0.id == theme.id }) {
            // Pure custom (no shadowing) — append at the end so the
            // builtins stay in their curated order.
            merged.append(theme)
        }
        // Suppress the unused warning when there are zero customs.
        _ = customIDs
        return merged
    }

    /// `true` when `id` belongs to a user-authored theme JSON rather
    /// than one of the shipped `builtIns`. Used by the picker to render
    /// the "(custom)" badge.
    public static func isCustom(id: String) -> Bool {
        CustomThemeLoader.shared.themes.contains(where: { $0.id == id })
    }
}

/// Color tokens for the app chrome (everything that isn't the terminal
/// grid or syntax-highlighted code). Organized around three concepts:
///
/// - **Surfaces** form a depth hierarchy:
///     `overlay` (modal backdrop, deepest)
///     `background` (the canvas the window sits on)
///     `panel` (workspace panels, sidebars)
///     `elevated` (raised surfaces — popovers, headers, command bar)
///
/// - **Content** colors carry meaning:
///     `text` is the primary reading color
///     `dimText` is for labels, helper text
///     `tertiaryText` is for icons, secondary marks
///     `invertedText` is for text on filled accents (buttons, badges)
///
/// - **Lines** are how surfaces edge into each other:
///     `hairline` is the lightest separator (0.5–1 px on inactive panes)
///     `border` is the default pane edge
///     `activeBorder` highlights the focused pane
///
/// - **Accents** + **status** are intent colors. `accent` is the brand
///   highlight; `accentSoft` is the same with a low alpha baked in for
///   subtle backgrounds. `success/warning/danger` are semantic — used by
///   banners, badges, trust prompts.
public struct ThemeChrome: Equatable, Codable, Sendable {
    public var background: HexColor
    public var panel: HexColor
    /// Background of a *non-focused* pane. Sits one notch dimmer than
    /// `panel`. Riven uses a deeper sumi-tone; Carbon's barely changes.
    public var panelInactive: HexColor
    public var border: HexColor
    public var activeBorder: HexColor
    public var text: HexColor
    public var dimText: HexColor
    public var elevated: HexColor
    public var overlay: HexColor
    public var tertiaryText: HexColor
    public var invertedText: HexColor
    public var hairline: HexColor
    public var accent: HexColor
    public var accentSoft: HexColor
    public var success: HexColor
    public var warning: HexColor
    public var danger: HexColor
    /// Background of the per-pane header strip (the row that holds the
    /// tab label / `[][]` / `+`). Subtle elevation above `panel`.
    public var paneHeaderBg: HexColor
    /// Background + text of the bottom status bar.
    public var statusBg: HexColor
    public var statusText: HexColor
    /// Background fill for selected text in editors and code surfaces.
    /// Usually a translucent accent — uses 8-digit hex `#RRGGBBAA`.
    public var selectionBg: HexColor

    public init(
        background: HexColor,
        panel: HexColor,
        panelInactive: HexColor? = nil,
        border: HexColor,
        activeBorder: HexColor,
        text: HexColor,
        dimText: HexColor,
        elevated: HexColor,
        overlay: HexColor,
        tertiaryText: HexColor,
        invertedText: HexColor,
        hairline: HexColor,
        accent: HexColor,
        accentSoft: HexColor,
        success: HexColor,
        warning: HexColor,
        danger: HexColor,
        paneHeaderBg: HexColor? = nil,
        statusBg: HexColor? = nil,
        statusText: HexColor? = nil,
        selectionBg: HexColor? = nil
    ) {
        self.background = background
        self.panel = panel
        // Fall back to `panel` when `panelInactive` isn't supplied (legacy
        // call sites and older snapshots) so inactive panes still get a
        // valid color rather than crashing on the swatch.
        self.panelInactive = panelInactive ?? panel
        self.border = border
        self.activeBorder = activeBorder
        self.text = text
        self.dimText = dimText
        self.elevated = elevated
        self.overlay = overlay
        self.tertiaryText = tertiaryText
        self.invertedText = invertedText
        self.hairline = hairline
        self.accent = accent
        self.accentSoft = accentSoft
        self.success = success
        self.warning = warning
        self.danger = danger
        self.paneHeaderBg = paneHeaderBg ?? elevated
        self.statusBg = statusBg ?? background
        self.statusText = statusText ?? dimText
        self.selectionBg = selectionBg ?? accentSoft
    }

    // Custom decoder for back-compat with snapshots persisted before the
    // mockup-parity tokens (panelInactive / paneHeaderBg / statusBg /
    // statusText / selectionBg) were added. Missing keys fall back to a
    // sensible neighbor (panel for panel*, elevated for paneHeaderBg,
    // accentSoft for selectionBg, etc.) so an older theme JSON still
    // round-trips without becoming garish-magenta.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let panel = try c.decode(HexColor.self, forKey: .panel)
        let elevated = try c.decode(HexColor.self, forKey: .elevated)
        let background = try c.decode(HexColor.self, forKey: .background)
        let dimText = try c.decode(HexColor.self, forKey: .dimText)
        let accentSoft = try c.decode(HexColor.self, forKey: .accentSoft)

        self.background = background
        self.panel = panel
        self.panelInactive = try c.decodeIfPresent(HexColor.self, forKey: .panelInactive) ?? panel
        self.border = try c.decode(HexColor.self, forKey: .border)
        self.activeBorder = try c.decode(HexColor.self, forKey: .activeBorder)
        self.text = try c.decode(HexColor.self, forKey: .text)
        self.dimText = dimText
        self.elevated = elevated
        self.overlay = try c.decode(HexColor.self, forKey: .overlay)
        self.tertiaryText = try c.decode(HexColor.self, forKey: .tertiaryText)
        self.invertedText = try c.decode(HexColor.self, forKey: .invertedText)
        self.hairline = try c.decode(HexColor.self, forKey: .hairline)
        self.accent = try c.decode(HexColor.self, forKey: .accent)
        self.accentSoft = accentSoft
        self.success = try c.decode(HexColor.self, forKey: .success)
        self.warning = try c.decode(HexColor.self, forKey: .warning)
        self.danger = try c.decode(HexColor.self, forKey: .danger)
        self.paneHeaderBg = try c.decodeIfPresent(HexColor.self, forKey: .paneHeaderBg) ?? elevated
        self.statusBg = try c.decodeIfPresent(HexColor.self, forKey: .statusBg) ?? background
        self.statusText = try c.decodeIfPresent(HexColor.self, forKey: .statusText) ?? dimText
        self.selectionBg = try c.decodeIfPresent(HexColor.self, forKey: .selectionBg) ?? accentSoft
    }

    private enum CodingKeys: String, CodingKey {
        case background, panel, panelInactive, border, activeBorder, text, dimText
        case elevated, overlay, tertiaryText, invertedText, hairline
        case accent, accentSoft, success, warning, danger
        case paneHeaderBg, statusBg, statusText, selectionBg
    }
}

// MARK: - Geometry

/// Layout-dimensional theme knobs. These don't carry color; they control
/// how the chrome *reads* spatially. Riven's signature compartment look
/// comes from `dividerWeight: 6` + a small `paneRadius`, while Carbon
/// ships `dividerWeight: 1` to feel like a flat reference grid.
public struct ThemeGeometry: Equatable, Codable, Sendable {
    /// Thickness (pt) of the divider line drawn between sibling panes
    /// inside the same tab.
    public var dividerWeight: CGFloat
    /// Corner radius (pt) applied to each pane's body.
    public var paneRadius: CGFloat
    /// Corner radius (pt) for the outermost window background. Currently
    /// passed through to the mockup-aware surface chrome; the OS still
    /// owns the actual NSWindow corners.
    public var windowRadius: CGFloat
    /// Stroke width (pt) of the active-pane outline.
    public var activeHighlightWidth: CGFloat
    /// Multiplier on the active border's color alpha when drawn (1.0 =
    /// fully opaque; riven uses ~0.55 so the amber reads as a glow
    /// rather than a hard line).
    public var activeHighlightAlpha: Double

    public init(
        dividerWeight: CGFloat = 1,
        paneRadius: CGFloat = 4,
        windowRadius: CGFloat = 12,
        activeHighlightWidth: CGFloat = 1,
        activeHighlightAlpha: Double = 1.0
    ) {
        self.dividerWeight = dividerWeight
        self.paneRadius = paneRadius
        self.windowRadius = windowRadius
        self.activeHighlightWidth = activeHighlightWidth
        self.activeHighlightAlpha = activeHighlightAlpha
    }

    public static let `default` = ThemeGeometry()

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.dividerWeight = try c.decodeIfPresent(CGFloat.self, forKey: .dividerWeight) ?? 1
        self.paneRadius = try c.decodeIfPresent(CGFloat.self, forKey: .paneRadius) ?? 4
        self.windowRadius = try c.decodeIfPresent(CGFloat.self, forKey: .windowRadius) ?? 12
        self.activeHighlightWidth = try c.decodeIfPresent(CGFloat.self, forKey: .activeHighlightWidth) ?? 1
        self.activeHighlightAlpha = try c.decodeIfPresent(Double.self, forKey: .activeHighlightAlpha) ?? 1.0
    }

    private enum CodingKeys: String, CodingKey {
        case dividerWeight, paneRadius, windowRadius, activeHighlightWidth, activeHighlightAlpha
    }
}

// MARK: - Material

/// Light/dark hint + a string-named vibrancy material. The string maps in
/// the app layer to an `NSVisualEffectView.Material`; we keep the raw
/// `String` here so RivenCore stays AppKit-free.
///
/// Supported `vibrancyMaterial` values (these mirror the AppKit cases of
/// the same name): `windowBackground`, `headerView`, `titlebar`,
/// `underWindowBackground`, `underPageBackground`. Unknown values fall
/// back to `windowBackground` in the renderer.
public struct ThemeMaterial: Equatable, Codable, Sendable {
    public enum Mode: String, Codable, Sendable {
        case light
        case dark
    }

    public var mode: Mode
    public var vibrancyMaterial: String

    public init(mode: Mode = .dark, vibrancyMaterial: String = "headerView") {
        self.mode = mode
        self.vibrancyMaterial = vibrancyMaterial
    }

    public static let dark = ThemeMaterial(mode: .dark, vibrancyMaterial: "headerView")
    public static let light = ThemeMaterial(mode: .light, vibrancyMaterial: "titlebar")

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .dark
        self.vibrancyMaterial = try c.decodeIfPresent(String.self, forKey: .vibrancyMaterial) ?? "headerView"
    }

    private enum CodingKeys: String, CodingKey {
        case mode, vibrancyMaterial
    }
}

public struct TerminalColors: Equatable, Codable, Sendable {
    public var foreground: HexColor
    public var background: HexColor
    public var prompt: HexColor
    public var cursor: HexColor
    /// The 12 chromatic ANSI slots (regular + bright pairs for the six
    /// non-achromatic colors). Achromatic slots (black/white/dim) are
    /// derived from `foreground`/`background` at draw time rather than
    /// stored here — only the chromatic slots need theme curation, which
    /// is where the "fruit salad" problem actually lives.
    ///
    /// See the `palette tuning notes` MARK at the top of this file for
    /// the conversion math used to derive these values from the SGR-
    /// spec defaults (#FF0000, #00FF00, …).
    public var ansi: ANSIPalette

    public init(
        foreground: HexColor,
        background: HexColor,
        prompt: HexColor,
        cursor: HexColor,
        ansi: ANSIPalette = .tuned
    ) {
        self.foreground = foreground
        self.background = background
        self.prompt = prompt
        self.cursor = cursor
        self.ansi = ansi
    }
}

/// The 12 chromatic ANSI palette slots used by `ls --color`, vim syntax
/// highlighting, and any program that emits SGR 30–37 / 90–97 with a
/// non-achromatic index. Values shipped here are the SGR-spec defaults
/// retuned to 80% saturation (see `palette tuning notes` at the top of
/// this file).
public struct ANSIPalette: Equatable, Codable, Sendable {
    public var red: HexColor
    public var green: HexColor
    public var blue: HexColor
    public var cyan: HexColor
    public var magenta: HexColor
    public var yellow: HexColor
    public var brightRed: HexColor
    public var brightGreen: HexColor
    public var brightBlue: HexColor
    public var brightCyan: HexColor
    public var brightMagenta: HexColor
    public var brightYellow: HexColor

    public init(
        red: HexColor,
        green: HexColor,
        blue: HexColor,
        cyan: HexColor,
        magenta: HexColor,
        yellow: HexColor,
        brightRed: HexColor,
        brightGreen: HexColor,
        brightBlue: HexColor,
        brightCyan: HexColor,
        brightMagenta: HexColor,
        brightYellow: HexColor
    ) {
        self.red = red
        self.green = green
        self.blue = blue
        self.cyan = cyan
        self.magenta = magenta
        self.yellow = yellow
        self.brightRed = brightRed
        self.brightGreen = brightGreen
        self.brightBlue = brightBlue
        self.brightCyan = brightCyan
        self.brightMagenta = brightMagenta
        self.brightYellow = brightYellow
    }

    /// SGR-spec defaults knocked down to 80% saturation — the baseline
    /// palette used by all four bundled themes. See the `palette tuning
    /// notes` MARK at the top of this file for the derivation.
    public static let tuned = ANSIPalette(
        red:            "#E61919",
        green:          "#19E619",
        blue:           "#1919E6",
        cyan:           "#19E6E6",
        magenta:        "#E619E6",
        yellow:         "#E6E619",
        brightRed:      "#EE6666",
        brightGreen:    "#66EE66",
        brightBlue:     "#6666EE",
        brightCyan:     "#66EEEE",
        brightMagenta:  "#EE66EE",
        brightYellow:   "#EEEE66"
    )
}

public struct SyntaxColors: Equatable, Codable, Sendable {
    public var keyword: HexColor
    public var function: HexColor
    public var string: HexColor
    public var comment: HexColor
}

public struct HexColor: Equatable, Codable, Sendable, ExpressibleByStringLiteral {
    public var hex: String

    public init(stringLiteral value: String) {
        self.hex = value
    }

    public init(_ hex: String) {
        self.hex = hex
    }

    // Encode as a bare JSON string rather than `{"hex": "..."}`. Two
    // reasons: (a) the literal already round-trips through
    // `ExpressibleByStringLiteral`, so the object wrapper was pure
    // accidental complexity; (b) custom-theme files (T-6) will be
    // hand-authored, and `"#1a130d"` reads better than
    // `{"hex": "#1a130d"}`. Safe to change today: ThemeSpec is never
    // persisted to disk — WorkspaceSnapshot keeps `selectedThemeID`
    // only, and themes are looked up by id at decode time.
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self.hex = try c.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }
}

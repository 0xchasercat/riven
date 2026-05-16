import Foundation

public struct ThemeSpec: Equatable, Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var chrome: ThemeChrome
    public var terminal: TerminalColors
    public var syntax: SyntaxColors

    public init(id: String, name: String, chrome: ThemeChrome, terminal: TerminalColors, syntax: SyntaxColors) {
        self.id = id
        self.name = name
        self.chrome = chrome
        self.terminal = terminal
        self.syntax = syntax
    }

    public static let builtIns: [ThemeSpec] = [
        ThemeSpec(
            id: "bento",
            name: "Bento",
            chrome: ThemeChrome(
                background: "#0e0a07",
                panel: "#1a130d",
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
                danger: "#bf6e54"
            ),
            terminal: TerminalColors(foreground: "#ece1cb", background: "#1a130d", prompt: "#d9a663", cursor: "#d9a663"),
            syntax: SyntaxColors(keyword: "#d9a663", function: "#ece1cb", string: "#a8945c", comment: "#5a4a30")
        ),
        ThemeSpec(
            id: "carbon",
            name: "Carbon",
            chrome: ThemeChrome(
                background: "#0c0c0c",
                panel: "#141414",
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
                danger: "#b06866"
            ),
            terminal: TerminalColors(foreground: "#d4d4d4", background: "#141414", prompt: "#9a9a9a", cursor: "#e8e8e8"),
            syntax: SyntaxColors(keyword: "#c8c8c8", function: "#e8e8e8", string: "#9a9a9a", comment: "#4a4a4a")
        ),
        ThemeSpec(
            id: "tokyo",
            name: "Tokyo",
            chrome: ThemeChrome(
                background: "#13131c",
                panel: "#1a1b26",
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
                danger: "#f7768e"
            ),
            terminal: TerminalColors(foreground: "#c0caf5", background: "#1a1b26", prompt: "#bb9af7", cursor: "#bb9af7"),
            syntax: SyntaxColors(keyword: "#bb9af7", function: "#7aa2f7", string: "#9ece6a", comment: "#565f89")
        ),
        ThemeSpec(
            id: "paper",
            name: "Paper",
            chrome: ThemeChrome(
                background: "#ece7da",
                panel: "#f6f2e7",
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
                danger: "#a04640"
            ),
            terminal: TerminalColors(foreground: "#2a2620", background: "#f6f2e7", prompt: "#6a5a30", cursor: "#2a2620"),
            syntax: SyntaxColors(keyword: "#6a3a8a", function: "#2a4a8a", string: "#5a6a32", comment: "#9a907a")
        )
    ]

    public static func theme(id: String) -> ThemeSpec? {
        builtIns.first { $0.id == id }
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

    public init(
        background: HexColor,
        panel: HexColor,
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
        danger: HexColor
    ) {
        self.background = background
        self.panel = panel
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
    }
}

public struct TerminalColors: Equatable, Codable, Sendable {
    public var foreground: HexColor
    public var background: HexColor
    public var prompt: HexColor
    public var cursor: HexColor
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
}

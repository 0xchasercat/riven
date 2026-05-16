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
            chrome: ThemeChrome(background: "#0e0a07", panel: "#1a130d", border: "#0a0604", activeBorder: "#c89858", text: "#ece1cb", dimText: "#8a7a62"),
            terminal: TerminalColors(foreground: "#ece1cb", background: "#1a130d", prompt: "#d9a663", cursor: "#d9a663"),
            syntax: SyntaxColors(keyword: "#d9a663", function: "#ece1cb", string: "#a8945c", comment: "#5a4a30")
        ),
        ThemeSpec(
            id: "carbon",
            name: "Carbon",
            chrome: ThemeChrome(background: "#0c0c0c", panel: "#111111", border: "#1f1f1f", activeBorder: "#3a3a3a", text: "#d4d4d4", dimText: "#6a6a6a"),
            terminal: TerminalColors(foreground: "#d4d4d4", background: "#111111", prompt: "#888888", cursor: "#e8e8e8"),
            syntax: SyntaxColors(keyword: "#c8c8c8", function: "#e8e8e8", string: "#9a9a9a", comment: "#4a4a4a")
        ),
        ThemeSpec(
            id: "tokyo",
            name: "Tokyo",
            chrome: ThemeChrome(background: "#13131c", panel: "#1a1b26", border: "#272a3e", activeBorder: "#bb9af7", text: "#c0caf5", dimText: "#6b7394"),
            terminal: TerminalColors(foreground: "#c0caf5", background: "#1a1b26", prompt: "#bb9af7", cursor: "#bb9af7"),
            syntax: SyntaxColors(keyword: "#bb9af7", function: "#7aa2f7", string: "#9ece6a", comment: "#565f89")
        ),
        ThemeSpec(
            id: "paper",
            name: "Paper",
            chrome: ThemeChrome(background: "#ece7da", panel: "#f6f2e7", border: "#d4cdb8", activeBorder: "#2a2620", text: "#2a2620", dimText: "#8a8268"),
            terminal: TerminalColors(foreground: "#2a2620", background: "#f6f2e7", prompt: "#6a5a30", cursor: "#2a2620"),
            syntax: SyntaxColors(keyword: "#6a3a8a", function: "#2a4a8a", string: "#5a6a32", comment: "#9a907a")
        )
    ]

    public static func theme(id: String) -> ThemeSpec? {
        builtIns.first { $0.id == id }
    }
}

public struct ThemeChrome: Equatable, Codable, Sendable {
    public var background: HexColor
    public var panel: HexColor
    public var border: HexColor
    public var activeBorder: HexColor
    public var text: HexColor
    public var dimText: HexColor
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

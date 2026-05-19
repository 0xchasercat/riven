import Foundation

public enum CommandAction: String, Codable, Sendable {
    case splitRight
    case splitDown
    case flipPane
    case zoomPane
    case closePane
    case openProject
    case openFile
    case restoreSession
    case search
    case trustProject
    /// Toggle the command-bar's submission key between Enter and
    /// Cmd+Enter. The preference is persisted in ThemePreferenceStore.
    case toggleSubmitOnEnter
}

public struct Command: Equatable, Codable, Sendable, Identifiable {
    public var id: CommandAction
    public var group: String
    public var title: String
    public var shortcut: String?

    public init(id: CommandAction, group: String, title: String, shortcut: String? = nil) {
        self.id = id
        self.group = group
        self.title = title
        self.shortcut = shortcut
    }

    public static let bentoBuiltIns: [Command] = [
        Command(id: .splitRight, group: "Pane", title: "Split pane right", shortcut: "cmd+d"),
        Command(id: .splitDown, group: "Pane", title: "Split pane down", shortcut: "cmd+shift+d"),
        Command(id: .flipPane, group: "Pane", title: "Flip pane: terminal/editor", shortcut: "cmd+return"),
        Command(id: .zoomPane, group: "Pane", title: "Zoom active pane", shortcut: "cmd+/"),
        Command(id: .closePane, group: "Pane", title: "Close active pane", shortcut: "cmd+w"),
        Command(id: .openProject, group: "Project", title: "Open project", shortcut: "cmd+o"),
        Command(id: .openFile, group: "Project", title: "Open file…", shortcut: "cmd+p"),
        Command(id: .trustProject, group: "Project", title: "Trust this project"),
        Command(id: .restoreSession, group: "Project", title: "Restore last session"),
        Command(id: .search, group: "Search", title: "Search files and scrollback", shortcut: "cmd+shift+f"),
        Command(id: .toggleSubmitOnEnter, group: "Input", title: "Toggle Enter behavior in command bar")
    ]
}

public struct CommandPalette: Sendable {
    public var commands: [Command]

    public init(commands: [Command]) {
        self.commands = commands
    }

    public func search(_ query: String) -> [Command] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return commands }
        return commands.filter { command in
            command.title.lowercased().contains(normalized) ||
                command.group.lowercased().contains(normalized) ||
                command.id.rawValue.lowercased().contains(normalized)
        }
    }
}

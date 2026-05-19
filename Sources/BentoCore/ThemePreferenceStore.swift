import Foundation

public enum ThemePreferenceError: Error, Equatable {
    case unknownTheme(String)
}

public final class ThemePreferenceStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "Bento.selectedThemeID"
    private let submitOnEnterKey = "Bento.commandBar.submitOnEnter"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var selectedTheme: ThemeSpec {
        guard let id = defaults.string(forKey: key), let theme = ThemeSpec.theme(id: id) else {
            return ThemeSpec.builtIns[0]
        }
        return theme
    }

    public var hasExplicitSelection: Bool {
        defaults.string(forKey: key) != nil
    }

    public func selectTheme(id: String) throws {
        guard ThemeSpec.theme(id: id) != nil else {
            throw ThemePreferenceError.unknownTheme(id)
        }
        defaults.set(id, forKey: key)
    }

    // MARK: - Command-bar submission

    /// `true` means Enter submits and Cmd+Enter inserts a newline
    /// (terminal-style). `false` (default) means Enter inserts a
    /// newline and Cmd+Enter submits — Slack/Discord/Claude style.
    /// Persisted so the user's choice survives across launches.
    public var submitsOnEnter: Bool {
        get { defaults.bool(forKey: submitOnEnterKey) }
        set { defaults.set(newValue, forKey: submitOnEnterKey) }
    }

    public func toggleSubmitsOnEnter() {
        submitsOnEnter.toggle()
    }
}

import Foundation

public enum ThemePreferenceError: Error, Equatable {
    case unknownTheme(String)
}

public final class ThemePreferenceStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "Riven.selectedThemeID"
    private let submitOnEnterKey = "Riven.commandBar.submitOnEnter"

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

    /// `true` (default) means Enter submits and Cmd+Enter inserts a
    /// newline — closest to a real shell prompt's behavior, which is
    /// what users typing into a terminal-shaped surface expect by
    /// default. `false` flips it: Enter inserts a newline and
    /// Cmd+Enter submits (Slack / Discord / Claude style).
    ///
    /// Stored using a present/absent distinction so we can detect "the
    /// user has never set this" (return true) vs "the user explicitly
    /// chose false" (return false). `UserDefaults.bool(forKey:)` would
    /// flatten those into the same `false` and clobber the new default.
    public var submitsOnEnter: Bool {
        get {
            if defaults.object(forKey: submitOnEnterKey) == nil { return true }
            return defaults.bool(forKey: submitOnEnterKey)
        }
        set { defaults.set(newValue, forKey: submitOnEnterKey) }
    }

    public func toggleSubmitsOnEnter() {
        submitsOnEnter.toggle()
    }
}

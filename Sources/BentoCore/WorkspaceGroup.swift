import Foundation

/// A self-contained workspace unit: one shell with its own file viewer and
/// optional editor. Splitting the pane graph creates a new `WorkspaceGroup`
/// next to the existing one, so each split is its own coherent context.
///
/// `currentCwd` is initially seeded from `initialCwd` but updated as the
/// shell emits OSC 7 sequences (which Ghostty parses and surfaces via
/// `GHOSTTY_TERMINAL_DATA_PWD`). The file viewer rebinds to that path so
/// `cd` in the shell moves the sidebar with it.
///
/// `openEditorPath` is nil when the workspace shows only a sidebar +
/// terminal; non-nil when an editor pane is also visible (e.g. after the
/// user clicked a file in the sidebar).
public struct WorkspaceGroup: Hashable, Codable, Sendable {
    public var initialCwd: String
    public var currentCwd: String
    public var terminalCommand: String?
    public var openEditorPath: String?
    public var sidebarWidth: CGFloat
    public var editorWidth: CGFloat
    public var focusedSubpane: WorkspaceSubpane

    public init(
        initialCwd: String,
        currentCwd: String? = nil,
        terminalCommand: String? = nil,
        openEditorPath: String? = nil,
        sidebarWidth: CGFloat = 200,
        editorWidth: CGFloat = 480,
        focusedSubpane: WorkspaceSubpane = .terminal
    ) {
        self.initialCwd = initialCwd
        self.currentCwd = currentCwd ?? initialCwd
        self.terminalCommand = terminalCommand
        self.openEditorPath = openEditorPath
        self.sidebarWidth = sidebarWidth
        self.editorWidth = editorWidth
        self.focusedSubpane = focusedSubpane
    }
}

/// Which subpane inside a `WorkspaceGroup` has keyboard focus. Persisted
/// in snapshots so the user lands back in the same subpane after a restart.
public enum WorkspaceSubpane: String, Codable, Sendable {
    case sidebar
    case terminal
    case editor
}

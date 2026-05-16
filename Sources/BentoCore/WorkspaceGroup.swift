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
    /// Updated as the shell emits OSC 7. Useful for status/breadcrumb
    /// surfaces; deliberately NOT used to drive the sidebar (sidebar is
    /// pinned to `initialCwd` — the workspace's root — so `cd /tmp` in
    /// the shell doesn't rip the file viewer out from under the user).
    public var currentCwd: String
    public var terminalCommand: String?
    public var openEditorPath: String?
    public var sidebarWidth: CGFloat
    public var editorWidth: CGFloat
    public var focusedSubpane: WorkspaceSubpane
    /// Sidebar visibility. `.collapsed` (default) shows top-level
    /// directory names only at a narrow width; `.expanded` shows the
    /// full nested tree at the configured `sidebarWidth`.
    public var sidebarState: WorkspaceSidebarState

    public init(
        initialCwd: String,
        currentCwd: String? = nil,
        terminalCommand: String? = nil,
        openEditorPath: String? = nil,
        sidebarWidth: CGFloat = 220,
        editorWidth: CGFloat = 480,
        focusedSubpane: WorkspaceSubpane = .terminal,
        sidebarState: WorkspaceSidebarState = .collapsed
    ) {
        self.initialCwd = initialCwd
        self.currentCwd = currentCwd ?? initialCwd
        self.terminalCommand = terminalCommand
        self.openEditorPath = openEditorPath
        self.sidebarWidth = sidebarWidth
        self.editorWidth = editorWidth
        self.focusedSubpane = focusedSubpane
        self.sidebarState = sidebarState
    }
}

public enum WorkspaceSidebarState: String, Codable, Sendable {
    /// Narrow strip showing top-level directory names only.
    case collapsed
    /// Full nested tree at `sidebarWidth`.
    case expanded
}

/// Which subpane inside a `WorkspaceGroup` has keyboard focus. Persisted
/// in snapshots so the user lands back in the same subpane after a restart.
public enum WorkspaceSubpane: String, Codable, Sendable {
    case sidebar
    case terminal
    case editor
}

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
    /// Inner tabs within this workspace. Each tab is its own terminal
    /// with a unique paneID (so each has its own PTY at the broker).
    /// The sidebar is shared across all inner tabs — that's the whole
    /// point of the workspace boundary. Switching inner tabs swaps the
    /// active terminal under the same sidebar + command bar.
    public var tabs: [WorkspaceInnerTab]
    /// Which inner tab currently has focus / is rendered. Must match
    /// one of `tabs[*].id`; if it doesn't, `tabs[0]` is the fallback.
    public var focusedTabID: TabID

    public init(
        initialCwd: String,
        currentCwd: String? = nil,
        terminalCommand: String? = nil,
        openEditorPath: String? = nil,
        sidebarWidth: CGFloat = 220,
        editorWidth: CGFloat = 480,
        focusedSubpane: WorkspaceSubpane = .terminal,
        sidebarState: WorkspaceSidebarState = .collapsed,
        tabs: [WorkspaceInnerTab]? = nil,
        focusedTabID: TabID? = nil
    ) {
        self.initialCwd = initialCwd
        self.currentCwd = currentCwd ?? initialCwd
        self.terminalCommand = terminalCommand
        self.openEditorPath = openEditorPath
        self.sidebarWidth = sidebarWidth
        self.editorWidth = editorWidth
        self.focusedSubpane = focusedSubpane
        self.sidebarState = sidebarState
        // Default workspace ships with a single "shell" inner tab. The
        // tab's paneID is fresh per workspace so each one gets its own
        // PTY at the broker.
        let defaultTab = WorkspaceInnerTab(
            id: TabID(),
            displayName: "shell",
            terminalPaneID: PaneID(),
            command: terminalCommand,
            cwd: initialCwd
        )
        let resolvedTabs = tabs ?? [defaultTab]
        self.tabs = resolvedTabs
        self.focusedTabID = focusedTabID ?? resolvedTabs.first?.id ?? defaultTab.id
    }

    /// Convenience: the currently-focused inner tab, or the first tab
    /// if the focused ID doesn't resolve (defensive).
    public var focusedTab: WorkspaceInnerTab {
        tabs.first(where: { $0.id == focusedTabID }) ?? tabs[0]
    }
}

/// One inner tab within a workspace. Carries the broker `PaneID` used
/// to address its PTY plus the display name shown in the inner tab strip.
public struct WorkspaceInnerTab: Hashable, Codable, Sendable, Identifiable {
    public var id: TabID
    public var displayName: String
    public var terminalPaneID: PaneID
    public var command: String?
    public var cwd: String

    public init(
        id: TabID = TabID(),
        displayName: String,
        terminalPaneID: PaneID,
        command: String? = nil,
        cwd: String
    ) {
        self.id = id
        self.displayName = displayName
        self.terminalPaneID = terminalPaneID
        self.command = command
        self.cwd = cwd
    }
}

/// Stable identifier for inner tabs. Lives across renders so the broker
/// can hold onto a tab's PTY by `terminalPaneID` and the UI can re-mount
/// its NSHostingController without losing state.
public struct TabID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String = UUID().uuidString) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
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

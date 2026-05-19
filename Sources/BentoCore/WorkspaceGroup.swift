import Foundation

/// A self-contained workspace unit: one shell with its own file viewer and
/// a stack of inner tabs (each terminal or editor). Splitting the pane
/// graph creates a new `WorkspaceGroup` next to the existing one, so each
/// split is its own coherent context.
///
/// `currentCwd` is initially seeded from `initialCwd` but updated as the
/// shell emits OSC 7 sequences (which Ghostty parses and surfaces via
/// `GHOSTTY_TERMINAL_DATA_PWD`). The file viewer rebinds to that path so
/// `cd` in the shell moves the sidebar with it.
///
/// The "open a file in the editor" flow no longer adds a side column —
/// it appends (or focuses) an `.editor` inner tab. That's the opinionated
/// bento layout: one tab is one thing (terminal OR editor), all sharing
/// the workspace's sidebar.
public struct WorkspaceGroup: Hashable, Codable, Sendable {
    public var initialCwd: String
    /// Updated as the shell emits OSC 7. Useful for status/breadcrumb
    /// surfaces; deliberately NOT used to drive the sidebar (sidebar is
    /// pinned to `initialCwd` — the workspace's root — so `cd /tmp` in
    /// the shell doesn't rip the file viewer out from under the user).
    public var currentCwd: String
    public var terminalCommand: String?
    public var sidebarWidth: CGFloat
    /// Width hint for editor tabs. Retained as a per-workspace preference
    /// so future split-editor experiments can reuse it; today editor tabs
    /// fill the whole tab area so this is informational only.
    public var editorWidth: CGFloat
    public var focusedSubpane: WorkspaceSubpane
    /// Sidebar visibility. `.collapsed` (default) shows top-level
    /// directory names only at a narrow width; `.expanded` shows the
    /// full nested tree at the configured `sidebarWidth`.
    public var sidebarState: WorkspaceSidebarState
    /// Inner tabs within this workspace. Each tab is its own surface —
    /// either a terminal (with a unique broker `PaneID` for its PTY) or
    /// an editor pointed at a file path. The sidebar is shared across
    /// all inner tabs — that's the whole point of the workspace boundary.
    /// Switching inner tabs swaps the active surface under the same
    /// sidebar + (for terminal tabs) command bar.
    public var tabs: [WorkspaceInnerTab]
    /// Which inner tab currently has focus / is rendered. Must match
    /// one of `tabs[*].id`; if it doesn't, `tabs[0]` is the fallback.
    public var focusedTabID: TabID

    public init(
        initialCwd: String,
        currentCwd: String? = nil,
        terminalCommand: String? = nil,
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
            kind: .terminal(paneID: PaneID(), command: terminalCommand),
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

    // MARK: - Pure mutators
    //
    // These are intentionally pure so the controller's tab plumbing can
    // be exercised in tests without spinning up the full @MainActor
    // BentoRootController (which does file I/O at init). The controller
    // is just a thin layer that calls these and republishes the result.

    /// Return a copy of this workspace with `tab` appended to the inner
    /// tab list and focus moved to the new tab. The append is unchecked
    /// — callers that need uniqueness (e.g. "don't add a second tab for
    /// the same file") should pre-check.
    public func appendingTab(_ tab: WorkspaceInnerTab) -> WorkspaceGroup {
        var copy = self
        copy.tabs.append(tab)
        copy.focusedTabID = tab.id
        return copy
    }

    /// Return a copy of this workspace with the tab matching `id`
    /// removed. If `id` is the focused tab, focus moves to its left
    /// neighbour (or the first tab when the closed tab was at index 0).
    /// No-op when:
    ///   - the workspace has only one tab (we never let a workspace go
    ///     tabless — every workspace must have at least its shell),
    ///   - `id` doesn't match any tab.
    public func removingTab(_ id: TabID) -> WorkspaceGroup {
        guard tabs.count > 1,
              let idx = tabs.firstIndex(where: { $0.id == id })
        else { return self }
        var copy = self
        copy.tabs.remove(at: idx)
        if copy.focusedTabID == id {
            copy.focusedTabID = copy.tabs[max(0, idx - 1)].id
        }
        return copy
    }

    /// Return a copy of this workspace with focus moved to `id`. No-op
    /// when `id` is already focused or doesn't match any tab.
    public func focusingTab(_ id: TabID) -> WorkspaceGroup {
        guard id != focusedTabID, tabs.contains(where: { $0.id == id }) else { return self }
        var copy = self
        copy.focusedTabID = id
        return copy
    }

    // MARK: - Codable
    //
    // Custom decoder so legacy snapshots (which carry an `openEditorPath`
    // field and a flat `terminalPaneID` on each tab) still resurrect.
    // `openEditorPath`, if present, becomes a fresh `.editor` tab appended
    // to whatever terminal tabs already exist.

    private enum CodingKeys: String, CodingKey {
        case initialCwd
        case currentCwd
        case terminalCommand
        case sidebarWidth
        case editorWidth
        case focusedSubpane
        case sidebarState
        case tabs
        case focusedTabID
        // Legacy:
        case openEditorPath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.initialCwd = try c.decode(String.self, forKey: .initialCwd)
        self.currentCwd = try c.decodeIfPresent(String.self, forKey: .currentCwd) ?? self.initialCwd
        self.terminalCommand = try c.decodeIfPresent(String.self, forKey: .terminalCommand)
        self.sidebarWidth = try c.decodeIfPresent(CGFloat.self, forKey: .sidebarWidth) ?? 220
        self.editorWidth = try c.decodeIfPresent(CGFloat.self, forKey: .editorWidth) ?? 480
        self.focusedSubpane = try c.decodeIfPresent(WorkspaceSubpane.self, forKey: .focusedSubpane) ?? .terminal
        self.sidebarState = try c.decodeIfPresent(WorkspaceSidebarState.self, forKey: .sidebarState) ?? .collapsed

        var decodedTabs = try c.decodeIfPresent([WorkspaceInnerTab].self, forKey: .tabs) ?? []
        if decodedTabs.isEmpty {
            // Pre-tabs snapshot: synthesize the default shell tab.
            decodedTabs = [WorkspaceInnerTab(
                id: TabID(),
                displayName: "shell",
                kind: .terminal(paneID: PaneID(), command: self.terminalCommand),
                cwd: self.initialCwd
            )]
        }
        // Legacy `openEditorPath` becomes an appended editor tab so the
        // user lands back in the same file even though the storage shape
        // changed.
        if let legacyEditor = try c.decodeIfPresent(String.self, forKey: .openEditorPath),
           !legacyEditor.isEmpty,
           !decodedTabs.contains(where: { $0.editorPath == legacyEditor }) {
            decodedTabs.append(WorkspaceInnerTab(
                id: TabID(),
                displayName: URL(fileURLWithPath: legacyEditor).lastPathComponent,
                kind: .editor(path: legacyEditor),
                cwd: self.initialCwd
            ))
        }
        self.tabs = decodedTabs

        let decodedFocus = try c.decodeIfPresent(TabID.self, forKey: .focusedTabID)
        self.focusedTabID = decodedFocus ?? decodedTabs.first?.id ?? TabID()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(initialCwd, forKey: .initialCwd)
        try c.encode(currentCwd, forKey: .currentCwd)
        try c.encodeIfPresent(terminalCommand, forKey: .terminalCommand)
        try c.encode(sidebarWidth, forKey: .sidebarWidth)
        try c.encode(editorWidth, forKey: .editorWidth)
        try c.encode(focusedSubpane, forKey: .focusedSubpane)
        try c.encode(sidebarState, forKey: .sidebarState)
        try c.encode(tabs, forKey: .tabs)
        try c.encode(focusedTabID, forKey: .focusedTabID)
        // Don't re-emit `openEditorPath` — it's strictly a decode-side
        // back-compat hook.
    }
}

/// One inner tab within a workspace. Carries its `kind` (terminal or
/// editor) plus the display name shown in the inner tab strip and the
/// cwd the tab was created under (informational; the broker still owns
/// the live PTY's cwd via OSC 7).
public struct WorkspaceInnerTab: Hashable, Codable, Sendable, Identifiable {
    public var id: TabID
    public var displayName: String
    public var kind: WorkspaceInnerTabKind
    public var cwd: String

    public init(
        id: TabID = TabID(),
        displayName: String,
        kind: WorkspaceInnerTabKind,
        cwd: String
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.cwd = cwd
    }

    /// Back-compat accessor: the broker PaneID for terminal tabs, nil
    /// for editor tabs. Callers reaching for this should branch on
    /// `kind` instead — this is kept to keep diffs small in views that
    /// were written before tabs grew variants.
    public var terminalPaneID: PaneID? {
        if case let .terminal(paneID, _) = kind { return paneID }
        return nil
    }

    /// Back-compat accessor: the optional shell command for terminal tabs.
    public var command: String? {
        if case let .terminal(_, command) = kind { return command }
        return nil
    }

    /// The file path for editor tabs (nil = scratch / unsaved buffer
    /// OR the tab isn't an editor at all — distinguish via `isEditor`).
    public var editorPath: String? {
        if case let .editor(path) = kind { return path }
        return nil
    }

    /// `true` when this tab is an editor (scratch or file-backed).
    /// Use this to differentiate "scratch tab" from "not an editor"
    /// when both return nil from `editorPath`.
    public var isEditor: Bool {
        if case .editor = kind { return true }
        return false
    }

    // MARK: - Codable
    //
    // Permissive decoder so legacy snapshots — which encoded a flat
    // `terminalPaneID` + `command` and no `kind` — still resurrect as
    // `.terminal` tabs.

    private enum CodingKeys: String, CodingKey {
        case id, displayName, kind, cwd, terminalPaneID, command
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(TabID.self, forKey: .id)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.cwd = try c.decode(String.self, forKey: .cwd)
        if let kind = try c.decodeIfPresent(WorkspaceInnerTabKind.self, forKey: .kind) {
            self.kind = kind
        } else {
            // Legacy shape: a flat `terminalPaneID` + `command` lived on
            // the tab itself. Reconstruct a `.terminal` kind from those.
            let paneID = try c.decode(PaneID.self, forKey: .terminalPaneID)
            let command = try c.decodeIfPresent(String.self, forKey: .command)
            self.kind = .terminal(paneID: paneID, command: command)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(kind, forKey: .kind)
        try c.encode(cwd, forKey: .cwd)
    }
}

/// What a `WorkspaceInnerTab` is. A `.terminal` tab carries its own
/// broker `PaneID` (the address of its PTY) and an optional shell
/// command; an `.editor` tab carries an optional file path the editor
/// is bound to (`nil` = an unsaved scratch buffer). Persisted in
/// snapshots so each tab survives a restart with its surface kind
/// intact.
public enum WorkspaceInnerTabKind: Hashable, Codable, Sendable {
    case terminal(paneID: PaneID, command: String?)
    case editor(path: String?)
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

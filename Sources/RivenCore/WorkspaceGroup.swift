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
/// Riven layout: one tab is one thing (terminal OR editor), all sharing
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
    /// User-given name for this workspace, overriding the cwd-derived
    /// label that WorkspaceTabBar would otherwise pick. `nil` (default)
    /// falls back to that derivation; an empty string is normalized
    /// back to `nil` on assignment. Persisted in snapshots.
    public var customName: String? {
        didSet {
            if customName?.isEmpty == true { customName = nil }
        }
    }

    public init(
        initialCwd: String,
        currentCwd: String? = nil,
        terminalCommand: String? = nil,
        sidebarWidth: CGFloat = 220,
        editorWidth: CGFloat = 480,
        focusedSubpane: WorkspaceSubpane = .terminal,
        sidebarState: WorkspaceSidebarState = .collapsed,
        tabs: [WorkspaceInnerTab]? = nil,
        focusedTabID: TabID? = nil,
        customName: String? = nil
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
        self.customName = (customName?.isEmpty == true) ? nil : customName
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
    // RivenRootController (which does file I/O at init). The controller
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

    /// Return a copy with the workspace's `customName` set. Empty string
    /// or whitespace-only normalizes to nil (reverts to the cwd-derived
    /// label). No-op when the value is unchanged.
    public func renamed(to newName: String?) -> WorkspaceGroup {
        let normalized: String? = {
            guard let trimmed = newName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { return nil }
            return trimmed
        }()
        guard customName != normalized else { return self }
        var copy = self
        copy.customName = normalized
        return copy
    }

    /// Return a copy with the focused tab's focused surface split by
    /// `direction`, adding `newSurface` as the new sibling. The new
    /// surface takes focus inside the tab. No-op when no tab is
    /// focused.
    public func splittingFocusedSurface(
        direction: SplitDirection,
        newSurface: TabSurface
    ) -> WorkspaceGroup {
        guard let idx = tabs.firstIndex(where: { $0.id == focusedTabID }) else { return self }
        var copy = self
        copy.tabs[idx] = tabs[idx].splittingFocusedSurface(
            direction: direction,
            newSurface: newSurface
        )
        return copy
    }

    /// Remove `surfaceID` from `tabID`. No-op when:
    /// - tab not found,
    /// - surface not found inside the tab,
    /// - removing it would leave the tab empty (close the whole tab
    ///   via `removingTab` instead).
    public func removingSurface(tabID: TabID, surfaceID: SurfaceID) -> WorkspaceGroup {
        guard let idx = tabs.firstIndex(where: { $0.id == tabID }) else { return self }
        let updated = tabs[idx].removingSurface(surfaceID)
        guard updated != tabs[idx] else { return self }
        var copy = self
        copy.tabs[idx] = updated
        return copy
    }

    /// Move focus to `surfaceID` inside `tabID`. No-op when the
    /// surface is already focused or doesn't exist.
    public func focusingSurface(tabID: TabID, surfaceID: SurfaceID) -> WorkspaceGroup {
        guard let idx = tabs.firstIndex(where: { $0.id == tabID }) else { return self }
        let updated = tabs[idx].focusingSurface(surfaceID)
        guard updated != tabs[idx] else { return self }
        var copy = self
        copy.tabs[idx] = updated
        return copy
    }

    /// Cycle focus inside `tabID` to the next surface in layout DFS
    /// order. No-op when the tab has only one surface.
    public func focusingNextSurface(tabID: TabID) -> WorkspaceGroup {
        guard let idx = tabs.firstIndex(where: { $0.id == tabID }) else { return self }
        let updated = tabs[idx].focusingNextSurface()
        guard updated != tabs[idx] else { return self }
        var copy = self
        copy.tabs[idx] = updated
        return copy
    }

    /// Return a copy with `id`'s `displayName` set to `newName`. Empty
    /// string or whitespace-only resets the display name to the
    /// kind-default (`shell` for terminals, file basename for editors).
    /// No-op when `id` doesn't match any tab.
    public func renamingTab(_ id: TabID, to newName: String) -> WorkspaceGroup {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return self }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved: String
        if trimmed.isEmpty {
            // Reset to the kind-default.
            switch tabs[idx].kind {
            case .terminal:
                resolved = "shell"
            case .editor(let path):
                resolved = path.flatMap { URL(fileURLWithPath: $0).lastPathComponent } ?? "Untitled"
            case .scrollbackPeek:
                resolved = "scrollback"
            }
        } else {
            resolved = trimmed
        }
        guard tabs[idx].displayName != resolved else { return self }
        var copy = self
        copy.tabs[idx].displayName = resolved
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
        case customName
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

        let decodedName = try c.decodeIfPresent(String.self, forKey: .customName)
        self.customName = (decodedName?.isEmpty == true) ? nil : decodedName
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
        try c.encodeIfPresent(customName, forKey: .customName)
        // Don't re-emit `openEditorPath` — it's strictly a decode-side
        // back-compat hook.
    }
}

/// One inner tab within a workspace. A tab is a stack of one or more
/// **surfaces** (terminal or editor leaves) arranged by a recursive
/// **layout** tree. A tab with a single surface is a regular flat tab
/// (the only shape that existed pre-#23); a tab with a `.split` layout
/// renders multiple surfaces side-by-side or stacked.
///
/// Every surface has its own broker `PaneID` (for terminals) or
/// editor path (for editors). Focus is at the surface level — the
/// command bar writes into `focusedSurface.terminalPaneID`, the
/// rename-tab dialog still works on the whole tab.
public struct WorkspaceInnerTab: Hashable, Codable, Sendable, Identifiable {
    public var id: TabID
    public var displayName: String
    /// Origin cwd when the tab was first created. Each surface keeps
    /// its own working directory after that (via OSC 7); this is the
    /// seed used for any new surface added via split.
    public var cwd: String
    /// Every surface (terminal/editor leaf) inside this tab. A tab
    /// always has at least one surface; closing the last surface is a
    /// no-op (close the whole tab instead).
    public var surfaces: [TabSurface]
    /// How the surfaces are arranged spatially. Leaves point to
    /// surfaces by id. Single-surface tabs use a `.leaf` layout.
    public var layout: TabLayout
    /// Which surface inside this tab currently has focus. Must match
    /// one of `surfaces[*].id`; defensive fallback to `surfaces[0]`.
    public var focusedSurfaceID: SurfaceID

    /// Primary constructor — pass a single `kind` and the tab is built
    /// with one surface containing it. Multi-surface tabs are
    /// constructed via `splittingFocusedSurface(...)`.
    public init(
        id: TabID = TabID(),
        displayName: String,
        kind: WorkspaceInnerTabKind,
        cwd: String
    ) {
        self.id = id
        self.displayName = displayName
        self.cwd = cwd
        let surface = TabSurface(id: SurfaceID(), kind: kind)
        self.surfaces = [surface]
        self.layout = .leaf(surface.id)
        self.focusedSurfaceID = surface.id
    }

    /// Lower-level constructor for tests + persistence — takes the
    /// surface list, layout, and focus id explicitly. Use the
    /// kind-based init for everyday code paths.
    public init(
        id: TabID,
        displayName: String,
        cwd: String,
        surfaces: [TabSurface],
        layout: TabLayout,
        focusedSurfaceID: SurfaceID
    ) {
        precondition(!surfaces.isEmpty, "WorkspaceInnerTab must contain at least one surface")
        self.id = id
        self.displayName = displayName
        self.cwd = cwd
        self.surfaces = surfaces
        self.layout = layout
        self.focusedSurfaceID = focusedSurfaceID
    }

    /// The currently-focused surface, or `surfaces[0]` if
    /// `focusedSurfaceID` doesn't resolve (defensive).
    public var focusedSurface: TabSurface {
        surfaces.first(where: { $0.id == focusedSurfaceID }) ?? surfaces[0]
    }

    /// `true` when the tab has more than one surface (i.e. the layout
    /// contains a `.split`). Cheaper than walking the layout tree.
    public var isSplit: Bool { surfaces.count > 1 }

    /// Back-compat accessor: the kind of the focused surface. Most
    /// pre-#23 code reaches for `tab.kind`; that still works and
    /// returns whatever's under the caret.
    public var kind: WorkspaceInnerTabKind { focusedSurface.kind }

    /// Back-compat accessor: the broker `PaneID` for the focused
    /// surface if it's a terminal, nil otherwise. Used by the command
    /// bar to route input.
    public var terminalPaneID: PaneID? {
        if case let .terminal(paneID, _) = focusedSurface.kind { return paneID }
        return nil
    }

    /// Back-compat accessor: the optional shell command for the
    /// focused surface (terminal only).
    public var command: String? {
        if case let .terminal(_, command) = focusedSurface.kind { return command }
        return nil
    }

    /// Back-compat accessor: the file path of the focused surface if
    /// it's an editor (nil = scratch buffer; also nil if the focused
    /// surface isn't an editor — distinguish via `isEditor`).
    public var editorPath: String? {
        if case let .editor(path) = focusedSurface.kind { return path }
        return nil
    }

    /// `true` when the focused surface is an editor (scratch or
    /// file-backed). Disambiguates "scratch editor" from "not an
    /// editor" when both return nil from `editorPath`.
    public var isEditor: Bool {
        if case .editor = focusedSurface.kind { return true }
        return false
    }

    // MARK: - Pure split mutators

    /// Return a copy with `direction`-split at the currently-focused
    /// surface. The focused surface stays; `newSurface` becomes its
    /// sibling in a new `.split` node, and focus moves to the new
    /// surface so the user can immediately interact with it.
    public func splittingFocusedSurface(
        direction: SplitDirection,
        newSurface: TabSurface
    ) -> WorkspaceInnerTab {
        var copy = self
        copy.surfaces.append(newSurface)
        copy.layout = Self.replaceLeaf(
            in: layout,
            target: focusedSurfaceID,
            with: .split(direction, .leaf(focusedSurfaceID), .leaf(newSurface.id))
        )
        copy.focusedSurfaceID = newSurface.id
        return copy
    }

    /// Return a copy with `id` removed from both the surface list AND
    /// the layout (collapsing any single-child split nodes that result
    /// from the removal — same idea as `PaneGraph.close`). No-op when
    /// `id` doesn't exist or when removing it would leave the tab
    /// empty.
    public func removingSurface(_ id: SurfaceID) -> WorkspaceInnerTab {
        guard surfaces.count > 1,
              surfaces.contains(where: { $0.id == id }) else { return self }
        var copy = self
        copy.surfaces.removeAll(where: { $0.id == id })
        copy.layout = Self.removingLeaf(from: layout, target: id) ?? .leaf(copy.surfaces[0].id)
        if copy.focusedSurfaceID == id {
            copy.focusedSurfaceID = copy.surfaces[0].id
        }
        return copy
    }

    /// Move focus to `id` if it's a known surface; no-op otherwise.
    public func focusingSurface(_ id: SurfaceID) -> WorkspaceInnerTab {
        guard id != focusedSurfaceID, surfaces.contains(where: { $0.id == id }) else { return self }
        var copy = self
        copy.focusedSurfaceID = id
        return copy
    }

    /// Cycle focus to the "next" surface in layout-tree DFS order.
    /// Useful for keyboard navigation between split panes.
    public func focusingNextSurface() -> WorkspaceInnerTab {
        let ordered = Self.leafIDs(of: layout)
        guard ordered.count > 1,
              let currentIdx = ordered.firstIndex(of: focusedSurfaceID) else { return self }
        let nextIdx = (currentIdx + 1) % ordered.count
        return focusingSurface(ordered[nextIdx])
    }

    // MARK: - Layout-tree helpers (private)

    /// Walk `node` and return a tree where every `.leaf(target)` is
    /// replaced with `replacement`. Other leaves and split shapes are
    /// preserved. Used by split: the focused leaf becomes a new split
    /// with the focused leaf + new leaf as children.
    private static func replaceLeaf(
        in node: TabLayout,
        target: SurfaceID,
        with replacement: TabLayout
    ) -> TabLayout {
        switch node {
        case let .leaf(id):
            return id == target ? replacement : node
        case let .split(direction, lhs, rhs):
            return .split(
                direction,
                replaceLeaf(in: lhs, target: target, with: replacement),
                replaceLeaf(in: rhs, target: target, with: replacement)
            )
        }
    }

    /// Walk `node` and return a tree with `target` removed. When a
    /// split node ends up with only one child after removal, the
    /// surviving child takes the parent's place (collapses single-
    /// child splits). Returns `nil` only if the entire tree was the
    /// removed leaf — caller falls back to a default leaf.
    private static func removingLeaf(from node: TabLayout, target: SurfaceID) -> TabLayout? {
        switch node {
        case let .leaf(id):
            return id == target ? nil : node
        case let .split(direction, lhs, rhs):
            let newLhs = removingLeaf(from: lhs, target: target)
            let newRhs = removingLeaf(from: rhs, target: target)
            switch (newLhs, newRhs) {
            case let (.some(l), .some(r)):
                return .split(direction, l, r)
            case let (.some(l), .none):
                return l
            case let (.none, .some(r)):
                return r
            case (.none, .none):
                return nil
            }
        }
    }

    /// Collect leaf surface IDs in DFS order. Used by next-focus
    /// cycling so the user moves through splits in a predictable
    /// reading order (left→right, top→bottom).
    private static func leafIDs(of node: TabLayout) -> [SurfaceID] {
        switch node {
        case let .leaf(id):
            return [id]
        case let .split(_, lhs, rhs):
            return leafIDs(of: lhs) + leafIDs(of: rhs)
        }
    }

    // MARK: - Codable
    //
    // Permissive decoder so legacy snapshots resurrect correctly:
    //   1. Pre-#23 shape with `kind` (and optional `terminalPaneID` /
    //      `command` from the original launch). Synthesize one
    //      surface, layout = .leaf, focusedSurfaceID = that surface.
    //   2. Even-older shape with bare `terminalPaneID` + `command` and
    //      no `kind` field. Same migration — assemble a terminal
    //      surface from the flat fields.
    //   3. New (#23) shape with `surfaces` + `layout` + `focusedSurfaceID`.

    private enum CodingKeys: String, CodingKey {
        case id, displayName, cwd
        // New (#23) keys:
        case surfaces, layout, focusedSurfaceID
        // Pre-#23 keys (kept for decode-side back-compat):
        case kind, terminalPaneID, command
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(TabID.self, forKey: .id)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.cwd = try c.decode(String.self, forKey: .cwd)

        if let surfaces = try c.decodeIfPresent([TabSurface].self, forKey: .surfaces),
           !surfaces.isEmpty {
            // New shape.
            self.surfaces = surfaces
            self.layout = try c.decodeIfPresent(TabLayout.self, forKey: .layout)
                ?? .leaf(surfaces[0].id)
            let decodedFocus = try c.decodeIfPresent(SurfaceID.self, forKey: .focusedSurfaceID)
            self.focusedSurfaceID = decodedFocus ?? surfaces[0].id
        } else {
            // Legacy shape — promote into a single-surface tab.
            let kind: WorkspaceInnerTabKind
            if let decoded = try c.decodeIfPresent(WorkspaceInnerTabKind.self, forKey: .kind) {
                kind = decoded
            } else {
                // Even-older flat shape: terminalPaneID + command at
                // the tab level. Reconstruct a terminal kind.
                let paneID = try c.decode(PaneID.self, forKey: .terminalPaneID)
                let command = try c.decodeIfPresent(String.self, forKey: .command)
                kind = .terminal(paneID: paneID, command: command)
            }
            let surface = TabSurface(id: SurfaceID(), kind: kind)
            self.surfaces = [surface]
            self.layout = .leaf(surface.id)
            self.focusedSurfaceID = surface.id
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(cwd, forKey: .cwd)
        try c.encode(surfaces, forKey: .surfaces)
        try c.encode(layout, forKey: .layout)
        try c.encode(focusedSurfaceID, forKey: .focusedSurfaceID)
        // Don't re-emit `kind` / `terminalPaneID` / `command` — they
        // are strictly decode-side back-compat hooks. A round-trip
        // through this encoder upgrades the on-disk shape to the new
        // surface-tree form.
    }
}

/// One pane inside an inner tab. Terminal surfaces own their broker
/// `PaneID` (the address of the PTY); editor surfaces own a file
/// path or nil for a scratch buffer.
public struct TabSurface: Hashable, Codable, Sendable, Identifiable {
    public var id: SurfaceID
    public var kind: WorkspaceInnerTabKind

    public init(id: SurfaceID = SurfaceID(), kind: WorkspaceInnerTabKind) {
        self.id = id
        self.kind = kind
    }

    /// Display-friendly filename for editor surfaces (used by the
    /// close-prompt to name the file being saved). `nil` when the
    /// surface is a terminal OR an unsaved scratch editor.
    public var filename: String? {
        guard case let .editor(path) = kind, let path else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}

/// Stable identifier for surfaces (panes inside a tab). Same shape as
/// `TabID` / `PaneID`; opaque UUID-backed string by default.
public struct SurfaceID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String = UUID().uuidString) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// Recursive split tree describing how surfaces are arranged inside a
/// tab. `.leaf(id)` is a single surface filling its parent; `.split`
/// stacks two sub-layouts. Reuses `SplitDirection` from `PaneGraph`
/// (`.right` = side-by-side, `.down` = top/bottom).
public enum TabLayout: Hashable, Codable, Sendable {
    case leaf(SurfaceID)
    indirect case split(SplitDirection, TabLayout, TabLayout)
}

/// What a tab's surface is. A `.terminal` surface carries its own
/// broker `PaneID` (the address of its PTY) and an optional shell
/// command; an `.editor` surface carries an optional file path the
/// editor is bound to (`nil` = an unsaved scratch buffer); a
/// `.scrollbackPeek` is a read-only inline view of a pane's
/// scrollback log centered on `focusLine`, opened from the search
/// overlay's "peek" action. Persisted in snapshots so each surface
/// survives a restart with its kind intact.
public enum WorkspaceInnerTabKind: Hashable, Codable, Sendable {
    case terminal(paneID: PaneID, command: String?)
    case editor(path: String?)
    /// Read-only peek into the scrollback log of `paneID`, centered on
    /// `focusLine`. Has no PTY of its own — it just renders bytes from
    /// the on-disk log. Cannot be edited. The "Replay in new pane"
    /// toolbar button opens a fresh terminal seeded from the log if
    /// the user wants a live shell.
    case scrollbackPeek(paneID: PaneID, focusLine: Int)
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

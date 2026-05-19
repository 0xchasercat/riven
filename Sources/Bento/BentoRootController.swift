import AppKit
import BentoCore
import Combine
import Foundation

/// Bridges the actor-based `WorkspaceController` into SwiftUI.
///
/// Owns the persistent stores (trust, snapshots, scrollback), opens the cwd
/// as the current project at launch, and republishes the resulting
/// `WorkspaceState` on the main actor so views can bind to it.
@MainActor
final class BentoRootController: ObservableObject {
    let preference = ThemePreferenceStore()
    let workspace: WorkspaceController
    let fileMap = PaneFileMap()

    @Published private(set) var state: WorkspaceState
    @Published var openFilePaths: [String] = []
    @Published private(set) var agentClient: AgentClient?
    /// Bumped each time `agentClient` is replaced — initial connect counts
    /// as epoch 1, every subsequent watchdog respawn bumps to 2, 3, …
    /// Views that hold long-lived broker sessions stamp this into their
    /// SwiftUI `.id(...)` so they tear down + rebuild against the fresh
    /// client when the broker is respawned.
    @Published private(set) var brokerEpoch: Int = 0
    /// Mirrors `preference.submitsOnEnter` so SwiftUI views see the change
    /// the moment the user toggles via the palette. `false` (default) =
    /// Enter inserts a newline, Cmd+Enter submits — Slack/Claude pattern.
    @Published private(set) var submitsOnEnter: Bool = false

    init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Bento", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let trust = ProjectTrustStore()
        let snapshots = WorkspaceSnapshotStore(root: support.appendingPathComponent("snapshots", isDirectory: true))
        let scrollback = ScrollbackStore(root: support.appendingPathComponent("scrollback", isDirectory: true))
        let workspace = WorkspaceController(trustStore: trust, snapshotStore: snapshots, scrollbackStore: scrollback)
        self.workspace = workspace

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let themeID = preference.selectedTheme.id

        // Render with a synchronous fallback so the first frame has something
        // real, then refresh from the controller (which loads snapshots,
        // parses session.yml, scans the tree) on the next runloop tick.
        self.state = Self.fallbackState(cwd: cwd, themeID: themeID)
        self.openFilePaths = self.state.openFiles
        self.submitsOnEnter = preference.submitsOnEnter

        Task { [weak self] in
            guard let self else { return }
            if let real = try? await self.workspace.openProject(cwd, selectedThemeID: themeID) {
                self.state = real
                self.openFilePaths = real.openFiles
            }
        }
    }

    /// Hand off the broker connection once `AgentLauncher` finishes its
    /// startup handshake. Until this fires, terminal panes render a
    /// "connecting" placeholder.
    ///
    /// Also called by the launcher's watchdog after a respawn — in that
    /// case the previous `agentClient` is already closed and views need
    /// to rebuild against the new one. We bump `brokerEpoch` so views
    /// that key off it (`PaneGridView`, terminal tab content) tear down
    /// their cached NSViews and ask SwiftUI for a fresh build.
    func attachAgentClient(_ client: AgentClient) {
        self.agentClient = client
        self.brokerEpoch &+= 1
    }

    /// Open `url` in the focused workspace as an editor tab.
    ///
    /// If the focused workspace already has an editor tab pointed at
    /// `url`, focus that tab. Otherwise append a fresh editor tab and
    /// focus it. The sidebar is unchanged — that's the whole point of
    /// the bento model: the editor lives as a peer of the terminal in
    /// the inner tab strip, sharing one sidebar.
    ///
    /// Legacy non-workspace pane kinds (terminal / editor leaves from
    /// pre-workspace snapshots) fall back to the old auto-split behavior
    /// so old graphs keep working.
    func openFile(_ url: URL) {
        var graph = state.paneGraph
        let focusedID = graph.focusedPaneID
        let focused = graph.pane(focusedID)

        if let workspace = focused?.workspace {
            var updated = workspace
            if let existing = updated.tabs.first(where: { $0.editorPath == url.path }) {
                // Already open — just focus the existing tab.
                updated.focusedTabID = existing.id
            } else {
                let newTab = WorkspaceInnerTab(
                    id: TabID(),
                    displayName: url.lastPathComponent,
                    kind: .editor(path: url.path),
                    cwd: updated.initialCwd
                )
                updated.tabs.append(newTab)
                updated.focusedTabID = newTab.id
            }
            var pane = focused!
            pane.kind = .workspace(updated)
            graph = graph.replacingPane(pane)
        } else {
            // Legacy fallback (terminal/editor leaves): preserve previous
            // behavior of splitting in an editor pane.
            let leaves = graph.leaves()
            let editorPaneID: PaneID

            if let focusedEditor = leaves.first(where: { $0.id == focusedID && $0.editor != nil }) {
                editorPaneID = focusedEditor.id
            } else if let firstEditor = leaves.first(where: { $0.editor != nil }) {
                editorPaneID = firstEditor.id
                graph = graph.focus(firstEditor.id)
            } else {
                let newEditor = PaneDescriptor(
                    id: PaneID(),
                    name: url.lastPathComponent,
                    kind: .editor(EditorPane(path: url.path)),
                    isFocused: true
                )
                graph = graph.split(focusedID, direction: .right, newPane: newEditor)
                editorPaneID = newEditor.id
            }
            fileMap.setFile(url, for: editorPaneID)
        }

        recordPaneGraph(graph)

        var paths = openFilePaths
        if !paths.contains(url.path) {
            paths.insert(url.path, at: 0)
            recordOpenFiles(paths)
        }
    }

    /// Update the in-memory open-file list and tell the controller so the
    /// next snapshot reflects what the editor surface is showing.
    func recordOpenFiles(_ paths: [String]) {
        openFilePaths = paths
        Task { [workspace] in
            await workspace.setOpenFiles(paths)
        }
    }

    /// Update the `currentCwd` of a workspace pane in response to an OSC 7
    /// report from its shell. Re-publishes the pane graph so the workspace's
    /// sidebar re-scans the new path. No-op if the pane isn't a workspace
    /// (or the cwd didn't actually change).
    func updateWorkspaceCwd(paneID: PaneID, cwd: String) {
        guard var pane = state.paneGraph.pane(paneID),
              var workspace = pane.workspace,
              workspace.currentCwd != cwd else {
            return
        }
        workspace.currentCwd = cwd
        pane.kind = .workspace(workspace)
        let graph = state.paneGraph.replacingPane(pane)
        recordPaneGraph(graph)
    }

    /// Replace the tracked pane graph after a UI-driven mutation (split,
    /// focus change, pane close).
    func recordPaneGraph(_ graph: PaneGraph) {
        Task { [workspace] in
            await workspace.updatePaneGraph(graph)
        }
        self.state.paneGraph = graph
    }

    /// Run a unified search (files + scrollback) against the currently
    /// open project. Used by the search overlay.
    func search(_ query: String) async throws -> [UnifiedSearchResult] {
        try await workspace.search(query)
    }

    /// Add a brand-new top-level **workspace** (a new screen-level bento
    /// box) rooted at `~`. Wired to Cmd+N. Each workspace owns its own
    /// sidebar and its own collection of inner terminal tabs.
    func openNewWorkspace() {
        openNewWorkspace(at: NSHomeDirectory())
    }

    /// Rebind the focused workspace's root (sidebar source + cwd cache)
    /// to a new directory. Used by the editable toolbar path field.
    ///
    /// Note: this does NOT `cd` the running shell. The PTY keeps its
    /// own working directory; OSC 7 will continue to drive
    /// `currentCwd` from whatever the shell actually does. We only
    /// retarget the workspace-level fields that the sidebar / window
    /// title key off of.
    ///
    /// Path normalization:
    ///   - leading `~` expands to `$HOME`
    ///   - relative paths resolve against the previous initialCwd
    ///   - the resolved path must exist as a directory; otherwise the
    ///     call is a no-op and returns `false` so the toolbar can flag
    ///     the bad input.
    @discardableResult
    func setFocusedWorkspaceCwd(_ raw: String) -> Bool {
        guard var pane = state.paneGraph.pane(state.paneGraph.focusedPaneID),
              var workspace = pane.workspace else { return false }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let resolved: String
        if expanded.hasPrefix("/") {
            resolved = (expanded as NSString).standardizingPath
        } else {
            let base = URL(fileURLWithPath: workspace.initialCwd)
            resolved = base.appendingPathComponent(expanded)
                .standardizedFileURL.path
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        workspace.initialCwd = resolved
        workspace.currentCwd = resolved
        pane.kind = .workspace(workspace)
        recordPaneGraph(state.paneGraph.replacingPane(pane))
        return true
    }

    /// Add a new workspace rooted at `cwd` and focus it.
    func openNewWorkspace(at cwd: String) {
        let newPane = PaneDescriptor(
            id: PaneID(),
            name: "workspace",
            kind: .workspace(WorkspaceGroup(initialCwd: cwd)),
            isFocused: true
        )
        let graph = state.paneGraph.split(
            state.paneGraph.focusedPaneID,
            direction: .right,
            newPane: newPane
        )
        recordPaneGraph(graph)
    }

    /// Add a new **inner tab** to the currently focused workspace. Wired
    /// to Cmd+T. The new tab gets its own broker PaneID (own PTY), and
    /// focus moves to it. Sidebar stays put — that's the whole point of
    /// keeping the sidebar at the workspace level.
    func openNewInnerTab() {
        guard var pane = state.paneGraph.pane(state.paneGraph.focusedPaneID),
              let workspace = pane.workspace else {
            // No focused workspace — fall back to creating a new top-level
            // workspace so Cmd+T always does something useful.
            openNewWorkspace()
            return
        }
        let tab = WorkspaceInnerTab(
            displayName: "shell",
            kind: .terminal(paneID: PaneID(), command: nil),
            cwd: workspace.initialCwd
        )
        pane.kind = .workspace(workspace.appendingTab(tab))
        recordPaneGraph(state.paneGraph.replacingPane(pane))
    }

    /// Close an inner tab within the focused workspace. If it's the
    /// last inner tab, no-op — the workspace always has at least one
    /// terminal. If the closed tab was focused, focus moves to a
    /// neighbour.
    func closeInnerTab(_ id: TabID) {
        guard var pane = state.paneGraph.pane(state.paneGraph.focusedPaneID),
              let workspace = pane.workspace else {
            return
        }
        let updated = workspace.removingTab(id)
        guard updated != workspace else { return }
        pane.kind = .workspace(updated)
        recordPaneGraph(state.paneGraph.replacingPane(pane))
    }

    /// Rename a workspace tab (the top strip). Empty / whitespace input
    /// reverts to the cwd-derived label. The workspace is found by its
    /// pane ID, not by focus — so the editor in WorkspaceTabBar can
    /// rename a tab that isn't currently focused.
    func renameWorkspace(paneID: PaneID, to newName: String) {
        guard var pane = state.paneGraph.pane(paneID),
              let workspace = pane.workspace else { return }
        let updated = workspace.renamed(to: newName)
        guard updated != workspace else { return }
        pane.kind = .workspace(updated)
        recordPaneGraph(state.paneGraph.replacingPane(pane))
    }

    /// Rename an inner tab inside the focused workspace. Empty input
    /// resets the displayName to the kind-default.
    func renameInnerTab(_ id: TabID, to newName: String) {
        guard var pane = state.paneGraph.pane(state.paneGraph.focusedPaneID),
              let workspace = pane.workspace else { return }
        let updated = workspace.renamingTab(id, to: newName)
        guard updated != workspace else { return }
        pane.kind = .workspace(updated)
        recordPaneGraph(state.paneGraph.replacingPane(pane))
    }

    /// Move focus to an inner tab within the focused workspace.
    func focusInnerTab(_ id: TabID) {
        guard var pane = state.paneGraph.pane(state.paneGraph.focusedPaneID),
              let workspace = pane.workspace else {
            return
        }
        let updated = workspace.focusingTab(id)
        guard updated != workspace else { return }
        pane.kind = .workspace(updated)
        recordPaneGraph(state.paneGraph.replacingPane(pane))
    }

    /// Backward-compat shim — older menu wiring calls `openNewTab()`.
    /// Maps to the new inner-tab semantics so Cmd+T behaves correctly
    /// even before the menu rewires.
    func openNewTab() {
        openNewInnerTab()
    }

    /// Append a fresh, unsaved scratch editor tab to the focused
    /// workspace (or fall back to creating a new workspace if no
    /// workspace is focused). The tab has a nil path until the user
    /// saves it; the display name is auto-numbered (Untitled-1,
    /// Untitled-2, …) per workspace so multiple scratch tabs read
    /// distinctly in the tab strip.
    func openScratchEditor() {
        guard var pane = state.paneGraph.pane(state.paneGraph.focusedPaneID),
              let workspace = pane.workspace else {
            openNewWorkspace()
            return
        }
        // Auto-number against existing Untitled-N tabs so the user's
        // own renamed tabs don't get clobbered. Find the next free
        // index by scanning the workspace's editor-scratch displayNames.
        let existingNumbers: [Int] = workspace.tabs.compactMap { tab in
            guard tab.editorPath == nil, tab.isEditor else { return nil }
            let prefix = "Untitled-"
            guard tab.displayName.hasPrefix(prefix) else { return nil }
            return Int(tab.displayName.dropFirst(prefix.count))
        }
        let nextN = (existingNumbers.max() ?? 0) + 1
        let scratch = WorkspaceInnerTab(
            id: TabID(),
            displayName: "Untitled-\(nextN)",
            kind: .editor(path: nil),
            cwd: workspace.initialCwd
        )
        pane.kind = .workspace(workspace.appendingTab(scratch))
        recordPaneGraph(state.paneGraph.replacingPane(pane))
    }

    /// Send a Ctrl+L (FF, 0x0C) byte to the focused workspace's focused
    /// terminal tab — the binding every shell already interprets as
    /// "clear screen". Editor tabs are a no-op for this command.
    ///
    /// Wired to Cmd+K (see `BentoApp.installMenu`) and routed through
    /// the `.bentoClearFocusedTerminal` notification so menu, palette,
    /// and any future entry point can converge on one path.
    func clearFocusedTerminal() {
        guard
            let pane = state.paneGraph.pane(state.paneGraph.focusedPaneID),
            let workspace = pane.workspace,
            let paneID = workspace.focusedTab.terminalPaneID,
            let client = agentClient
        else { return }
        let payload = Data([0x0C])
        Task { try? await client.writeInput(paneID: paneID, data: payload) }
    }

    /// Toggle the focused workspace's sidebar between collapsed and
    /// expanded. Used by the sidebar header's toggle button.
    func toggleFocusedSidebar() {
        guard var pane = state.paneGraph.pane(state.paneGraph.focusedPaneID),
              var workspace = pane.workspace else {
            return
        }
        workspace.sidebarState = (workspace.sidebarState == .expanded) ? .collapsed : .expanded
        pane.kind = .workspace(workspace)
        recordPaneGraph(state.paneGraph.replacingPane(pane))
    }

    /// Close a workspace tab. If it's the last tab the call is a no-op
    /// (graph never goes empty). Otherwise focus moves to a neighbour.
    func closeTab(_ id: PaneID) {
        guard let next = state.paneGraph.close(id) else { return }
        recordPaneGraph(next)
    }

    /// Move keyboard focus to the given workspace tab.
    func focusTab(_ id: PaneID) {
        let next = state.paneGraph.focus(id)
        if next != state.paneGraph { recordPaneGraph(next) }
    }

    /// Close the focused inner tab if it's an editor. No-op when the
    /// focused pane isn't a workspace, when the focused inner tab is a
    /// terminal, or when the workspace has only one tab left (we never
    /// let a workspace go tabless).
    ///
    /// Wired to the `bentoCloseEditor` notification; the editor column
    /// header's `×` button used to fire this. Now that the editor is an
    /// inner tab, the per-tab `×` in `InnerTabStrip` is the primary
    /// close path — this remains as a fallback so older entry points
    /// (Cmd shortcuts, palette actions) still work.
    func closeFocusedEditor() {
        guard let pane = state.paneGraph.pane(state.paneGraph.focusedPaneID),
              let workspace = pane.workspace,
              workspace.focusedTab.editorPath != nil else {
            return
        }
        closeInnerTab(workspace.focusedTabID)
    }

    /// Trust the currently open project so its `.bento/session.yml` task
    /// panes will auto-start now and on every future open. Wired through
    /// the trust prompt overlay's "Trust this project" button.
    func trustCurrentProject() {
        Task { [weak self] in
            guard let self else { return }
            if let new = try? await self.workspace.trustCurrentProject() {
                self.state = new
            }
        }
    }

    /// Flip the Enter / Cmd+Enter binding in the command bar. Persists
    /// the new state via `ThemePreferenceStore` and republishes the
    /// mirrored `@Published` so live SwiftUI views see the change
    /// without restarting the session. Wired through the palette
    /// (`CommandAction.toggleSubmitOnEnter`).
    func toggleSubmitsOnEnter() {
        preference.toggleSubmitsOnEnter()
        submitsOnEnter = preference.submitsOnEnter
    }

    /// Cycle to the next built-in theme. Wired through `CommandAction.cycleTheme`.
    func cycleTheme() {
        let all = ThemeSpec.builtIns
        let current = preference.selectedTheme.id
        let nextIdx = (all.firstIndex(where: { $0.id == current }).map { $0 + 1 } ?? 0) % all.count
        try? preference.selectTheme(id: all[nextIdx].id)
        self.state.selectedThemeID = all[nextIdx].id
    }

    private static func fallbackState(cwd: URL, themeID: String) -> WorkspaceState {
        let tree = (try? ProjectFileTree.scan(root: cwd, maxDepth: 3))
            ?? ProjectFileTree(name: cwd.lastPathComponent, path: cwd.path, kind: .directory)
        let pane = PaneDescriptor(
            id: PaneID("workspace-root"),
            name: "workspace",
            kind: .workspace(WorkspaceGroup(initialCwd: cwd.path)),
            isFocused: true
        )
        return WorkspaceState(
            projectRoot: cwd.path,
            selectedThemeID: themeID,
            requiresTaskTrust: false,
            pendingTaskCommands: [],
            agentRequests: [],
            fileTree: tree,
            paneGraph: PaneGraph(root: pane),
            openFiles: [],
            restoredFromSnapshot: false
        )
    }
}

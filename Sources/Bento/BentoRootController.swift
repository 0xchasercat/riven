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
    func attachAgentClient(_ client: AgentClient) {
        self.agentClient = client
    }

    /// Open `url` in the focused workspace's editor pane. If the focused
    /// pane is a workspace, set its `openEditorPath` (which causes the
    /// `WorkspaceGroupView` to reveal its editor subpane); legacy
    /// terminal/editor leaves fall back to the old auto-split behavior.
    func openFile(_ url: URL) {
        var graph = state.paneGraph
        let focusedID = graph.focusedPaneID
        let focused = graph.pane(focusedID)

        if let workspace = focused?.workspace {
            // Update the workspace's editor binding in place — no new split.
            var updated = workspace
            updated.openEditorPath = url.path
            var pane = focused!
            pane.kind = .workspace(updated)
            // Rebuild the graph by replacing the pane in-place.
            graph = graph.replacingPane(pane)
            fileMap.setFile(url, for: focusedID)
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
              var workspace = pane.workspace else {
            // No focused workspace — fall back to creating a new top-level
            // workspace so Cmd+T always does something useful.
            openNewWorkspace()
            return
        }
        let tab = WorkspaceInnerTab(
            displayName: "shell",
            terminalPaneID: PaneID(),
            command: nil,
            cwd: workspace.initialCwd
        )
        workspace.tabs.append(tab)
        workspace.focusedTabID = tab.id
        pane.kind = .workspace(workspace)
        recordPaneGraph(state.paneGraph.replacingPane(pane))
    }

    /// Close an inner tab within the focused workspace. If it's the
    /// last inner tab, no-op — the workspace always has at least one
    /// terminal. If the closed tab was focused, focus moves to a
    /// neighbour.
    func closeInnerTab(_ id: TabID) {
        guard var pane = state.paneGraph.pane(state.paneGraph.focusedPaneID),
              var workspace = pane.workspace,
              workspace.tabs.count > 1,
              let idx = workspace.tabs.firstIndex(where: { $0.id == id }) else {
            return
        }
        workspace.tabs.remove(at: idx)
        if workspace.focusedTabID == id {
            workspace.focusedTabID = workspace.tabs[max(0, idx - 1)].id
        }
        pane.kind = .workspace(workspace)
        recordPaneGraph(state.paneGraph.replacingPane(pane))
    }

    /// Move focus to an inner tab within the focused workspace.
    func focusInnerTab(_ id: TabID) {
        guard var pane = state.paneGraph.pane(state.paneGraph.focusedPaneID),
              var workspace = pane.workspace,
              workspace.focusedTabID != id,
              workspace.tabs.contains(where: { $0.id == id }) else {
            return
        }
        workspace.focusedTabID = id
        pane.kind = .workspace(workspace)
        recordPaneGraph(state.paneGraph.replacingPane(pane))
    }

    /// Backward-compat shim — older menu wiring calls `openNewTab()`.
    /// Maps to the new inner-tab semantics so Cmd+T behaves correctly
    /// even before the menu rewires.
    func openNewTab() {
        openNewInnerTab()
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

    /// Close the focused workspace's open editor (if any). The editor
    /// column hides; the terminal stays put. No-op when the focused pane
    /// isn't a workspace or the workspace has no editor open.
    func closeFocusedEditor() {
        guard var pane = state.paneGraph.pane(state.paneGraph.focusedPaneID),
              var workspace = pane.workspace,
              workspace.openEditorPath != nil else {
            return
        }
        workspace.openEditorPath = nil
        pane.kind = .workspace(workspace)
        recordPaneGraph(state.paneGraph.replacingPane(pane))
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

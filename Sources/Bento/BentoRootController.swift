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

    /// Open `url` in an editor pane. Strategy: if the focused pane is
    /// already an editor, target it; else target the first editor leaf;
    /// else split the focused pane to add a new editor leaf and target
    /// that. Either way, the file shows up immediately.
    func openFile(_ url: URL) {
        var graph = state.paneGraph
        let leaves = graph.leaves()
        let editorPaneID: PaneID

        if let focusedEditor = leaves.first(where: { $0.id == graph.focusedPaneID && $0.editor != nil }) {
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
            graph = graph.split(graph.focusedPaneID, direction: .right, newPane: newEditor)
            editorPaneID = newEditor.id
        }

        fileMap.setFile(url, for: editorPaneID)
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
            name: "shell",
            kind: .terminal(TerminalPane(command: nil, cwd: cwd.path)),
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

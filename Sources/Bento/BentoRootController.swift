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

    @Published private(set) var state: WorkspaceState
    @Published var openFilePaths: [String] = []

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
        Task { @MainActor in
            self.state.paneGraph = graph
        }
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

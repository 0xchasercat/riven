import Foundation

public struct WorkspaceState: Equatable, Codable, Sendable {
    public var projectRoot: String
    public var selectedThemeID: String
    public var requiresTaskTrust: Bool
    public var pendingTaskCommands: [String]
    public var agentRequests: [AgentRequest]
    public var fileTree: ProjectFileTree
    public var paneGraph: PaneGraph
    public var openFiles: [String]
    public var restoredFromSnapshot: Bool

    public init(
        projectRoot: String,
        selectedThemeID: String,
        requiresTaskTrust: Bool,
        pendingTaskCommands: [String],
        agentRequests: [AgentRequest],
        fileTree: ProjectFileTree,
        paneGraph: PaneGraph,
        openFiles: [String] = [],
        restoredFromSnapshot: Bool = false
    ) {
        self.projectRoot = projectRoot
        self.selectedThemeID = selectedThemeID
        self.requiresTaskTrust = requiresTaskTrust
        self.pendingTaskCommands = pendingTaskCommands
        self.agentRequests = agentRequests
        self.fileTree = fileTree
        self.paneGraph = paneGraph
        self.openFiles = openFiles
        self.restoredFromSnapshot = restoredFromSnapshot
    }
}

public actor WorkspaceController {
    private let trustStore: ProjectTrustStore
    private let snapshotStore: WorkspaceSnapshotStore
    private let scrollbackStore: ScrollbackStore
    private var currentProjectRoot: URL?
    private var currentConfig: SessionConfig?
    private var currentState: WorkspaceState?
    private var currentPaneGraph: PaneGraph?
    private var currentOpenFiles: [String] = []

    public init(
        trustStore: ProjectTrustStore,
        snapshotStore: WorkspaceSnapshotStore,
        scrollbackStore: ScrollbackStore
    ) {
        self.trustStore = trustStore
        self.snapshotStore = snapshotStore
        self.scrollbackStore = scrollbackStore
    }

    @discardableResult
    public func openProject(_ projectRoot: URL, selectedThemeID: String = "bento") throws -> WorkspaceState {
        let root = projectRoot.standardizedFileURL
        currentProjectRoot = root
        currentConfig = try loadSessionConfig(projectRoot: root)

        let snapshot = (try? snapshotStore.load(projectRoot: root.path)) ?? nil
        let resolvedThemeID = snapshot?.selectedThemeID ?? selectedThemeID
        currentPaneGraph = snapshot?.paneGraph ?? defaultPaneGraph(for: root)
        currentOpenFiles = snapshot?.openFiles ?? []

        let state = try makeState(
            projectRoot: root,
            selectedThemeID: resolvedThemeID,
            restoredFromSnapshot: snapshot != nil
        )
        currentState = state
        return state
    }

    @discardableResult
    public func trustCurrentProject() throws -> WorkspaceState {
        guard let root = currentProjectRoot else {
            throw WorkspaceControllerError.noOpenProject
        }
        trustStore.trust(projectRoot: root)
        let state = try makeState(
            projectRoot: root,
            selectedThemeID: currentState?.selectedThemeID ?? "bento",
            restoredFromSnapshot: currentState?.restoredFromSnapshot ?? false
        )
        currentState = state
        return state
    }

    public func search(_ query: String) throws -> [UnifiedSearchResult] {
        guard let root = currentProjectRoot else {
            throw WorkspaceControllerError.noOpenProject
        }
        return try UnifiedSearchIndex(projectRoot: root, scrollbackStore: scrollbackStore).search(query)
    }

    /// Replaces the controller's tracked pane graph. The UI layer calls this whenever a pane
    /// is split, focused, or its underlying kind changes so that snapshots reflect the live layout.
    public func updatePaneGraph(_ graph: PaneGraph) {
        currentPaneGraph = graph
        if var state = currentState {
            state.paneGraph = graph
            currentState = state
        }
    }

    /// Records the list of files the editor surface currently has open.
    public func setOpenFiles(_ paths: [String]) {
        currentOpenFiles = paths
        if var state = currentState {
            state.openFiles = paths
            currentState = state
        }
    }

    /// Builds a snapshot of the controller's current workspace state. Crashes only if the
    /// controller has never been used; callers should ensure a project is open first.
    public func captureSnapshot() throws -> WorkspaceSnapshot {
        guard let root = currentProjectRoot else {
            throw WorkspaceControllerError.noOpenProject
        }
        let graph = currentPaneGraph ?? defaultPaneGraph(for: root)
        return WorkspaceSnapshot(
            projectRoot: root.path,
            selectedThemeID: currentState?.selectedThemeID ?? "bento",
            paneGraph: graph,
            openFiles: currentOpenFiles
        )
    }

    /// Persists the current workspace state to the snapshot store keyed by the open project.
    public func persistSnapshot() throws {
        let snapshot = try captureSnapshot()
        try snapshotStore.save(snapshot)
    }

    private func makeState(
        projectRoot: URL,
        selectedThemeID: String,
        restoredFromSnapshot: Bool
    ) throws -> WorkspaceState {
        let graph = currentPaneGraph ?? defaultPaneGraph(for: projectRoot)
        currentPaneGraph = graph

        guard let config = currentConfig else {
            return WorkspaceState(
                projectRoot: projectRoot.path,
                selectedThemeID: selectedThemeID,
                requiresTaskTrust: false,
                pendingTaskCommands: [],
                agentRequests: [],
                fileTree: try ProjectFileTree.scan(root: projectRoot),
                paneGraph: graph,
                openFiles: currentOpenFiles,
                restoredFromSnapshot: restoredFromSnapshot
            )
        }

        let planner = TaskPanePlanner(config: config, projectRoot: projectRoot, trustStore: trustStore)
        return WorkspaceState(
            projectRoot: projectRoot.path,
            selectedThemeID: selectedThemeID,
            requiresTaskTrust: planner.requiresTrustPrompt,
            pendingTaskCommands: config.panes.map { "\($0.name): \($0.command)" },
            agentRequests: planner.agentRequests(),
            fileTree: try ProjectFileTree.scan(root: projectRoot),
            paneGraph: graph,
            openFiles: currentOpenFiles,
            restoredFromSnapshot: restoredFromSnapshot
        )
    }

    private func defaultPaneGraph(for projectRoot: URL) -> PaneGraph {
        // New projects open into a single `.workspace` leaf so the user
        // gets the integrated [sidebar | terminal | editor-on-open] layout
        // by default. Legacy `.terminal` / `.editor` cases still load from
        // older snapshots; new graphs use `.workspace` exclusively.
        let pane = PaneDescriptor(
            id: PaneID("workspace-root"),
            name: "workspace",
            kind: .workspace(WorkspaceGroup(initialCwd: projectRoot.path)),
            isFocused: true
        )
        return PaneGraph(root: pane)
    }

    private func loadSessionConfig(projectRoot: URL) throws -> SessionConfig? {
        let url = projectRoot.appendingPathComponent(".bento/session.yml")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try SessionConfig.parse(String(contentsOf: url, encoding: .utf8))
    }
}

public enum WorkspaceControllerError: Error, Equatable {
    case noOpenProject
}

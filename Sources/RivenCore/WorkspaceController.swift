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
    /// Non-nil when `openProject` was asked for a root that was missing
    /// or unreadable and fell back to `~`. Carries a human-readable
    /// reason the UI can surface as a one-line banner ("Project
    /// ~/foo moved or deleted — opened ~ instead"). UI is expected to
    /// clear this via its own dismiss-× when the user acknowledges.
    public var projectFallbackReason: String?

    public init(
        projectRoot: String,
        selectedThemeID: String,
        requiresTaskTrust: Bool,
        pendingTaskCommands: [String],
        agentRequests: [AgentRequest],
        fileTree: ProjectFileTree,
        paneGraph: PaneGraph,
        openFiles: [String] = [],
        restoredFromSnapshot: Bool = false,
        projectFallbackReason: String? = nil
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
        self.projectFallbackReason = projectFallbackReason
    }

    // Custom Codable so older snapshots without `projectFallbackReason`
    // still decode cleanly — Swift's auto-synthesis would otherwise
    // throw `keyNotFound` on every restart against an existing snapshot
    // that predates this field.
    private enum CodingKeys: String, CodingKey {
        case projectRoot, selectedThemeID, requiresTaskTrust
        case pendingTaskCommands, agentRequests, fileTree
        case paneGraph, openFiles, restoredFromSnapshot
        case projectFallbackReason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.projectRoot = try c.decode(String.self, forKey: .projectRoot)
        self.selectedThemeID = try c.decode(String.self, forKey: .selectedThemeID)
        self.requiresTaskTrust = try c.decode(Bool.self, forKey: .requiresTaskTrust)
        self.pendingTaskCommands = try c.decode([String].self, forKey: .pendingTaskCommands)
        self.agentRequests = try c.decode([AgentRequest].self, forKey: .agentRequests)
        self.fileTree = try c.decode(ProjectFileTree.self, forKey: .fileTree)
        self.paneGraph = try c.decode(PaneGraph.self, forKey: .paneGraph)
        self.openFiles = try c.decodeIfPresent([String].self, forKey: .openFiles) ?? []
        self.restoredFromSnapshot = try c.decodeIfPresent(Bool.self, forKey: .restoredFromSnapshot) ?? false
        self.projectFallbackReason = try c.decodeIfPresent(String.self, forKey: .projectFallbackReason)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(projectRoot, forKey: .projectRoot)
        try c.encode(selectedThemeID, forKey: .selectedThemeID)
        try c.encode(requiresTaskTrust, forKey: .requiresTaskTrust)
        try c.encode(pendingTaskCommands, forKey: .pendingTaskCommands)
        try c.encode(agentRequests, forKey: .agentRequests)
        try c.encode(fileTree, forKey: .fileTree)
        try c.encode(paneGraph, forKey: .paneGraph)
        try c.encode(openFiles, forKey: .openFiles)
        try c.encode(restoredFromSnapshot, forKey: .restoredFromSnapshot)
        try c.encodeIfPresent(projectFallbackReason, forKey: .projectFallbackReason)
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
        // Resolve the requested root, falling back to `~` if it's gone
        // or unreadable. The fallback path uses the home directory as a
        // safe-and-always-present anchor so the user lands somewhere
        // sensible instead of a broken sidebar / failed scan. The UI
        // surfaces the reason via `WorkspaceState.projectFallbackReason`.
        let requested = projectRoot.standardizedFileURL
        var fallbackReason: String?
        let root: URL
        if Self.isReadableDirectory(requested) {
            root = requested
        } else {
            let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL
            fallbackReason = "Project \(Self.displayPath(requested)) moved or deleted — opened \(Self.displayPath(home)) instead"
            root = home
        }
        currentProjectRoot = root
        // session.yml lives under the project root; if we fell back to
        // ~ we won't have one. Catch any decode errors so a malformed
        // config doesn't take the workspace down either.
        currentConfig = (try? loadSessionConfig(projectRoot: root)) ?? nil

        let snapshot = (try? snapshotStore.load(projectRoot: root.path)) ?? nil
        let resolvedThemeID = snapshot?.selectedThemeID ?? selectedThemeID
        currentPaneGraph = snapshot?.paneGraph ?? defaultPaneGraph(for: root)
        currentOpenFiles = snapshot?.openFiles ?? []

        var state = try makeState(
            projectRoot: root,
            selectedThemeID: resolvedThemeID,
            restoredFromSnapshot: snapshot != nil
        )
        state.projectFallbackReason = fallbackReason
        currentState = state
        return state
    }

    /// True when `url` exists on disk and is a directory we can list.
    /// We don't probe for read permission via `isReadableFile` — the
    /// `ProjectFileTree.scan` call later will surface that more
    /// accurately. The check here is strictly "did the parent
    /// directory itself vanish or get replaced by a file".
    private static func isReadableDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return false
        }
        return isDir.boolValue
    }

    /// Tilde-collapse a URL for the user-visible fallback banner.
    /// "/Users/foo/Code/bar" → "~/Code/bar". Falls back to the absolute
    /// path when the URL doesn't live under $HOME.
    private static func displayPath(_ url: URL) -> String {
        let path = url.path
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~/" + String(path.dropFirst(home.count + 1))
        }
        return path
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

    public func search(
        _ query: String,
        scope: SearchScope = .thisProject
    ) throws -> [UnifiedSearchResult] {
        guard let root = currentProjectRoot else {
            throw WorkspaceControllerError.noOpenProject
        }
        return try UnifiedSearchIndex(projectRoot: root, scrollbackStore: scrollbackStore)
            .search(query, scope: scope)
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

        // ProjectFileTree.scan can throw on permission failures; catch
        // here and synthesize an empty stub so the workspace still
        // mounts. The sidebar's own .task path will retry/report once
        // the view is up.
        let scanned: ProjectFileTree = (try? ProjectFileTree.scan(root: projectRoot))
            ?? ProjectFileTree(
                name: projectRoot.lastPathComponent,
                path: projectRoot.path,
                kind: .directory
            )

        guard let config = currentConfig else {
            return WorkspaceState(
                projectRoot: projectRoot.path,
                selectedThemeID: selectedThemeID,
                requiresTaskTrust: false,
                pendingTaskCommands: [],
                agentRequests: [],
                fileTree: scanned,
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
            fileTree: scanned,
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
        let url = projectRoot.appendingPathComponent(".riven/session.yml")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try SessionConfig.parse(String(contentsOf: url, encoding: .utf8))
    }
}

public enum WorkspaceControllerError: Error, Equatable {
    case noOpenProject
}

public extension WorkspaceState {
    /// H-1: enumerate display filenames for every editor surface that
    /// appears in `dirtySurfaces`. Used by the quit-prompt to list
    /// "you have unsaved changes in N file(s)" with each file
    /// individually identified.
    ///
    /// Unsaved scratch buffers (`TabSurface.filename == nil`) collapse
    /// to "Untitled" so they're still represented in the alert body.
    /// Order matches a `panes.values` iteration, which isn't
    /// deterministic across runs — callers that need stable ordering
    /// should sort the result themselves. The quit alert doesn't care.
    func dirtyEditorFilenames(in dirtySurfaces: Set<SurfaceID>) -> [String] {
        guard !dirtySurfaces.isEmpty else { return [] }
        var out: [String] = []
        for pane in paneGraph.panes.values {
            guard let workspace = pane.workspace else { continue }
            for tab in workspace.tabs {
                for surface in tab.surfaces where dirtySurfaces.contains(surface.id) {
                    out.append(surface.filename ?? "Untitled")
                }
            }
        }
        return out
    }
}

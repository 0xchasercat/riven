import Foundation
import Testing
@testable import RivenCore

@Suite("Workspace resurrection")
struct WorkspaceResurrectionTests {
    @Test("opening a project with a saved snapshot restores the pane graph")
    func opensProjectWithRestoredPaneGraph() async throws {
        let project = try temporaryProject()
        try "readme".write(to: project.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let snapshotRoot = project.appendingPathComponent(".snapshots")
        let snapshotStore = WorkspaceSnapshotStore(root: snapshotRoot)

        let editorPane = PaneDescriptor(
            id: PaneID("editor-root"),
            name: "README",
            kind: .editor(EditorPane(
                path: project.appendingPathComponent("README.md").path,
                cursorLine: 4,
                cursorColumn: 2,
                inheritedCWD: project.standardizedFileURL.path
            )),
            isFocused: true
        )
        var graph = PaneGraph(root: editorPane)
        let splitID = try graph.split(editorPane.id, direction: .right)

        let snapshot = WorkspaceSnapshot(
            projectRoot: project.standardizedFileURL.path,
            selectedThemeID: "midnight",
            paneGraph: graph,
            openFiles: [project.appendingPathComponent("README.md").path]
        )
        try snapshotStore.save(snapshot)

        let controller = WorkspaceController(
            trustStore: ProjectTrustStore(),
            snapshotStore: snapshotStore,
            scrollbackStore: .temporary()
        )

        let state = try await controller.openProject(project)

        #expect(state.restoredFromSnapshot == true)
        #expect(state.selectedThemeID == "midnight")
        #expect(state.paneGraph == graph)
        #expect(state.paneGraph.panes.count == 2)
        #expect(state.paneGraph.focusedPaneID == splitID)
        #expect(state.openFiles == [project.appendingPathComponent("README.md").path])
    }

    @Test("persisting then reopening reproduces the focused pane and open files")
    func persistAndReopenRoundTrips() async throws {
        let project = try temporaryProject()
        try "hello".write(to: project.appendingPathComponent("Notes.md"), atomically: true, encoding: .utf8)
        let snapshotRoot = project.appendingPathComponent(".snapshots")
        let snapshotStore = WorkspaceSnapshotStore(root: snapshotRoot)
        let trustStore = ProjectTrustStore()

        let firstController = WorkspaceController(
            trustStore: trustStore,
            snapshotStore: snapshotStore,
            scrollbackStore: .temporary()
        )
        try await firstController.openProject(project)

        let leftPane = PaneDescriptor(
            id: PaneID("left"),
            name: "shell",
            kind: .terminal(TerminalPane(command: nil, cwd: project.standardizedFileURL.path)),
            isFocused: true
        )
        var graph = PaneGraph(root: leftPane)
        let rightID = try graph.split(leftPane.id, direction: .down)
        try graph.flip(rightID, to: .editor(EditorPane(
            path: project.appendingPathComponent("Notes.md").path,
            cursorLine: 1,
            cursorColumn: 1,
            inheritedCWD: project.standardizedFileURL.path
        )))

        await firstController.updatePaneGraph(graph)
        await firstController.setOpenFiles([project.appendingPathComponent("Notes.md").path])

        let captured = try await firstController.captureSnapshot()
        #expect(captured.paneGraph == graph)
        #expect(captured.openFiles == [project.appendingPathComponent("Notes.md").path])

        try await firstController.persistSnapshot()

        let secondController = WorkspaceController(
            trustStore: trustStore,
            snapshotStore: snapshotStore,
            scrollbackStore: .temporary()
        )
        let restored = try await secondController.openProject(project)

        #expect(restored.restoredFromSnapshot == true)
        #expect(restored.paneGraph == graph)
        #expect(restored.paneGraph.focusedPaneID == rightID)
        #expect(restored.openFiles == [project.appendingPathComponent("Notes.md").path])
        if let editor = restored.paneGraph.pane(rightID)?.editor {
            #expect(editor.path == project.appendingPathComponent("Notes.md").path)
            #expect(editor.inheritedCWD == project.standardizedFileURL.path)
        } else {
            Issue.record("expected restored right pane to be an editor")
        }
    }

    @Test("opening a project with no snapshot returns the default pane state")
    func defaultPaneStateWithoutSnapshot() async throws {
        let project = try temporaryProject()
        try "readme".write(to: project.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let snapshotRoot = project.appendingPathComponent(".snapshots")

        let controller = WorkspaceController(
            trustStore: ProjectTrustStore(),
            snapshotStore: WorkspaceSnapshotStore(root: snapshotRoot),
            scrollbackStore: .temporary()
        )

        let state = try await controller.openProject(project)

        #expect(state.restoredFromSnapshot == false)
        #expect(state.openFiles.isEmpty)
        #expect(state.paneGraph.panes.count == 1)
        let onlyPane = state.paneGraph.pane(state.paneGraph.focusedPaneID)
        #expect(onlyPane?.isFocused == true)
        // The default new-project pane is now a workspace group
        // (sidebar + terminal + on-demand editor), seeded with the
        // project's path as its initial cwd. Legacy snapshots that
        // contain `.terminal` leaves still load — see the snapshot
        // restoration test above for that path.
        if let workspace = onlyPane?.workspace {
            #expect(workspace.initialCwd == project.standardizedFileURL.path)
            #expect(workspace.currentCwd == project.standardizedFileURL.path)
            #expect(workspace.terminalCommand == nil)
            // A fresh workspace ships with exactly one inner tab — a
            // terminal anchored at the workspace's cwd. The editor is
            // now a peer tab kind, not a side column; opening a file
            // appends an `.editor` tab.
            #expect(workspace.tabs.count == 1)
            if case .terminal = workspace.tabs.first?.kind {
                // expected
            } else {
                Issue.record("expected default inner tab to be a terminal")
            }
        } else {
            Issue.record("expected default pane to be a workspace group")
        }
    }

    @Test("inner tabs (terminal + editor kinds) round-trip through the snapshot")
    func innerTabsSurviveSnapshotRoundtrip() async throws {
        let project = try temporaryProject()
        try "hello".write(to: project.appendingPathComponent("Hello.md"), atomically: true, encoding: .utf8)
        let snapshotRoot = project.appendingPathComponent(".snapshots")
        let store = WorkspaceSnapshotStore(root: snapshotRoot)

        // Build a workspace with three inner tabs: two terminals and an
        // editor. Each terminal carries its own broker `PaneID` (which
        // we need to survive so the broker can reattach across UI
        // launches).
        let leftPaneID = PaneID()
        let rightPaneID = PaneID()
        let leftTab = WorkspaceInnerTab(
            id: TabID("tab-left"),
            displayName: "shell",
            kind: .terminal(paneID: leftPaneID, command: nil),
            cwd: project.standardizedFileURL.path
        )
        let editorTab = WorkspaceInnerTab(
            id: TabID("tab-editor"),
            displayName: "Hello.md",
            kind: .editor(path: project.appendingPathComponent("Hello.md").path),
            cwd: project.standardizedFileURL.path
        )
        let rightTab = WorkspaceInnerTab(
            id: TabID("tab-right"),
            displayName: "build",
            kind: .terminal(paneID: rightPaneID, command: "swift build"),
            cwd: project.standardizedFileURL.path
        )
        let workspace = WorkspaceGroup(
            initialCwd: project.standardizedFileURL.path,
            tabs: [leftTab, editorTab, rightTab],
            focusedTabID: editorTab.id
        )
        let workspacePane = PaneDescriptor(
            id: PaneID("workspace-root"),
            name: "workspace",
            kind: .workspace(workspace),
            isFocused: true
        )
        let graph = PaneGraph(root: workspacePane)

        let snapshot = WorkspaceSnapshot(
            projectRoot: project.standardizedFileURL.path,
            selectedThemeID: "riven",
            paneGraph: graph,
            openFiles: []
        )
        try store.save(snapshot)

        let restored = try store.load(projectRoot: project.standardizedFileURL.path)
        guard let restoredWorkspace = restored?.paneGraph.pane(PaneID("workspace-root"))?.workspace else {
            Issue.record("expected restored snapshot to contain the workspace pane")
            return
        }

        #expect(restoredWorkspace.tabs.count == 3)
        #expect(restoredWorkspace.focusedTabID == editorTab.id)
        // Same order, same ids, same kinds (with payloads).
        #expect(restoredWorkspace.tabs[0].id == leftTab.id)
        #expect(restoredWorkspace.tabs[1].id == editorTab.id)
        #expect(restoredWorkspace.tabs[2].id == rightTab.id)
        // Terminal tab carries its broker `PaneID` through — without this
        // the broker can't reattach to the same PTY across UI launches.
        #expect(restoredWorkspace.tabs[0].terminalPaneID == leftPaneID)
        #expect(restoredWorkspace.tabs[2].terminalPaneID == rightPaneID)
        #expect(restoredWorkspace.tabs[2].command == "swift build")
        // Editor tab restores its path so the same file lands open.
        #expect(restoredWorkspace.tabs[1].editorPath == project.appendingPathComponent("Hello.md").path)
    }

    @Test("a tab with side-by-side splits round-trips through the snapshot store")
    func splitTabRoundtripsThroughStore() throws {
        let project = try temporaryProject()
        let snapshotRoot = project.appendingPathComponent(".snapshots")
        let store = WorkspaceSnapshotStore(root: snapshotRoot)

        // Build a workspace with one tab that has two side-by-side
        // terminal surfaces. The split is explicitly authored here
        // (rather than via the splittingFocusedSurface mutator) so
        // both surface IDs are stable and the assertions can match
        // exactly.
        let leftSurface = TabSurface(
            id: SurfaceID("surface-left"),
            kind: .terminal(paneID: PaneID("pane-left"), command: nil)
        )
        let rightSurface = TabSurface(
            id: SurfaceID("surface-right"),
            kind: .terminal(paneID: PaneID("pane-right"), command: "swift test")
        )
        let tab = WorkspaceInnerTab(
            id: TabID("split-tab"),
            displayName: "split",
            cwd: project.standardizedFileURL.path,
            surfaces: [leftSurface, rightSurface],
            layout: .split(.right, .leaf(leftSurface.id), .leaf(rightSurface.id)),
            focusedSurfaceID: rightSurface.id
        )
        let workspace = WorkspaceGroup(
            initialCwd: project.standardizedFileURL.path,
            tabs: [tab],
            focusedTabID: tab.id
        )
        let pane = PaneDescriptor(
            id: PaneID("workspace-root"),
            name: "workspace",
            kind: .workspace(workspace),
            isFocused: true
        )
        let snapshot = WorkspaceSnapshot(
            projectRoot: project.standardizedFileURL.path,
            selectedThemeID: "riven",
            paneGraph: PaneGraph(root: pane),
            openFiles: []
        )
        try store.save(snapshot)

        let restored = try store.load(projectRoot: project.standardizedFileURL.path)
        guard let restoredWorkspace = restored?.paneGraph.pane(PaneID("workspace-root"))?.workspace else {
            Issue.record("expected restored snapshot to contain the workspace pane")
            return
        }
        guard let restoredTab = restoredWorkspace.tabs.first(where: { $0.id == TabID("split-tab") }) else {
            Issue.record("expected restored workspace to contain the split tab")
            return
        }
        #expect(restoredTab.surfaces.count == 2)
        #expect(restoredTab.isSplit == true)
        #expect(restoredTab.focusedSurfaceID == SurfaceID("surface-right"))
        // Layout preserved exactly.
        switch restoredTab.layout {
        case let .split(direction, .leaf(lhs), .leaf(rhs)):
            #expect(direction == .right)
            #expect(lhs == SurfaceID("surface-left"))
            #expect(rhs == SurfaceID("surface-right"))
        default:
            Issue.record("expected .split(.right, .leaf, .leaf) layout after roundtrip, got \(restoredTab.layout)")
        }
        // Broker PaneIDs survive — critical for reattach.
        let leftPaneIDAfter = restoredTab.surfaces
            .first(where: { $0.id == SurfaceID("surface-left") })
            .flatMap { surface -> PaneID? in
                if case let .terminal(paneID, _) = surface.kind { return paneID }
                return nil
            }
        let rightPaneAfter = restoredTab.surfaces
            .first(where: { $0.id == SurfaceID("surface-right") })?.kind
        #expect(leftPaneIDAfter == PaneID("pane-left"))
        if case let .terminal(paneID, command) = rightPaneAfter {
            #expect(paneID == PaneID("pane-right"))
            #expect(command == "swift test")
        } else {
            Issue.record("right surface lost its terminal kind on roundtrip")
        }
    }

    @Test("scratch editor tab (nil path) round-trips through the snapshot")
    func scratchEditorTabRoundtrips() throws {
        let project = try temporaryProject()
        let snapshotRoot = project.appendingPathComponent(".snapshots")
        let store = WorkspaceSnapshotStore(root: snapshotRoot)

        let shell = WorkspaceInnerTab(
            id: TabID("shell"),
            displayName: "shell",
            kind: .terminal(paneID: PaneID("pane-shell"), command: nil),
            cwd: project.standardizedFileURL.path
        )
        let scratch = WorkspaceInnerTab(
            id: TabID("scratch-1"),
            displayName: "Untitled-1",
            kind: .editor(path: nil),
            cwd: project.standardizedFileURL.path
        )
        let workspace = WorkspaceGroup(
            initialCwd: project.standardizedFileURL.path,
            tabs: [shell, scratch],
            focusedTabID: scratch.id
        )
        let pane = PaneDescriptor(
            id: PaneID("workspace-root"),
            name: "workspace",
            kind: .workspace(workspace),
            isFocused: true
        )
        let snapshot = WorkspaceSnapshot(
            projectRoot: project.standardizedFileURL.path,
            selectedThemeID: "riven",
            paneGraph: PaneGraph(root: pane),
            openFiles: []
        )
        try store.save(snapshot)

        let restored = try store.load(projectRoot: project.standardizedFileURL.path)
        guard let restoredWorkspace = restored?.paneGraph.pane(PaneID("workspace-root"))?.workspace else {
            Issue.record("expected restored snapshot to contain the workspace pane")
            return
        }

        #expect(restoredWorkspace.tabs.count == 2)
        #expect(restoredWorkspace.focusedTabID == scratch.id)
        let restoredScratch = restoredWorkspace.tabs[1]
        #expect(restoredScratch.id == TabID("scratch-1"))
        #expect(restoredScratch.isEditor == true)
        // The defining property of a scratch tab: editorPath is nil
        // even though the tab IS an editor.
        #expect(restoredScratch.editorPath == nil)
        #expect(restoredScratch.displayName == "Untitled-1")
    }

    @Test("legacy snapshot with openEditorPath promotes the file to an editor tab")
    func legacyOpenEditorPathMigratesToInnerTab() throws {
        // Stand in for a snapshot written before the editor became an
        // inner tab kind: a workspace with a single terminal tab and the
        // old `openEditorPath` field carrying a file. After decode the
        // workspace should have two tabs — the original terminal plus a
        // freshly-synthesized `.editor` tab pointed at the file.
        let json = #"""
        {
          "initialCwd": "/tmp/legacy",
          "currentCwd": "/tmp/legacy",
          "sidebarWidth": 220,
          "editorWidth": 480,
          "focusedSubpane": "terminal",
          "sidebarState": "collapsed",
          "openEditorPath": "/tmp/legacy/Notes.md",
          "tabs": [
            {
              "id": { "rawValue": "tab-shell" },
              "displayName": "shell",
              "cwd": "/tmp/legacy",
              "terminalPaneID": { "rawValue": "pane-shell" }
            }
          ],
          "focusedTabID": { "rawValue": "tab-shell" }
        }
        """#

        let decoded = try JSONDecoder().decode(WorkspaceGroup.self, from: Data(json.utf8))
        #expect(decoded.tabs.count == 2)
        // Original terminal tab preserved with its flat paneID promoted
        // into the new `.terminal` kind.
        #expect(decoded.tabs[0].id == TabID("tab-shell"))
        #expect(decoded.tabs[0].terminalPaneID == PaneID("pane-shell"))
        // Legacy editor file becomes the second tab.
        #expect(decoded.tabs[1].editorPath == "/tmp/legacy/Notes.md")
        // Focus stays on the original tab; legacy doesn't tell us the
        // user was actively in the editor column.
        #expect(decoded.focusedTabID == TabID("tab-shell"))
    }

    @Test("captureSnapshot throws when no project is open")
    func captureSnapshotRequiresOpenProject() async throws {
        let controller = WorkspaceController(
            trustStore: ProjectTrustStore(),
            snapshotStore: WorkspaceSnapshotStore(root: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)),
            scrollbackStore: .temporary()
        )

        await #expect(throws: WorkspaceControllerError.noOpenProject) {
            _ = try await controller.captureSnapshot()
        }
    }
}

private func temporaryProject() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

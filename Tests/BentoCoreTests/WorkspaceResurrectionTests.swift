import Foundation
import Testing
@testable import BentoCore

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
        if let terminal = onlyPane?.terminal {
            #expect(terminal.cwd == project.standardizedFileURL.path)
            #expect(terminal.command == nil)
        } else {
            Issue.record("expected default pane to be a terminal")
        }
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

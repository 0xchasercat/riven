import Foundation
import Testing
@testable import BentoCore

@Suite("Workspace controller")
struct WorkspaceControllerTests {
    @Test("opening a project loads task config and blocks auto-start until trusted")
    func opensProjectWithUntrustedTasks() async throws {
        let project = try temporaryProject()
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".bento"), withIntermediateDirectories: true)
        try """
        version: 1
        panes:
          - name: api
            cwd: backend
            cmd: cargo run
        """.write(to: project.appendingPathComponent(".bento/session.yml"), atomically: true, encoding: .utf8)
        try "readme".write(to: project.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let controller = WorkspaceController(
            trustStore: ProjectTrustStore(),
            snapshotStore: WorkspaceSnapshotStore(root: project.appendingPathComponent(".snapshots")),
            scrollbackStore: .temporary()
        )

        let state = try await controller.openProject(project)

        #expect(state.projectRoot == project.standardizedFileURL.path)
        #expect(state.requiresTaskTrust == true)
        #expect(state.pendingTaskCommands == ["api: cargo run"])
        #expect(state.agentRequests.isEmpty)
        #expect(state.fileTree.children.map(\.name) == ["README.md"])
    }

    @Test("trusting a project emits task pane requests")
    func trustEmitsTaskRequests() async throws {
        let project = try temporaryProject()
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".bento"), withIntermediateDirectories: true)
        try """
        version: 1
        panes:
          - name: api
            cwd: backend
            cmd: cargo run
        """.write(to: project.appendingPathComponent(".bento/session.yml"), atomically: true, encoding: .utf8)
        let trust = ProjectTrustStore()
        let controller = WorkspaceController(
            trustStore: trust,
            snapshotStore: WorkspaceSnapshotStore(root: project.appendingPathComponent(".snapshots")),
            scrollbackStore: .temporary()
        )

        try await controller.openProject(project)
        let state = try await controller.trustCurrentProject()

        #expect(state.requiresTaskTrust == false)
        #expect(state.agentRequests == [
            .createTerminal(PaneID("task-api"), cwd: project.appendingPathComponent("backend").standardizedFileURL.path, command: "cargo run")
        ])
    }

    @Test("searching current project combines files and scrollback")
    func searchProject() async throws {
        let project = try temporaryProject()
        try "migration\n".write(to: project.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let scrollback = ScrollbackStore.temporary()
        try scrollback.append("terminal migration\n", to: PaneID("api"))
        let controller = WorkspaceController(
            trustStore: ProjectTrustStore(),
            snapshotStore: WorkspaceSnapshotStore(root: project.appendingPathComponent(".snapshots")),
            scrollbackStore: scrollback
        )
        try await controller.openProject(project)

        let results = try await controller.search("migration")

        #expect(results.count == 2)
    }
}

private func temporaryProject() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

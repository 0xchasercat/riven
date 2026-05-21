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

    @Test("openProject falls back to ~ when the requested root is missing")
    func openProjectFallsBackOnMissingRoot() async throws {
        // Build a URL that points at a path we haven't created — the
        // standard "user deleted the project directory between
        // launches" scenario.
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bento-missing-\(UUID().uuidString)")
        // Sanity: the path really doesn't exist.
        #expect(!FileManager.default.fileExists(atPath: missing.path))

        let controller = WorkspaceController(
            trustStore: ProjectTrustStore(),
            snapshotStore: WorkspaceSnapshotStore(
                root: URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("bento-snap-\(UUID().uuidString)")
            ),
            scrollbackStore: .temporary()
        )

        let state = try await controller.openProject(missing)

        // Landed on $HOME, not the missing dir.
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        #expect(state.projectRoot == home)
        // Banner copy is populated so the UI can surface it.
        #expect(state.projectFallbackReason != nil)
        if let reason = state.projectFallbackReason {
            #expect(reason.contains("moved or deleted"))
        }
    }

    @Test("openProject leaves projectFallbackReason nil when root exists")
    func openProjectNoFallbackWhenRootExists() async throws {
        let project = try temporaryProject()
        let controller = WorkspaceController(
            trustStore: ProjectTrustStore(),
            snapshotStore: WorkspaceSnapshotStore(root: project.appendingPathComponent(".snapshots")),
            scrollbackStore: .temporary()
        )

        let state = try await controller.openProject(project)

        #expect(state.projectRoot == project.standardizedFileURL.path)
        #expect(state.projectFallbackReason == nil)
    }

    @Test("openProject falls back when the path exists but is a file")
    func openProjectFallsBackWhenRootIsFile() async throws {
        // Create a file (not a directory) at the requested path —
        // ProjectFileTree.scan would otherwise throw on this.
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bento-file-\(UUID().uuidString).txt")
        try "not a directory".write(to: file, atomically: true, encoding: .utf8)

        let controller = WorkspaceController(
            trustStore: ProjectTrustStore(),
            snapshotStore: WorkspaceSnapshotStore(
                root: URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("bento-snap-\(UUID().uuidString)")
            ),
            scrollbackStore: .temporary()
        )

        let state = try await controller.openProject(file)
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        #expect(state.projectRoot == home)
        #expect(state.projectFallbackReason != nil)
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

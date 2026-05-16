import Foundation
import Testing
@testable import BentoCore

@Suite("Task pane planner")
struct TaskPanePlannerTests {
    @Test("requires trust before generating auto-start requests")
    func requiresTrust() throws {
        let project = URL(fileURLWithPath: "/repo")
        let config = SessionConfig(version: 1, panes: [
            TaskPaneConfig(name: "api", cwd: "backend", command: "cargo run")
        ])
        let planner = TaskPanePlanner(config: config, projectRoot: project, trustStore: ProjectTrustStore())

        #expect(planner.requiresTrustPrompt == true)
        #expect(planner.agentRequests().isEmpty)
    }

    @Test("creates terminal requests after trust using resolved cwd")
    func createsTerminalRequests() throws {
        let project = URL(fileURLWithPath: "/repo")
        let trust = ProjectTrustStore()
        trust.trust(projectRoot: project)
        let config = SessionConfig(version: 1, panes: [
            TaskPaneConfig(name: "api", cwd: "backend", command: "cargo run")
        ])
        let planner = TaskPanePlanner(config: config, projectRoot: project, trustStore: trust)

        let requests = planner.agentRequests()

        #expect(requests == [
            .createTerminal(PaneID("task-api"), cwd: "/repo/backend", command: "cargo run")
        ])
    }
}

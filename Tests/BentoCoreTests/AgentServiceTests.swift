import Testing
@testable import BentoCore

@Suite("Agent service")
struct AgentServiceTests {
    @Test("records output into scrollback when handling output events")
    func recordsOutput() async throws {
        let service = InProcessAgentService(scrollbackStore: .temporary())
        let pane = PaneID("api")

        try await service.handle(.createTerminal(pane, cwd: "/repo", command: nil))
        try await service.recordOutput("hello\n", from: pane)

        #expect(try await service.searchScrollback("hello") == [
            ScrollbackMatch(paneID: pane, lineNumber: 1, line: "hello")
        ])
    }

    @Test("runs command-backed terminal requests through PTY and persists output")
    func runsCommandTerminal() async throws {
        let service = InProcessAgentService(scrollbackStore: .temporary())
        let pane = PaneID("api")

        try await service.handle(.createTerminal(pane, cwd: "/tmp", command: "printf agent-pty"))

        #expect(try await service.searchScrollback("agent-pty") == [
            ScrollbackMatch(paneID: pane, lineNumber: 1, line: "agent-pty")
        ])
    }
}

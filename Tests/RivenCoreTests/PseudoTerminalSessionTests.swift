import Foundation
import Testing
@testable import RivenCore

@Suite("Pseudo terminal session")
struct PseudoTerminalSessionTests {
    @Test("runs a command through a real PTY and captures output")
    func runCommand() async throws {
        let session = PseudoTerminalSession(
            executable: "/bin/zsh",
            arguments: ["-lc", "printf riven-pty"],
            cwd: "/tmp"
        )

        let output = try await session.runUntilExit(timeout: .seconds(2))

        #expect(output.contains("riven-pty"))
    }
}

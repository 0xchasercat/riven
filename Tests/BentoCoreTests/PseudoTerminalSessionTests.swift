import Foundation
import Testing
@testable import BentoCore

@Suite("Pseudo terminal session")
struct PseudoTerminalSessionTests {
    @Test("runs a command through a real PTY and captures output")
    func runCommand() async throws {
        let session = PseudoTerminalSession(
            executable: "/bin/zsh",
            arguments: ["-lc", "printf bento-pty"],
            cwd: "/tmp"
        )

        let output = try await session.runUntilExit(timeout: .seconds(2))

        #expect(output.contains("bento-pty"))
    }
}

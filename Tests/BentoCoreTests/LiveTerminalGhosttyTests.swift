import Foundation
import Testing
@testable import BentoCore

/// Integration tests for the PTY + Ghostty pipeline that backs
/// `GhosttyTerminalView`. These exercise:
///   1. The live PTY streaming API (`LivePseudoTerminal.start/output/write`).
///   2. `GhosttyBridge.feed(_:to:)` (wraps `ghostty_terminal_vt_write`).
///   3. `GhosttyBridge.readGridText(_:)` (wraps `ghostty_terminal_grid_ref`,
///      `ghostty_grid_ref_cell`, `ghostty_cell_get`).
@Suite("Live terminal + Ghostty pipeline")
struct LiveTerminalGhosttyTests {

    /// End-to-end: spawn a real shell, run `printf hello-bento`, capture
    /// the bytes off the PTY master, feed them through Ghostty's VT parser,
    /// then read the grid back via the C grid-ref API and assert the
    /// string is present.
    @Test("PTY output flows through Ghostty and appears in the grid")
    func ptyToGhosttyToGrid() async throws {
        let pty = LivePseudoTerminal(
            spec: .init(
                executable: "/bin/sh",
                arguments: ["-c", "printf hello-bento\n; sleep 0.05"],
                cwd: "/tmp",
                environment: [:],
                columns: 80,
                rows: 24
            )
        )
        try pty.start()

        let bridge = GhosttyBridge()
        let session = try bridge.createSession(
            id: PaneID("live-pty-ghostty"),
            cwd: "/tmp",
            command: nil,
            cols: 80,
            rows: 24
        )
        defer { try? bridge.close(session) }

        // Collect output for up to ~1.5s, feeding everything we see into
        // Ghostty. We bail early once we've observed "hello-bento" in the
        // grid so the test stays fast.
        let timeoutNs: UInt64 = 1_500_000_000
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNs
        var found = false
        for await chunk in pty.output {
            try bridge.feed(chunk, to: session)
            let grid = try bridge.readGridText(session)
            if grid.contains(where: { $0.contains("hello-bento") }) {
                found = true
                break
            }
            if DispatchTime.now().uptimeNanoseconds > deadline { break }
        }
        pty.terminate()

        #expect(found, "expected 'hello-bento' in the Ghostty grid")
    }

    /// Unit test: skip the PTY entirely and just verify that
    /// `feed(_:to:)` + `readGridText(_:)` round-trip a literal byte string.
    /// This isolates the C-binding correctness from the PTY plumbing.
    @Test("feeding literal bytes lands them in the Ghostty grid")
    func literalFeedShowsInGrid() throws {
        let bridge = GhosttyBridge()
        let session = try bridge.createSession(
            id: PaneID("literal-feed"),
            cwd: "/tmp",
            command: nil,
            cols: 80,
            rows: 24
        )
        defer { try? bridge.close(session) }

        let payload = "hello-bento"
        try bridge.feed(Data(payload.utf8), to: session)

        let grid = try bridge.readGridText(session)
        #expect(grid.contains(where: { $0.contains(payload) }))
    }
}

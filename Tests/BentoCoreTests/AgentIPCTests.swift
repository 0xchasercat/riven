import Foundation
import Testing
@testable import BentoCore

@Suite("Agent IPC broker", .serialized)
struct AgentIPCTests {
    /// End-to-end: spawn the BentoAgent binary as a subprocess, connect via
    /// the client, run a short command in a PTY, and assert its output makes
    /// it through the subscription stream.
    @Test("creates a pane and streams its output to subscribers")
    func endToEndOutput() async throws {
        let harness = try await AgentHarness.start()
        defer { harness.stop() }

        let client = AgentClient(socketURL: harness.socketURL)
        try await client.connect()
        defer { Task { await client.close() } }

        try await client.ping()

        let pane = PaneID("test-broker-output")
        _ = try await client.createPane(
            paneID: pane,
            command: "/bin/zsh",
            args: ["-c", "printf hello-broker"],
            cwd: "/tmp"
        )

        let stream = try await client.subscribe(paneID: pane)
        let collected = try await collect(stream: stream, until: "hello-broker", timeout: .seconds(5))
        #expect(collected.contains("hello-broker"))
    }

    /// Reconnect: create a pane, drop the client, reconnect with a brand new
    /// client, subscribe with the same PaneID, and assert the ring buffer
    /// replays the original output to the new subscriber.
    @Test("replays buffered output to a reconnected subscriber")
    func reconnectReplaysBuffer() async throws {
        let harness = try await AgentHarness.start()
        defer { harness.stop() }

        let pane = PaneID("test-broker-reconnect")

        // First client: create the pane and wait for output to land in the
        // server-side ring buffer.
        do {
            let first = AgentClient(socketURL: harness.socketURL)
            try await first.connect()
            _ = try await first.createPane(
                paneID: pane,
                command: "/bin/zsh",
                args: ["-c", "printf reconnect-payload; sleep 30"],
                cwd: "/tmp"
            )
            let stream = try await first.subscribe(paneID: pane)
            _ = try await collect(stream: stream, until: "reconnect-payload", timeout: .seconds(5))
            await first.close()
        }

        // Give the server a brief moment to finish processing the close.
        try await Task.sleep(for: .milliseconds(100))

        // Second client: subscribe again — the replay must include the
        // buffered output even though no live writes happen in this window.
        let second = AgentClient(socketURL: harness.socketURL)
        try await second.connect()
        defer { Task { await second.close() } }

        let panes = try await second.listPanes()
        #expect(panes.contains { $0.paneID == pane })

        let stream = try await second.subscribe(paneID: pane)
        let collected = try await collect(stream: stream, until: "reconnect-payload", timeout: .seconds(5))
        #expect(collected.contains("reconnect-payload"))

        // Clean up the long-running child.
        try? await second.killPane(paneID: pane)
    }

    // MARK: - Helpers

    private func collect(
        stream: AsyncThrowingStream<IPCEvent, Error>,
        until needle: String,
        timeout: Duration
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                var buffer = Data()
                for try await event in stream {
                    if case let .output(_, data) = event {
                        buffer.append(data)
                        if let s = String(data: buffer, encoding: .utf8), s.contains(needle) {
                            return s
                        }
                    }
                }
                return String(data: buffer, encoding: .utf8)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            let result = try await group.next() ?? nil
            group.cancelAll()
            guard let s = result else {
                throw CollectError.timedOut
            }
            return s
        }
    }

    enum CollectError: Error { case timedOut }
}

// MARK: - Test harness

/// Builds and launches the BentoAgent product as a subprocess on a unique
/// socket path, waits for it to announce readiness on stdout, and tears it
/// down on `stop()`.
final class AgentHarness {
    let socketURL: URL
    private let process: Process

    private init(socketURL: URL, process: Process) {
        self.socketURL = socketURL
        self.process = process
    }

    static func start() async throws -> AgentHarness {
        let binary = try locateAgentBinary()
        let socketURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bento-agent-\(UUID().uuidString).sock")

        let process = Process()
        process.executableURL = binary
        process.arguments = ["--socket", socketURL.path]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Wait for either the "listening on" log line or for the socket file
        // to appear, whichever comes first. Up to ~5s.
        let deadline = Date().addingTimeInterval(5)
        var stdoutBuffer = Data()
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: socketURL.path) {
                let chunk = stdoutPipe.fileHandleForReading.availableData
                if !chunk.isEmpty { stdoutBuffer.append(chunk) }
                if let s = String(data: stdoutBuffer, encoding: .utf8), s.contains("listening on") {
                    break
                }
                // Socket present is also a sufficient ready signal.
                break
            }
            let chunk = stdoutPipe.fileHandleForReading.availableData
            if !chunk.isEmpty {
                stdoutBuffer.append(chunk)
                if let s = String(data: stdoutBuffer, encoding: .utf8), s.contains("listening on") {
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        if !FileManager.default.fileExists(atPath: socketURL.path) {
            process.terminate()
            let err = String(data: stderrPipe.fileHandleForReading.availableData, encoding: .utf8) ?? ""
            throw HarnessError.didNotStart(stderr: err)
        }
        return AgentHarness(socketURL: socketURL, process: process)
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: socketURL)
    }

    private static func locateAgentBinary() throws -> URL {
        // The test bundle binary lives next to the BentoAgent product binary
        // in the same `.build/<config>/<triple>` directory. Walk up from
        // `Bundle.main.bundleURL` (or `Bundle(for:)` for the test bundle) to
        // find it.
        let candidates = Bundle.allBundles.map { $0.bundleURL.deletingLastPathComponent() }
            + [Bundle.main.bundleURL.deletingLastPathComponent()]
        for dir in candidates {
            let candidate = dir.appendingPathComponent("BentoAgent")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        // Fallback: ask `swift build` for the bin path. This keeps us robust
        // if the binary hasn't been built yet (although the test driver will
        // normally build the whole package first).
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["swift", "build", "--show-bin-path"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try proc.run()
        proc.waitUntilExit()
        let binPath = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let candidate = URL(fileURLWithPath: binPath).appendingPathComponent("BentoAgent")
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        throw HarnessError.binaryNotFound
    }

    enum HarnessError: Error {
        case binaryNotFound
        case didNotStart(stderr: String)
    }
}

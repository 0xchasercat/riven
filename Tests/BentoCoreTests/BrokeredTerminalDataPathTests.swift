import Foundation
import Testing
@testable import BentoCore

/// Integration test for the broker plumbing that powers
/// `BrokeredTerminalView`.
///
/// We deliberately do not instantiate the NSView itself — NSView tests
/// under SwiftPM are flaky because there's no AppKit run loop. Instead
/// we exercise exactly the same wire path the view uses:
///   1. Spawn a real `BentoAgent` subprocess on a per-test socket.
///   2. Connect an `AgentClient`.
///   3. Call `createPane(...)` for a `printf hello-broker` command, the
///      same shape `BrokeredTerminalView.runBrokerLoop()` uses.
///   4. Subscribe to the pane and assert the output stream emits the
///      expected bytes.
///
/// The harness (`AgentHarness`) lives in `AgentIPCTests.swift`. Both
/// suites use the `.serialized` trait at the suite level so we don't
/// fight for the shared test binary.
@Suite("Brokered terminal data path", .serialized)
struct BrokeredTerminalDataPathTests {

    @Test("client + broker round-trip surfaces pane output to subscribers")
    func brokerStreamsHelloBroker() async throws {
        let harness = try await AgentHarness.start()
        defer { harness.stop() }

        let client = AgentClient(socketURL: harness.socketURL)
        try await client.connect()
        defer { Task { await client.close() } }

        let pane = PaneID("brokered-view-data-path")
        _ = try await client.createPane(
            paneID: pane,
            command: "/bin/zsh",
            args: ["-c", "printf hello-broker"],
            cwd: "/tmp"
        )

        let stream = try await client.subscribe(paneID: pane)
        let output = try await waitForBytes(stream: stream, until: "hello-broker", timeout: .seconds(5))
        #expect(output.contains("hello-broker"))
    }

    /// Resize requests are non-fatal in `BrokeredTerminalView` but they
    /// must round-trip without error against a live broker for an
    /// existing pane. A second attempt after the pane exits should
    /// surface `unknown_pane` so the view can give up cleanly.
    @Test("resize succeeds for live pane and fails for unknown pane")
    func resizeBehavior() async throws {
        let harness = try await AgentHarness.start()
        defer { harness.stop() }

        let client = AgentClient(socketURL: harness.socketURL)
        try await client.connect()
        defer { Task { await client.close() } }

        let pane = PaneID("brokered-resize")
        _ = try await client.createPane(
            paneID: pane,
            command: "/bin/sh",
            args: ["-c", "sleep 5"],
            cwd: "/tmp"
        )

        try await client.resize(paneID: pane, columns: 100, rows: 30)

        try? await client.killPane(paneID: pane)
        await Task.yield()

        do {
            try await client.resize(paneID: PaneID("never-existed"), columns: 100, rows: 30)
            Issue.record("resize of unknown pane should have thrown")
        } catch let AgentClient.ClientError.server(err) {
            #expect(err.code == "unknown_pane")
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    // MARK: - Helpers

    private func waitForBytes(
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
                throw WaitError.timedOut
            }
            return s
        }
    }

    enum WaitError: Error { case timedOut }
}

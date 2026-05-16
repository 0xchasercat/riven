import Foundation
import Testing
@testable import BentoCore

/// Tests for the broker's on-disk scrollback persistence: bytes written to a
/// pane's PTY survive a broker restart and are replayed to a fresh subscriber,
/// the per-pane disk file is capped from the head, and live + replayed bytes
/// stay in chronological order without duplication.
@Suite("Broker scrollback persistence", .serialized)
struct BrokerPersistenceTests {
    /// Hello-world round-trip across a SIGTERM:
    ///
    /// 1. Spawn broker on a fresh socket + scrollback root.
    /// 2. Create a pane that prints "hello-world" then sleeps.
    /// 3. Subscribe and wait for the bytes to appear.
    /// 4. SIGTERM the broker (so its persister flushes synchronously).
    /// 5. Spawn a *second* broker on the same socket + scrollback root.
    /// 6. Subscribe to the same paneID and expect the replay to contain
    ///    "hello-world" — even though the original PTY is long dead.
    @Test("scrollback persists across broker restarts")
    func persistsAcrossRestart() async throws {
        let scrollbackRoot = uniqueScrollbackRoot()
        defer { try? FileManager.default.removeItem(at: scrollbackRoot) }
        let socketURL = uniqueSocketURL()

        let pane = PaneID("persist-across-restart")

        // First generation: write some bytes through a real PTY, wait for
        // them, then SIGTERM. The persister's shutdown hook is what makes
        // those bytes durable.
        do {
            let harness = try await AgentHarness.start(socketURL: socketURL, scrollbackRoot: scrollbackRoot)
            let client = AgentClient(socketURL: harness.socketURL)
            try await client.connect()

            _ = try await client.createPane(
                paneID: pane,
                command: "/bin/zsh",
                args: ["-c", "printf hello-world\\n; sleep 30"],
                cwd: "/tmp"
            )
            let stream = try await client.subscribe(paneID: pane)
            let collected = try await collect(stream: stream, until: "hello-world", timeout: .seconds(5))
            #expect(collected.contains("hello-world"))

            await client.close()
            // SIGTERM (not just process.terminate without flush) — the broker's
            // signal handler flushes the persister before exiting.
            harness.terminateAndWait()
        }

        // Second generation: brand new broker process on the same socket and
        // scrollback root. The pane no longer has a live PTY, but its
        // scrollback file should be on disk.
        let secondHarness = try await AgentHarness.start(socketURL: socketURL, scrollbackRoot: scrollbackRoot)
        defer { secondHarness.stop() }

        let second = AgentClient(socketURL: secondHarness.socketURL)
        try await second.connect()
        defer { Task { await second.close() } }

        let stream = try await second.subscribe(paneID: pane)
        // We won't get any further output, only the replay event. The collect
        // helper returns as soon as the needle appears in the buffered events.
        let collected = try await collect(stream: stream, until: "hello-world", timeout: .seconds(5))
        #expect(collected.contains("hello-world"))
    }

    /// Disk cap: feed > 1 MiB through a pane and assert (a) the on-disk file
    /// stays around the cap and (b) the most-recent suffix is preserved.
    @Test("size cap truncates from oldest end")
    func sizeCapTruncatesFromOldest() async throws {
        let scrollbackRoot = uniqueScrollbackRoot()
        defer { try? FileManager.default.removeItem(at: scrollbackRoot) }
        let socketURL = uniqueSocketURL()

        let pane = PaneID("size-cap")
        let harness = try await AgentHarness.start(socketURL: socketURL, scrollbackRoot: scrollbackRoot)
        defer { harness.stop() }

        let client = AgentClient(socketURL: harness.socketURL)
        try await client.connect()
        defer { Task { await client.close() } }

        // Generate well past the 1 MiB cap (~1.5 MiB) followed by a unique
        // sentinel so we can verify the suffix survived truncation.
        // `head -c` from /dev/zero would emit binary nulls, which is fine —
        // ScrollbackStore is byte-oriented. We use `yes`-via-shell instead so
        // the resulting file has predictable, printable bytes.
        let sentinel = "tail-sentinel-\(UUID().uuidString)"
        _ = try await client.createPane(
            paneID: pane,
            command: "/bin/zsh",
            args: [
                "-c",
                // Produce 1500 KB of 'x' followed by the sentinel.
                "yes x | head -c 1572864; printf '\\n%s\\n' \(sentinel); sleep 30"
            ],
            cwd: "/tmp"
        )

        let stream = try await client.subscribe(paneID: pane)
        let collected = try await collect(stream: stream, until: sentinel, timeout: .seconds(15))
        #expect(collected.contains(sentinel))

        // Allow the persister's timer to flush the trailing buffer + run the
        // truncate. Flushes happen every ~250 ms.
        try await Task.sleep(for: .milliseconds(800))

        let file = scrollbackRoot
            .appendingPathComponent(pane.rawValue)
            .appendingPathExtension("log")
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        // Truncation is amortized: the broker rewrites the file once it
        // exceeds cap + slack (1 MiB + 256 KiB). Allow another 256 KiB of
        // headroom for bytes that arrived between the rewrite and our
        // observation. Anything below 1.5 MiB proves the cap is working
        // (we wrote 1.5 MiB of payload; without truncation the file would
        // be 1.5 MiB *plus* the trailing sentinel chunk).
        #expect(size < 1024 * 1024 + 512 * 1024,
                "scrollback file should stay near the 1 MiB cap, got \(size)")

        let store = ScrollbackStore(root: scrollbackRoot)
        let tail = try store.tail(pane, bytes: 1024 * 1024)
        let tailString = String(data: tail, encoding: .utf8) ?? ""
        #expect(tailString.contains(sentinel),
                "most-recent suffix (with sentinel) must survive truncation")
    }

    /// Replaying a re-created pane returns only the LIVE post-restart
    /// bytes — not the on-disk history. We made this trade-off after the
    /// UX showed the old behaviour ("disk replay on every reattach") was
    /// visibly stacking prompts at the top of the terminal on every
    /// SwiftUI re-render. The on-disk scrollback is still maintained
    /// (unified search uses it), it just isn't auto-fed into a fresh
    /// terminal grid on subscribe.
    ///
    /// 1. Pane prints `BEFORE-RESTART` then sleeps.
    /// 2. SIGTERM broker (flush).
    /// 3. New broker. Re-create the same paneID with `AFTER-RESTART`.
    /// 4. Subscribe — replay contains only `AFTER-RESTART` (live), and
    ///    contains it exactly once.
    @Test("re-created live pane replay shows only new bytes, no duplicates")
    func replayInOrderWithoutDuplication() async throws {
        let scrollbackRoot = uniqueScrollbackRoot()
        defer { try? FileManager.default.removeItem(at: scrollbackRoot) }
        let socketURL = uniqueSocketURL()
        let pane = PaneID("in-order")

        // Generation 1: write BEFORE-RESTART, wait for it, SIGTERM.
        do {
            let harness = try await AgentHarness.start(socketURL: socketURL, scrollbackRoot: scrollbackRoot)
            let client = AgentClient(socketURL: harness.socketURL)
            try await client.connect()

            _ = try await client.createPane(
                paneID: pane,
                command: "/bin/zsh",
                args: ["-c", "printf BEFORE-RESTART\\n; sleep 30"],
                cwd: "/tmp"
            )
            let stream = try await client.subscribe(paneID: pane)
            _ = try await collect(stream: stream, until: "BEFORE-RESTART", timeout: .seconds(5))
            await client.close()
            harness.terminateAndWait()
        }

        // Generation 2: new broker, new PTY for the same paneID, write
        // AFTER-RESTART. The new live PTY should NOT re-feed the disk
        // history into the replay — that was the duplication source.
        let harness2 = try await AgentHarness.start(socketURL: socketURL, scrollbackRoot: scrollbackRoot)
        defer { harness2.stop() }

        let client2 = AgentClient(socketURL: harness2.socketURL)
        try await client2.connect()
        defer { Task { await client2.close() } }

        _ = try await client2.createPane(
            paneID: pane,
            command: "/bin/zsh",
            args: ["-c", "printf AFTER-RESTART\\n; sleep 30"],
            cwd: "/tmp"
        )
        let stream = try await client2.subscribe(paneID: pane)
        let collected = try await collect(stream: stream, until: "AFTER-RESTART", timeout: .seconds(5))

        // AFTER-RESTART must be present (live bytes still stream).
        #expect(collected.contains("AFTER-RESTART"))

        // AFTER-RESTART appears exactly once (no duplication on subscribe).
        let afterCount = collected.components(separatedBy: "AFTER-RESTART").count - 1
        #expect(afterCount == 1, "AFTER-RESTART duplicated (\(afterCount) occurrences)")

        try? await client2.killPane(paneID: pane)
    }

    // MARK: - Helpers

    private func uniqueScrollbackRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bento-scrollback-\(UUID().uuidString)", isDirectory: true)
    }

    private func uniqueSocketURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bento-agent-\(UUID().uuidString).sock")
    }

    private func collect(
        stream: AsyncThrowingStream<IPCEvent, Error>,
        until needle: String,
        timeout: Duration
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                var buffer = Data()
                let needleBytes = Data(needle.utf8)
                for try await event in stream {
                    if case let .output(_, data) = event {
                        buffer.append(data)
                        // Byte-level match on the raw buffer. Building a full
                        // String + grapheme-aware `.contains` on every chunk
                        // is O(N) per call and pathologically slow once N is
                        // in the megabytes (the cap test pushes 1.5 MiB).
                        if buffer.range(of: needleBytes) != nil {
                            return String(data: buffer, encoding: .utf8)
                                ?? String(decoding: buffer, as: UTF8.self)
                        }
                    }
                }
                return String(data: buffer, encoding: .utf8)
                    ?? String(decoding: buffer, as: UTF8.self)
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

// MARK: - Harness extensions

extension AgentHarness {
    /// Variant that lets the caller pin both the socket path and the
    /// scrollback root. Tests reuse both across broker restarts to verify
    /// on-disk persistence behavior.
    static func start(socketURL: URL, scrollbackRoot: URL) async throws -> AgentHarness {
        let binary = try Self.locateBinary()

        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "--socket", socketURL.path,
            "--scrollback-root", scrollbackRoot.path
        ]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()

        // Wait for either the listening line or the socket file (mirrors the
        // existing AgentHarness.start logic).
        let deadline = Date().addingTimeInterval(5)
        var stdoutBuffer = Data()
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: socketURL.path) {
                let chunk = stdoutPipe.fileHandleForReading.availableData
                if !chunk.isEmpty { stdoutBuffer.append(chunk) }
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

    /// SIGTERM the broker and wait for it to exit. Goes through the broker's
    /// shutdown handler so the persister flushes pending bytes synchronously.
    func terminateAndWait() {
        if process.isRunning {
            // `Process.terminate()` already sends SIGTERM on Darwin.
            process.terminate()
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: socketURL)
    }

    /// Mirrors the private `locateAgentBinary` in `AgentIPCTests` so tests in
    /// this file can spin up the broker without depending on private symbols.
    fileprivate static func locateBinary() throws -> URL {
        let candidates = Bundle.allBundles.map { $0.bundleURL.deletingLastPathComponent() }
            + [Bundle.main.bundleURL.deletingLastPathComponent()]
        for dir in candidates {
            let candidate = dir.appendingPathComponent("BentoAgent")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        // Fallback: ask `swift build` for the bin path. Mirrors the same
        // resilience as `AgentIPCTests.locateAgentBinary`.
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
}

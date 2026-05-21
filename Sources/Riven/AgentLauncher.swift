import AppKit
import RivenCore
import Darwin
import Foundation
import Network

/// Spawns and supervises the `RivenAgent` broker subprocess so the UI can
/// drive its terminals through `AgentClient` instead of owning PTYs in
/// process.
///
/// Lifecycle:
///   1. `start()` discovers the agent binary, picks the per-user socket
///      path (``AgentIPC.defaultSocketURL``), and either:
///        - **Reuses** an already-running agent if the socket is present
///          and connectable. This handles "user already had a session
///          running" — the new UI just attaches.
///        - **Spawns** a fresh agent and waits up to a few seconds for
///          its socket to become connectable. The launcher remembers
///          that *we* spawned it.
///   2. ``client()`` returns a connected `AgentClient`. The connection is
///      created lazily on first call and cached.
///   3. ``shutdown()`` closes the client. If we spawned the agent
///      ourselves, we also send `SIGTERM` to it; if we reused an existing
///      one we leave it running so other Riven windows keep working.
///
/// The launcher is `@MainActor`-isolated so it can be hung off the
/// `NSApplicationDelegate` without ceremony. The actual IPC (`AgentClient`)
/// is its own actor and is safe to call from any context.
@MainActor
public final class AgentLauncher {

    /// Resolved socket path the launcher will listen on / connect to.
    public let socketURL: URL

    private var spawnedProcess: Process?
    private var cachedClient: AgentClient?
    private var connectTask: Task<AgentClient, Error>?
    private var didShutdown = false
    private var watchdogTask: Task<Void, Never>?
    /// Set when the orchestrator initiates a respawn (so the watchdog
    /// doesn't re-fire on the inside of its own teardown).
    private var isRespawning = false

    /// Fires after the watchdog respawns a dead broker and a fresh
    /// `AgentClient` is connected. Receivers should treat the previous
    /// client as dead and rebind their views to the new one. Called on
    /// the main actor; the previous client has already been `close()`'d.
    public var onClientReplaced: ((AgentClient) -> Void)?

    /// Build a launcher targeting `socketURL` (defaults to the per-user
    /// agent socket). The agent isn't spawned until ``start()`` is called.
    public init(socketURL: URL = AgentIPC.defaultSocketURL) {
        self.socketURL = socketURL
    }

    deinit {
        // We can't call @MainActor methods from deinit; the orchestrator
        // is expected to call ``shutdown()`` from
        // `applicationWillTerminate`. As a safety net, terminate any
        // child we still own without touching actor-isolated state.
        if let process = spawnedProcess, process.isRunning {
            process.terminate()
        }
    }

    // MARK: - Lifecycle

    /// Discover the agent binary, attach to an existing broker if one is
    /// already serving on the configured socket, otherwise spawn a fresh
    /// one. Safe to call multiple times — subsequent calls are no-ops.
    @discardableResult
    public func start() async throws -> URL {
        precondition(!didShutdown, "AgentLauncher.start() called after shutdown")
        return try await spawnIfNeeded()
    }

    /// Same flow as `start()`, but without the post-shutdown precondition
    /// so the watchdog can drive it during `respawn()`. Idempotent on
    /// already-running brokers.
    private func spawnIfNeeded() async throws -> URL {
        // Already attached to an existing broker (or we already spawned one).
        if spawnedProcess != nil { return socketURL }
        if isSocketConnectable(socketURL) { return socketURL }

        // Otherwise spawn a fresh agent on this socket.
        let binary = try Self.locateAgentBinary()
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Remove any stale leftover socket file. The agent itself does
        // this defensively too, but doing it here means a half-dead
        // socket file from a previous crash doesn't fool our liveness
        // probe above.
        if FileManager.default.fileExists(atPath: socketURL.path),
           !isSocketConnectable(socketURL) {
            try? FileManager.default.removeItem(at: socketURL)
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = ["--socket", socketURL.path]
        // Keep the agent's stdout/stderr attached to ours during dev so
        // crashes are visible in the console.
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        spawnedProcess = process

        // Wait briefly for the socket to come up.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if isSocketConnectable(socketURL) {
                installWatchdog(process: process)
                return socketURL
            }
            try await Task.sleep(for: .milliseconds(50))
            if !process.isRunning { break }
        }
        // Couldn't connect — tear down whatever we spawned and surface
        // the failure.
        if process.isRunning { process.terminate() }
        spawnedProcess = nil
        throw LaunchError.agentDidNotStart
    }

    /// Close the cached client and, if we spawned the agent ourselves,
    /// terminate it. Idempotent.
    public func shutdown() async {
        guard !didShutdown else { return }
        didShutdown = true
        watchdogTask?.cancel()
        watchdogTask = nil
        connectTask?.cancel()
        connectTask = nil
        if let cachedClient {
            await cachedClient.close()
        }
        cachedClient = nil
        if let process = spawnedProcess, process.isRunning {
            process.terminate()
        }
        spawnedProcess = nil
    }

    // MARK: - Watchdog

    /// Spawn a polling task that fires `respawn()` if the broker exits
    /// without us asking it to. Polling at 250 ms keeps the cost trivial
    /// while still catching deaths within ~1 RTT for UI feedback.
    ///
    /// Termination signals we deliberately initiate (`SIGTERM` from
    /// `shutdown()`) flip `didShutdown` first, so the watchdog skips the
    /// respawn path in that case.
    private func installWatchdog(process: Process) {
        watchdogTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runWatchdog(process: process)
        }
        watchdogTask = task
    }

    private func runWatchdog(process: Process) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            if didShutdown { return }
            if !process.isRunning {
                NSLog(
                    "RivenAgent broker exited unexpectedly (status \(process.terminationStatus)); attempting respawn"
                )
                await respawn()
                return
            }
        }
    }

    /// Attempt to bring a fresh broker online. Cleans up the dead
    /// process's bookkeeping, then re-runs the spawn flow with
    /// exponential backoff (1s → 2s → 4s → 8s cap) until we succeed or
    /// the launcher is shut down.
    private func respawn() async {
        guard !didShutdown, !isRespawning else { return }
        isRespawning = true
        defer { isRespawning = false }

        // Close the dead client connection (the underlying socket is
        // already gone). Clear caches so `start()` + `client()` rebuild.
        if let cachedClient {
            await cachedClient.close()
        }
        cachedClient = nil
        connectTask?.cancel()
        connectTask = nil
        spawnedProcess = nil

        var backoffMS: UInt64 = 1000
        while !didShutdown {
            do {
                _ = try await spawnIfNeeded()
                let fresh = try await client()
                if didShutdown { return }
                onClientReplaced?(fresh)
                return
            } catch {
                NSLog("RivenAgent respawn attempt failed (\(error)); retrying in \(backoffMS) ms")
                try? await Task.sleep(for: .milliseconds(backoffMS))
                backoffMS = min(backoffMS * 2, 8000)
            }
        }
    }

    // MARK: - Client access

    /// Return a connected `AgentClient`. The connection is established on
    /// first call and cached; concurrent callers share the same task so
    /// we don't open multiple sockets.
    public func client() async throws -> AgentClient {
        if let cachedClient { return cachedClient }
        if let connectTask { return try await connectTask.value }

        let task = Task<AgentClient, Error> { [socketURL] in
            let client = AgentClient(socketURL: socketURL)
            try await client.connect()
            return client
        }
        connectTask = task
        do {
            let client = try await task.value
            cachedClient = client
            connectTask = nil
            return client
        } catch {
            connectTask = nil
            throw error
        }
    }

    /// True if the launcher believes the agent is the one it spawned (as
    /// opposed to attached to a pre-existing broker). Useful for tests.
    public var ownsAgent: Bool { spawnedProcess != nil }

    // MARK: - Errors

    public enum LaunchError: Error, CustomStringConvertible {
        case binaryNotFound
        case agentDidNotStart

        public var description: String {
            switch self {
            case .binaryNotFound: return "RivenAgent binary not found near app bundle or via swift build --show-bin-path"
            case .agentDidNotStart: return "RivenAgent spawned but did not become connectable within timeout"
            }
        }
    }

    // MARK: - Helpers

    /// Probe the socket with a short-lived `connect(2)` call. Returns
    /// true iff a server is currently accepting on it. Cheaper and more
    /// reliable than relying on `fileExists(atPath:)` alone — a stale
    /// socket file from a previously-killed agent will still exist on
    /// disk but refuse to connect.
    private func isSocketConnectable(_ url: URL) -> Bool {
        let path = url.path
        // Quick-fail if there's nothing on disk.
        if !FileManager.default.fileExists(atPath: path) { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard pathBytes.count <= maxLen else { return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { rawPtr in
            rawPtr.withMemoryRebound(to: CChar.self, capacity: maxLen + 1) { cPtr in
                for (i, b) in pathBytes.enumerated() {
                    cPtr[i] = CChar(bitPattern: b)
                }
                cPtr[pathBytes.count] = 0
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { aptr -> Int32 in
            aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saptr in
                connect(fd, saptr, len)
            }
        }
        return result == 0
    }

    /// Locate the RivenAgent executable. Order:
    ///   1. Same directory as `Bundle.main.executableURL` (production:
    ///      both live next to each other inside the app bundle).
    ///   2. The directory reported by `swift build --show-bin-path` (dev
    ///      builds when the UI is launched via `swift run` and the agent
    ///      is sitting in `.build/<config>/<triple>`).
    static func locateAgentBinary() throws -> URL {
        let fm = FileManager.default

        // (1) Bundle directory of the running executable.
        if let exe = Bundle.main.executableURL {
            let candidate = exe.deletingLastPathComponent().appendingPathComponent("RivenAgent")
            if fm.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        // (2) `swift build --show-bin-path` fallback.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["swift", "build", "--show-bin-path"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            throw LaunchError.binaryNotFound
        }
        proc.waitUntilExit()
        let raw = pipe.fileHandleForReading.readDataToEndOfFile()
        let binPath = String(data: raw, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !binPath.isEmpty {
            let candidate = URL(fileURLWithPath: binPath).appendingPathComponent("RivenAgent")
            if fm.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw LaunchError.binaryNotFound
    }
}

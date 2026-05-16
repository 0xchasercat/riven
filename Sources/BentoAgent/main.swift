import BentoCore
import Darwin
import Dispatch
import Foundation
import Network

// MARK: - Ring buffer

/// Fixed-capacity byte ring buffer used to replay recent output on reconnect.
final class RingBuffer: @unchecked Sendable {
    private var buffer: [UInt8]
    private var head = 0
    private var count = 0
    private let lock = NSLock()
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = Array(repeating: 0, count: capacity)
    }

    func append(_ data: Data) {
        guard capacity > 0, !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var srcOffset = 0
            var remaining = raw.count
            // If the incoming chunk is bigger than capacity, only the tail
            // matters.
            if remaining > capacity {
                srcOffset += remaining - capacity
                remaining = capacity
            }
            while remaining > 0 {
                let writePos = (head + count) % capacity
                let chunk = min(remaining, capacity - writePos)
                _ = buffer.withUnsafeMutableBufferPointer { buf in
                    memcpy(buf.baseAddress!.advanced(by: writePos), base.advanced(by: srcOffset), chunk)
                }
                srcOffset += chunk
                remaining -= chunk
                if count + chunk <= capacity {
                    count += chunk
                } else {
                    let overflow = (count + chunk) - capacity
                    count = capacity
                    head = (head + overflow) % capacity
                }
            }
        }
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        var out = Data(count: count)
        out.withUnsafeMutableBytes { raw in
            guard let dst = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let first = min(count, capacity - head)
            buffer.withUnsafeBufferPointer { src in
                memcpy(dst, src.baseAddress!.advanced(by: head), first)
                if count > first {
                    memcpy(dst.advanced(by: first), src.baseAddress!, count - first)
                }
            }
        }
        return out
    }
}

// MARK: - Scrollback persistence

/// Buffered, write-coalescing front-end to ``ScrollbackStore`` used by the
/// broker. Each `IPCEvent.output` chunk is queued in a per-pane in-memory
/// buffer; the buffer is flushed to disk under a hybrid policy:
///
/// * **Size**: as soon as a pane's pending buffer crosses
///   ``flushBytesThreshold`` (default 4 KiB) we ask the I/O queue to drain
///   that pane ASAP. The hot path stays lock-bounded — never blocked on disk.
/// * **Time**: a single repeating `DispatchSourceTimer` fires every
///   ``flushInterval`` (default 250 ms) and drains every dirty pane.
///
/// All disk I/O happens on a dedicated `DispatchQueue` (`ioQueue`) so the
/// broker's actors never block on `write(2)` or the periodic O(N) truncate.
/// Worst case after a hard kill: ~250 ms of buffered bytes. SIGTERM/SIGINT
/// flush synchronously via ``shutdown()``.
///
/// After every flush we enforce a per-pane size cap (`onDiskCapBytes`,
/// default 1 MiB) by truncating the file from the oldest end. Truncation is
/// amortized — see ``ScrollbackStore/truncateIfExceeds(_:cap:slack:)``.
final class ScrollbackPersister: @unchecked Sendable {
    let store: ScrollbackStore
    let flushBytesThreshold: Int
    let flushInterval: DispatchTimeInterval
    let onDiskCapBytes: Int
    /// Slack between the on-disk cap and the trigger that forces a rewrite.
    /// Higher = less I/O, more wasted disk; lower = tighter cap, more rewrites.
    let truncateSlackBytes: Int = 256 * 1024

    private let lock = NSLock()
    private var pending: [PaneID: Data] = [:]
    private let timer: DispatchSourceTimer
    private let ioQueue: DispatchQueue
    private var stopped = false

    init(
        store: ScrollbackStore,
        flushBytesThreshold: Int = 4 * 1024,
        flushInterval: DispatchTimeInterval = .milliseconds(250),
        onDiskCapBytes: Int = 1 * 1024 * 1024
    ) {
        self.store = store
        self.flushBytesThreshold = flushBytesThreshold
        self.flushInterval = flushInterval
        self.onDiskCapBytes = onDiskCapBytes

        self.ioQueue = DispatchQueue(label: "bento.agent.scrollback-persister.io", qos: .utility)
        self.timer = DispatchSource.makeTimerSource(queue: ioQueue)
        self.timer.schedule(deadline: .now() + flushInterval, repeating: flushInterval)
        self.timer.setEventHandler { [weak self] in
            self?.flushAll()
        }
        self.timer.resume()
    }

    /// Append `data` to the pane's pending write buffer. Never blocks on disk
    /// — when the per-pane buffer crosses ``flushBytesThreshold`` we just
    /// async-dispatch a drain to the I/O queue and return.
    func enqueue(_ data: Data, for paneID: PaneID) {
        guard !data.isEmpty else { return }
        lock.lock()
        var buf = pending[paneID] ?? Data()
        buf.append(data)
        pending[paneID] = buf
        let shouldFlush = buf.count >= flushBytesThreshold
        lock.unlock()
        if shouldFlush {
            ioQueue.async { [weak self] in
                self?.flush(paneID: paneID)
            }
        }
    }

    /// Synchronously flush a single pane's pending buffer to disk and apply
    /// the size cap. Always invoked on `ioQueue` — the timer, the
    /// size-trigger dispatch, and `flushAll()` all run there. ``shutdown()``
    /// is the one caller that runs synchronously on the calling thread (so
    /// SIGTERM blocks until everything is on disk).
    func flush(paneID: PaneID) {
        lock.lock()
        guard let data = pending.removeValue(forKey: paneID), !data.isEmpty else {
            lock.unlock()
            return
        }
        lock.unlock()
        do {
            try store.appendData(data, to: paneID)
            try store.truncateIfExceeds(paneID, cap: onDiskCapBytes, slack: truncateSlackBytes)
        } catch {
            FileHandle.standardError.write(Data("BentoAgent scrollback flush failed for \(paneID): \(error)\n".utf8))
        }
    }

    /// Flush every pane that has pending bytes (runs on `ioQueue`).
    func flushAll() {
        lock.lock()
        let ids = Array(pending.keys)
        lock.unlock()
        for id in ids { flush(paneID: id) }
    }

    /// Block until every pane's pending bytes are durable on disk, then
    /// stop the periodic timer. Used by:
    ///
    /// * SIGTERM/SIGINT — guarantees the next process generation sees all
    ///   the bytes from this one.
    /// * Subscribe path — guarantees the replay we hand to a new subscriber
    ///   includes every byte the in-memory ring already saw.
    func flushNow() {
        // Synchronously drain the io queue: any in-flight async flush is
        // already on it, and our barrier block won't run until they finish.
        ioQueue.sync(flags: .barrier) {
            self.flushAll()
        }
    }

    /// Flush everything and stop the background timer. Call from the SIGTERM
    /// path before exiting the process.
    func shutdown() {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        lock.unlock()
        timer.cancel()
        flushNow()
    }
}

// MARK: - Pane state

/// One PTY-backed pane owned by the broker. Subscribers are connections that
/// have asked for output frames; the broker fans out chunks to all of them.
actor PaneState {
    let paneID: PaneID
    let command: String
    let args: [String]
    let cwd: String
    let pty: LivePseudoTerminal
    let ringBuffer: RingBuffer
    let persister: ScrollbackPersister?
    private var subscribers: [ObjectIdentifier: ConnectionSink] = [:]
    private(set) var isRunning: Bool = true
    private(set) var exitStatus: Int32? = nil

    init(
        paneID: PaneID,
        command: String,
        args: [String],
        cwd: String,
        pty: LivePseudoTerminal,
        ringBuffer: RingBuffer,
        persister: ScrollbackPersister?
    ) {
        self.paneID = paneID
        self.command = command
        self.args = args
        self.cwd = cwd
        self.pty = pty
        self.ringBuffer = ringBuffer
        self.persister = persister
    }

    /// Add a subscriber and return the replay payload — strictly the
    /// in-memory ring buffer for THIS broker generation.
    ///
    /// We deliberately do NOT replay the on-disk scrollback here. The disk
    /// file is the union of every shell session this pane has ever had —
    /// re-feeding it into a fresh Ghostty terminal on subscribe would
    /// re-render every historical prompt every time the UI re-attached,
    /// which is what the user was seeing as "prompts stacked at the top."
    /// The disk file is still maintained for scrollback search; it just
    /// isn't auto-replayed into a live renderer.
    func addSubscriber(_ sink: ConnectionSink) -> Data {
        subscribers[ObjectIdentifier(sink)] = sink
        return ringBuffer.snapshot()
    }

    func removeSubscriber(_ sink: ConnectionSink) {
        subscribers.removeValue(forKey: ObjectIdentifier(sink))
    }

    func write(_ data: Data) {
        pty.write(data)
    }

    func resize(columns: UInt16, rows: UInt16) {
        pty.resize(columns: columns, rows: rows)
    }

    func kill() {
        pty.terminate()
    }

    func handleOutput(_ data: Data) {
        ringBuffer.append(data)
        persister?.enqueue(data, for: paneID)
        let frame = IPCFrame.event(.output(paneID: paneID, data: data))
        for (_, sink) in subscribers {
            sink.send(frame: frame)
        }
    }

    func handleExit(_ status: Int32) {
        isRunning = false
        exitStatus = status
        // Make sure any tail bytes the child wrote right before exit are on
        // disk before we tear the subscriber list down. Doing this on a
        // background queue would race the exit notification.
        persister?.flushNow()
        let frame = IPCFrame.event(.exited(paneID: paneID, status: status))
        for (_, sink) in subscribers {
            sink.send(frame: frame)
        }
        subscribers.removeAll()
    }

    func info() -> IPCPaneInfo {
        IPCPaneInfo(paneID: paneID, command: command, args: args, cwd: cwd, isRunning: isRunning)
    }
}

// MARK: - Connection sink

/// Thin wrapper around an `NWConnection` used by ``PaneState`` to push frames
/// out to a subscriber. Reference identity is what `PaneState` uses to track
/// subscriptions.
final class ConnectionSink: @unchecked Sendable {
    private let connection: NWConnection
    private let encoder = JSONEncoder()
    private let lock = NSLock()
    private var closed = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    func send(frame: IPCFrame) {
        lock.lock()
        if closed { lock.unlock(); return }
        lock.unlock()
        guard let data = try? IPCFraming.encode(frame, encoder: encoder) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }
}

// MARK: - Broker

// Actor declaration is permitted here; if error persists, check build context.
actor AgentBroker {
    private var panes: [PaneID: PaneState] = [:]
    /// Paths to scrollback files for panes that existed in a previous broker
    /// generation. We don't spin a PTY back up for them — but if a client
    /// subscribes by paneID we serve their on-disk history as a one-shot
    /// replay so the UI can repaint.
    private var dormantHistory: Set<PaneID> = []
    let persister: ScrollbackPersister?

    init(persister: ScrollbackPersister?) {
        self.persister = persister
        if let persister, let ids = try? persister.store.listPaneIDs() {
            self.dormantHistory = Set(ids)
        }
    }

    func createPane(
        paneID: PaneID,
        command: String,
        args: [String],
        cwd: String,
        columns: UInt16,
        rows: UInt16,
        env: [String: String]
    ) async throws -> PaneID {
        if panes[paneID] != nil {
            throw IPCError.alreadyExists
        }
        let pty = LivePseudoTerminal(
            spec: LivePseudoTerminal.Spec(
                executable: command,
                arguments: args,
                cwd: cwd,
                environment: env,
                columns: columns,
                rows: rows
            )
        )
        do {
            try pty.start()
        } catch let err as PseudoTerminalError {
            switch err {
            case .openptyFailed:
                throw IPCError.openptyFailed
            default:
                throw IPCError(code: "spawn_failed", message: String(describing: err))
            }
        }

        let ring = RingBuffer(capacity: AgentIPC.replayBufferBytes)
        let state = PaneState(
            paneID: paneID,
            command: command,
            args: args,
            cwd: cwd,
            pty: pty,
            ringBuffer: ring,
            persister: persister
        )
        panes[paneID] = state
        // Once a pane is live again, it owns the disk file going forward.
        dormantHistory.remove(paneID)

        // Pump output into the pane state.
        Task.detached { [pty, state] in
            for await chunk in pty.output {
                await state.handleOutput(chunk)
            }
        }
        Task.detached { [pty, state] in
            for await status in pty.exits {
                await state.handleExit(status)
            }
        }

        return paneID
    }

    func pane(_ id: PaneID) -> PaneState? { panes[id] }

    /// Scrollback for a paneID that has on-disk history but no live PTY.
    func dormantReplay(for id: PaneID) -> Data? {
        guard dormantHistory.contains(id), let persister else { return nil }
        return try? persister.store.tail(id, bytes: persister.onDiskCapBytes)
    }

    func listPanes() async -> [IPCPaneInfo] {
        var out: [IPCPaneInfo] = []
        for (_, p) in panes {
            await out.append(p.info())
        }
        // Surface dormant panes too so a reconnecting UI can find them and
        // optionally re-spawn or just replay their history.
        for id in dormantHistory where panes[id] == nil {
            out.append(IPCPaneInfo(paneID: id, command: "", args: [], cwd: "", isRunning: false))
        }
        return out
    }

    func removePane(_ id: PaneID) {
        panes.removeValue(forKey: id)
        // Killed panes also lose their dormant history entry; if scrollback
        // should outlive a kill, drop this line. Today's UX matches the prior
        // in-memory model where killing a pane discards it entirely.
        dormantHistory.remove(id)
        try? persister?.store.delete(id)
    }
}

// MARK: - BentoAgentMain

@main
struct BentoAgentMain {
    private static let signalSourceKeeper = SignalSourceKeeper()

    private actor SignalSourceKeeper {
        private var sources: [DispatchSourceSignal] = []
        func add(_ source: DispatchSourceSignal) {
            sources.append(source)
        }
    }

    static func main() async {
        let args = CommandLine.arguments
        var socketPath = AgentIPC.defaultSocketURL.path
        var scrollbackRoot: URL? = nil
        var i = 1
        while i < args.count {
            let a = args[i]
            if a == "--socket", i + 1 < args.count {
                socketPath = args[i + 1]
                i += 2
            } else if a == "--scrollback-root", i + 1 < args.count {
                scrollbackRoot = URL(fileURLWithPath: args[i + 1])
                i += 2
            } else {
                i += 1
            }
        }

        do {
            try await Self.runAgent(socketPath: socketPath, scrollbackRoot: scrollbackRoot)
        } catch {
            FileHandle.standardError.write(Data("BentoAgent fatal: \(error)\n".utf8))
            exit(1)
        }
    }

    static func runAgent(socketPath: String, scrollbackRoot: URL?) async throws {
        // Make sure the directory exists and any stale socket file is removed.
        let url = URL(fileURLWithPath: socketPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: socketPath) {
            try FileManager.default.removeItem(atPath: socketPath)
        }

        // Build the persister. If the caller didn't override the scrollback root,
        // use the standard Application Support location alongside the socket.
        let resolvedRoot: URL = scrollbackRoot ?? Self.defaultScrollbackRoot()
        let store = ScrollbackStore(root: resolvedRoot)
        let persister = ScrollbackPersister(store: store)

        let endpoint = NWEndpoint.unix(path: socketPath)
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = endpoint
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)

        let broker = AgentBroker(persister: persister)

        listener.newConnectionHandler = { connection in
            connection.start(queue: .global(qos: .userInitiated))
            Task.detached {
                await Self.handleConnection(connection, broker: broker)
            }
        }

        let started = AsyncStream<Void>.makeStream()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                started.continuation.yield(())
            case let .failed(error):
                FileHandle.standardError.write(Data("BentoAgent listener failed: \(error)\n".utf8))
                started.continuation.finish()
            case .cancelled:
                started.continuation.finish()
            default:
                break
            }
        }

        listener.start(queue: .global(qos: .userInitiated))

        // Install SIGTERM (and SIGINT) handlers that flush pending scrollback to
        // disk synchronously before exiting. Without this, up to ~250 ms of bytes
        // sitting in the persister's per-pane buffers would be lost on shutdown.
        Self.installShutdownHandlers(persister: persister)

        // Wait for ready, then announce on stdout so the parent process can
        // synchronize launch (tests rely on this line).
        for await _ in started.stream {
            FileHandle.standardOutput.write(Data("BentoAgent listening on \(socketPath)\n".utf8))
            break
        }

        // Park forever; the parent process terminates the agent.
        try await Task.sleep(nanoseconds: UInt64.max)
    }

    static func handleConnection(_ connection: NWConnection, broker: AgentBroker) async {
        let sink = ConnectionSink(connection: connection)
        var subscriptions: Set<PaneID> = []
        var readBuffer = Data()
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        func sendResponse(id: UInt64, payload: IPCResponse) {
            guard let data = try? IPCFraming.encode(.response(id: id, payload: payload), encoder: encoder) else { return }
            connection.send(content: data, completion: .contentProcessed { _ in })
        }

        func handleRequest(id: UInt64, request: IPCRequest) async {
            switch request {
            case .ping:
                sendResponse(id: id, payload: .pong)

            case let .createPane(paneID, command, args, cwd, columns, rows, env):
                do {
                    let created = try await broker.createPane(paneID: paneID, command: command, args: args, cwd: cwd, columns: columns, rows: rows, env: env)
                    sendResponse(id: id, payload: .paneCreated(paneID: created))
                } catch let err as IPCError {
                    sendResponse(id: id, payload: .error(err))
                } catch {
                    sendResponse(id: id, payload: .error(IPCError(code: "create_failed", message: String(describing: error))))
                }

            case let .writeInput(paneID, data):
                if let pane = await broker.pane(paneID) {
                    await pane.write(data)
                    sendResponse(id: id, payload: .ok)
                } else {
                    sendResponse(id: id, payload: .error(.unknownPane))
                }

            case let .resize(paneID, columns, rows):
                if let pane = await broker.pane(paneID) {
                    await pane.resize(columns: columns, rows: rows)
                    sendResponse(id: id, payload: .ok)
                } else {
                    sendResponse(id: id, payload: .error(.unknownPane))
                }

            case let .subscribeOutput(paneID):
                if let pane = await broker.pane(paneID) {
                    let replay = await pane.addSubscriber(sink)
                    subscriptions.insert(paneID)
                    sendResponse(id: id, payload: .subscribed(paneID: paneID, replay: replay))
                } else if let history = await broker.dormantReplay(for: paneID) {
                    // No live PTY for this pane in this broker generation, but
                    // there's on-disk scrollback from a previous run. Deliver it
                    // as a one-shot replay; no live events will follow.
                    sendResponse(id: id, payload: .subscribed(paneID: paneID, replay: history))
                } else {
                    sendResponse(id: id, payload: .error(.unknownPane))
                }

            case let .unsubscribeOutput(paneID):
                if let pane = await broker.pane(paneID) {
                    await pane.removeSubscriber(sink)
                }
                subscriptions.remove(paneID)
                sendResponse(id: id, payload: .ok)

            case let .killPane(paneID):
                if let pane = await broker.pane(paneID) {
                    await pane.kill()
                    await broker.removePane(paneID)
                    sendResponse(id: id, payload: .ok)
                } else {
                    sendResponse(id: id, payload: .error(.unknownPane))
                }

            case .listPanes:
                let list = await broker.listPanes()
                sendResponse(id: id, payload: .panes(list))
            }
        }

        func receiveOnce() async -> Data? {
            await withCheckedContinuation { cont in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if error != nil { cont.resume(returning: nil); return }
                    if let data, !data.isEmpty { cont.resume(returning: data); return }
                    if isComplete { cont.resume(returning: nil); return }
                    cont.resume(returning: Data())
                }
            }
        }

        readLoop: while true {
            guard let chunk = await receiveOnce() else { break }
            if chunk.isEmpty { continue }
            readBuffer.append(chunk)
            while readBuffer.count >= 4 {
                let length = readBuffer.prefix(4).withUnsafeBytes { raw -> UInt32 in
                    var be: UInt32 = 0
                    memcpy(&be, raw.baseAddress, 4)
                    return UInt32(bigEndian: be)
                }
                if Int(length) > AgentIPC.maxFrameBytes {
                    break readLoop
                }
                let total = 4 + Int(length)
                if readBuffer.count < total { break }
                let body = readBuffer.subdata(in: 4..<total)
                readBuffer.removeSubrange(0..<total)
                guard let frame = try? decoder.decode(IPCFrame.self, from: body),
                      case let .request(rid, payload) = frame else {
                    continue
                }
                await handleRequest(id: rid, request: payload)
            }
        }

        // Connection closed — drop all subscriptions for this connection. The
        // panes themselves keep running (broker survives client disconnect).
        sink.close()
        for paneID in subscriptions {
            if let pane = await broker.pane(paneID) {
                await pane.removeSubscriber(sink)
            }
        }
        connection.cancel()
    }

    private static func defaultScrollbackRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Bento", isDirectory: true).appendingPathComponent("scrollback", isDirectory: true)
    }

    /// Install POSIX signal handlers for SIGTERM and SIGINT that flush pending
    /// scrollback writes before exiting. Uses `DispatchSource` so the signal is
    /// handled on a dispatch queue rather than the (very limited) signal context.
    private static func installShutdownHandlers(persister: ScrollbackPersister) {
        let queue = DispatchQueue(label: "bento.agent.shutdown", qos: .userInitiated)
        for sig in [SIGTERM, SIGINT] {
            // Override the default disposition so the dispatch source can observe
            // the signal instead of the process being killed immediately.
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler {
                persister.shutdown()
                // Re-raise with the default handler so the parent sees the
                // expected exit status (e.g. 128+SIGTERM).
                signal(sig, SIG_DFL)
                raise(sig)
            }
            source.resume()
            // Keep the source alive for the lifetime of the process.
            Task { await signalSourceKeeper.add(source) }
        }
    }
}

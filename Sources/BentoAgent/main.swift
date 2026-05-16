import BentoCore
import Darwin
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
    private var subscribers: [ObjectIdentifier: ConnectionSink] = [:]
    private(set) var isRunning: Bool = true
    private(set) var exitStatus: Int32? = nil

    init(paneID: PaneID, command: String, args: [String], cwd: String, pty: LivePseudoTerminal, ringBuffer: RingBuffer) {
        self.paneID = paneID
        self.command = command
        self.args = args
        self.cwd = cwd
        self.pty = pty
        self.ringBuffer = ringBuffer
    }

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
        let frame = IPCFrame.event(.output(paneID: paneID, data: data))
        for (_, sink) in subscribers {
            sink.send(frame: frame)
        }
    }

    func handleExit(_ status: Int32) {
        isRunning = false
        exitStatus = status
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

actor AgentBroker {
    private var panes: [PaneID: PaneState] = [:]

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
        let state = PaneState(paneID: paneID, command: command, args: args, cwd: cwd, pty: pty, ringBuffer: ring)
        panes[paneID] = state

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

    func listPanes() async -> [IPCPaneInfo] {
        var out: [IPCPaneInfo] = []
        for (_, p) in panes {
            await out.append(p.info())
        }
        return out
    }

    func removePane(_ id: PaneID) {
        panes.removeValue(forKey: id)
    }
}

// MARK: - Connection handler

func handleConnection(_ connection: NWConnection, broker: AgentBroker) async {
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

// MARK: - Listener

func runAgent(socketPath: String) async throws {
    // Make sure the directory exists and any stale socket file is removed.
    let url = URL(fileURLWithPath: socketPath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: socketPath) {
        try FileManager.default.removeItem(atPath: socketPath)
    }

    let endpoint = NWEndpoint.unix(path: socketPath)
    let params = NWParameters.tcp
    params.requiredLocalEndpoint = endpoint
    params.allowLocalEndpointReuse = true
    let listener = try NWListener(using: params)

    let broker = AgentBroker()

    listener.newConnectionHandler = { connection in
        connection.start(queue: .global(qos: .userInitiated))
        Task.detached {
            await handleConnection(connection, broker: broker)
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

    // Wait for ready, then announce on stdout so the parent process can
    // synchronize launch (tests rely on this line).
    for await _ in started.stream {
        FileHandle.standardOutput.write(Data("BentoAgent listening on \(socketPath)\n".utf8))
        break
    }

    // Park forever; the parent process terminates the agent.
    try await Task.sleep(nanoseconds: UInt64.max)
}

@main
struct BentoAgentMain {
    static func main() async {
        let args = CommandLine.arguments
        var socketPath = AgentIPC.defaultSocketURL.path
        var i = 1
        while i < args.count {
            let a = args[i]
            if a == "--socket", i + 1 < args.count {
                socketPath = args[i + 1]
                i += 2
            } else {
                i += 1
            }
        }

        do {
            try await runAgent(socketPath: socketPath)
        } catch {
            FileHandle.standardError.write(Data("BentoAgent fatal: \(error)\n".utf8))
            exit(1)
        }
    }
}

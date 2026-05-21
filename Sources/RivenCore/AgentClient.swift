import Foundation
import Network

/// Client for the RivenAgent broker.
///
/// Wraps a Network.framework `NWConnection` to a Unix domain socket, multiplexes
/// request/response over a single connection, and exposes
/// `AsyncThrowingStream<IPCEvent, Error>` for output subscription.
///
/// Reconnect: clients can re-create an `AgentClient`, call ``connect()``, then
/// ``subscribe(paneID:)`` with a previously-created `PaneID`. The broker
/// replays its ring buffer in the initial `subscribed` response so the UI
/// repaints immediately on reconnect.
public actor AgentClient {
    public enum ClientError: Error, Equatable {
        case notConnected
        case connectionFailed(String)
        case decodeFailed(String)
        case protocolViolation(String)
        case closed
        case unexpectedResponse
        case server(IPCError)
    }

    private let socketURL: URL
    private var connection: NWConnection?
    private var nextRequestID: UInt64 = 1
    private var pending: [UInt64: CheckedContinuation<IPCResponse, Error>] = [:]
    private var subscribers: [PaneID: AsyncThrowingStream<IPCEvent, Error>.Continuation] = [:]
    private var receiveTask: Task<Void, Never>?
    private var readBuffer = Data()
    private var closed = false

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Tiny locked flag used to ensure a continuation is resumed exactly once
    /// from concurrent callback closures. Sendable so it can cross actor
    /// boundaries inside a `withCheckedThrowingContinuation` closure.
    private final class AtomicBool: @unchecked Sendable {
        private var value = false
        private let lock = NSLock()
        /// Atomically transition from false → true. Returns true iff this
        /// call performed the transition (caller should run its side effect).
        func setIfFalse() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if value { return false }
            value = true
            return true
        }
    }

    public init(socketURL: URL = AgentIPC.defaultSocketURL) {
        self.socketURL = socketURL
    }

    deinit {
        receiveTask?.cancel()
    }

    public func connect() async throws {
        if connection != nil { return }
        let endpoint = NWEndpoint.unix(path: socketURL.path)
        let params = NWParameters.tcp
        let conn = NWConnection(to: endpoint, using: params)
        self.connection = conn

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resumedBox = AtomicBool()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumedBox.setIfFalse() { cont.resume() }
                case let .failed(error):
                    if resumedBox.setIfFalse() { cont.resume(throwing: ClientError.connectionFailed(String(describing: error))) }
                case .cancelled:
                    if resumedBox.setIfFalse() { cont.resume(throwing: ClientError.closed) }
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }

        // Install a non-throwing handler for future state transitions so we can
        // tear down subscribers cleanly when the server goes away.
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                Task { await self.handleDisconnect() }
            default:
                break
            }
        }

        receiveTask = Task { [weak self] in
            await self?.readLoop()
        }
    }

    public func close() async {
        closed = true
        receiveTask?.cancel()
        receiveTask = nil
        connection?.cancel()
        connection = nil
        for (_, cont) in pending {
            cont.resume(throwing: ClientError.closed)
        }
        pending.removeAll()
        for (_, sub) in subscribers {
            sub.finish(throwing: ClientError.closed)
        }
        subscribers.removeAll()
    }

    // MARK: - Public API

    public func ping() async throws {
        let resp = try await send(.ping)
        guard case .pong = resp else { throw ClientError.unexpectedResponse }
    }

    @discardableResult
    public func createPane(
        paneID: PaneID,
        command: String,
        args: [String] = [],
        cwd: String = NSHomeDirectory(),
        columns: UInt16 = 80,
        rows: UInt16 = 24,
        env: [String: String] = [:]
    ) async throws -> PaneID {
        let resp = try await send(.createPane(paneID: paneID, command: command, args: args, cwd: cwd, columns: columns, rows: rows, env: env))
        switch resp {
        case let .paneCreated(id):
            return id
        case let .error(err):
            throw ClientError.server(err)
        default:
            throw ClientError.unexpectedResponse
        }
    }

    public func writeInput(paneID: PaneID, data: Data) async throws {
        let resp = try await send(.writeInput(paneID: paneID, data: data))
        try expectOK(resp)
    }

    public func resize(paneID: PaneID, columns: UInt16, rows: UInt16) async throws {
        let resp = try await send(.resize(paneID: paneID, columns: columns, rows: rows))
        try expectOK(resp)
    }

    public func killPane(paneID: PaneID) async throws {
        let resp = try await send(.killPane(paneID: paneID))
        try expectOK(resp)
    }

    public func listPanes() async throws -> [IPCPaneInfo] {
        let resp = try await send(.listPanes)
        switch resp {
        case let .panes(list): return list
        case let .error(err): throw ClientError.server(err)
        default: throw ClientError.unexpectedResponse
        }
    }

    /// Subscribe to output for a pane. The returned stream yields one
    /// synthetic `.output` event containing any buffered replay bytes (if
    /// non-empty), followed by live output events as they arrive. The stream
    /// finishes when the pane exits or the connection drops.
    public func subscribe(paneID: PaneID) async throws -> AsyncThrowingStream<IPCEvent, Error> {
        let (stream, cont) = AsyncThrowingStream<IPCEvent, Error>.makeStream()
        if let existing = subscribers[paneID] {
            existing.finish()
        }
        subscribers[paneID] = cont
        cont.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.handleSubscriptionTermination(paneID: paneID) }
        }

        let resp: IPCResponse
        do {
            resp = try await send(.subscribeOutput(paneID: paneID))
        } catch {
            subscribers.removeValue(forKey: paneID)
            cont.finish(throwing: error)
            throw error
        }

        switch resp {
        case let .subscribed(_, replay):
            if !replay.isEmpty {
                cont.yield(.output(paneID: paneID, data: replay))
            }
            return stream
        case let .error(err):
            subscribers.removeValue(forKey: paneID)
            cont.finish(throwing: ClientError.server(err))
            throw ClientError.server(err)
        default:
            subscribers.removeValue(forKey: paneID)
            cont.finish(throwing: ClientError.unexpectedResponse)
            throw ClientError.unexpectedResponse
        }
    }

    // MARK: - Internals

    private func expectOK(_ resp: IPCResponse) throws {
        switch resp {
        case .ok: return
        case let .error(err): throw ClientError.server(err)
        default: throw ClientError.unexpectedResponse
        }
    }

    private func handleSubscriptionTermination(paneID: PaneID) async {
        subscribers.removeValue(forKey: paneID)
        guard !closed, connection != nil else { return }
        _ = try? await send(.unsubscribeOutput(paneID: paneID))
    }

    private func send(_ request: IPCRequest) async throws -> IPCResponse {
        guard let conn = connection else { throw ClientError.notConnected }
        let id = nextRequestID
        nextRequestID &+= 1
        let frame = IPCFrame.request(id: id, payload: request)
        let data = try IPCFraming.encode(frame, encoder: encoder)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<IPCResponse, Error>) in
            pending[id] = cont
            conn.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error {
                    Task { await self?.failPending(id: id, error: ClientError.connectionFailed(String(describing: error))) }
                }
            })
        }
    }

    private func failPending(id: UInt64, error: Error) {
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(throwing: error)
        }
    }

    private func handleDisconnect() {
        for (_, cont) in pending {
            cont.resume(throwing: ClientError.closed)
        }
        pending.removeAll()
        for (_, sub) in subscribers {
            sub.finish(throwing: ClientError.closed)
        }
        subscribers.removeAll()
        connection = nil
    }

    private func readLoop() async {
        guard let conn = connection else { return }
        while !closed {
            do {
                let chunk = try await receive(conn: conn)
                if chunk.isEmpty {
                    // EOF
                    handleDisconnect()
                    return
                }
                readBuffer.append(chunk)
                try drainFrames()
            } catch is CancellationError {
                return
            } catch {
                handleDisconnect()
                return
            }
        }
    }

    private func receive(conn: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                if let data, !data.isEmpty {
                    cont.resume(returning: data)
                    return
                }
                if isComplete {
                    cont.resume(returning: Data())
                    return
                }
                cont.resume(returning: Data())
            }
        }
    }

    private func drainFrames() throws {
        while true {
            guard readBuffer.count >= 4 else { return }
            let header = readBuffer.prefix(4)
            let length = header.withUnsafeBytes { raw -> UInt32 in
                var be: UInt32 = 0
                memcpy(&be, raw.baseAddress, 4)
                return UInt32(bigEndian: be)
            }
            if Int(length) > AgentIPC.maxFrameBytes {
                throw ClientError.protocolViolation("frame too large: \(length)")
            }
            let total = 4 + Int(length)
            guard readBuffer.count >= total else { return }
            let body = readBuffer.subdata(in: 4..<total)
            readBuffer.removeSubrange(0..<total)

            let frame: IPCFrame
            do {
                frame = try IPCFraming.decode(body, decoder: decoder)
            } catch {
                throw ClientError.decodeFailed(String(describing: error))
            }
            dispatch(frame)
        }
    }

    private func dispatch(_ frame: IPCFrame) {
        switch frame {
        case let .response(id, payload):
            if let cont = pending.removeValue(forKey: id) {
                cont.resume(returning: payload)
            }
        case let .event(event):
            switch event {
            case let .output(paneID, _):
                subscribers[paneID]?.yield(event)
            case let .exited(paneID, _):
                if let sub = subscribers[paneID] {
                    sub.yield(event)
                    sub.finish()
                    subscribers.removeValue(forKey: paneID)
                }
            }
        case .request:
            // Server should not initiate requests to the client; ignore.
            break
        }
    }
}

import Foundation

/// Wire protocol for the BentoAgent broker.
///
/// Frames are length-prefixed: a 4-byte big-endian `UInt32` length followed by
/// a JSON-encoded payload (one of ``IPCRequest``, ``IPCResponse`` or
/// ``IPCEvent``). All payloads use Swift `Codable` enums with associated values.
///
/// Default broker socket path: `~/Library/Application Support/Bento/agent.sock`
/// (the agent auto-creates the parent directory on launch). Tests pass a
/// per-test path via the `--socket <path>` CLI flag.
public enum AgentIPC {
    /// Default Unix domain socket path used by the production agent.
    public static var defaultSocketURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Bento", isDirectory: true).appendingPathComponent("agent.sock")
    }

    /// Maximum number of bytes the broker buffers per pane for replay on
    /// reconnect. 64 KiB is enough to redraw a typical terminal viewport
    /// while keeping memory bounded for many panes.
    public static let replayBufferBytes: Int = 64 * 1024

    /// Maximum frame size accepted on the wire (16 MiB). Prevents a malformed
    /// length prefix from triggering an unbounded allocation.
    public static let maxFrameBytes: Int = 16 * 1024 * 1024
}

// MARK: - Requests

public enum IPCRequest: Codable, Sendable, Equatable {
    /// Create a brand-new pane. Server allocates the PTY and stores it under
    /// `paneID`. If the pane already exists this fails with `.alreadyExists`.
    case createPane(paneID: PaneID, command: String, args: [String], cwd: String, columns: UInt16, rows: UInt16, env: [String: String])
    /// Write bytes to the pane's stdin.
    case writeInput(paneID: PaneID, data: Data)
    /// Resize the PTY window.
    case resize(paneID: PaneID, columns: UInt16, rows: UInt16)
    /// Subscribe to output. The server immediately replays its ring buffer
    /// then streams new output frames as `IPCEvent.output` events. One
    /// subscription per connection.
    case subscribeOutput(paneID: PaneID)
    /// Stop streaming output to the calling connection.
    case unsubscribeOutput(paneID: PaneID)
    /// Send SIGTERM to the pane's child process and remove its bookkeeping.
    case killPane(paneID: PaneID)
    /// Return the list of currently-tracked panes.
    case listPanes
    /// Liveness check.
    case ping
}

// MARK: - Responses

public enum IPCResponse: Codable, Sendable, Equatable {
    case ok
    case pong
    case paneCreated(paneID: PaneID)
    case panes([IPCPaneInfo])
    /// Sent immediately after a `subscribeOutput` to deliver any buffered
    /// output the server has on hand. Subsequent output arrives as events.
    case subscribed(paneID: PaneID, replay: Data)
    case error(IPCError)
}

public struct IPCPaneInfo: Codable, Sendable, Equatable {
    public var paneID: PaneID
    public var command: String
    public var args: [String]
    public var cwd: String
    public var isRunning: Bool

    public init(paneID: PaneID, command: String, args: [String], cwd: String, isRunning: Bool) {
        self.paneID = paneID
        self.command = command
        self.args = args
        self.cwd = cwd
        self.isRunning = isRunning
    }
}

public struct IPCError: Codable, Sendable, Equatable, Error {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public static let unknownPane = IPCError(code: "unknown_pane", message: "no pane with that id")
    public static let alreadyExists = IPCError(code: "already_exists", message: "pane with that id already exists")
    public static let spawnFailed = IPCError(code: "spawn_failed", message: "failed to spawn child process")
    public static let openptyFailed = IPCError(code: "openpty_failed", message: "openpty() failed")
}

// MARK: - Events

public enum IPCEvent: Codable, Sendable, Equatable {
    case output(paneID: PaneID, data: Data)
    case exited(paneID: PaneID, status: Int32)
}

// MARK: - Frame envelope

/// Frames carry either a response (correlated by `id` to a request) or an
/// unsolicited event. We use a single envelope so the client can demux a
/// single connection.
public enum IPCFrame: Codable, Sendable, Equatable {
    case request(id: UInt64, payload: IPCRequest)
    case response(id: UInt64, payload: IPCResponse)
    case event(IPCEvent)
}

// MARK: - Framing helpers

public enum IPCFraming {
    public static func encode(_ frame: IPCFrame, encoder: JSONEncoder = JSONEncoder()) throws -> Data {
        let body = try encoder.encode(frame)
        var header = UInt32(body.count).bigEndian
        var out = Data(capacity: 4 + body.count)
        withUnsafeBytes(of: &header) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }

    public static func decode(_ body: Data, decoder: JSONDecoder = JSONDecoder()) throws -> IPCFrame {
        try decoder.decode(IPCFrame.self, from: body)
    }
}

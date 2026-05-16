import Foundation

public enum EngineIntegrationStatus: Equatable, Codable, Sendable {
    case required
    case linked(version: String)
    case unavailable(reason: String)
}

public protocol TerminalEngine: Sendable {
    var status: EngineIntegrationStatus { get }
    func makePane(id: PaneID, cwd: String, command: String?) throws
}

public protocol EditorEngine: Sendable {
    var status: EngineIntegrationStatus { get }
    func openDocument(path: String) throws
}

public struct GhosttyEngineContract: TerminalEngine {
    public let status: EngineIntegrationStatus
    public let bridge: GhosttyBridge

    public init(status: EngineIntegrationStatus = .linked(version: "libghostty-vt"), bridge: GhosttyBridge = GhosttyBridge()) {
        self.status = status
        self.bridge = bridge
    }

    public func makePane(id: PaneID, cwd: String, command: String?) throws {
        _ = try bridge.createSession(id: id, cwd: cwd, command: command)
    }
}

public struct STTextViewEngineContract: EditorEngine {
    public let status: EngineIntegrationStatus

    public init(status: EngineIntegrationStatus = .linked(version: "2.x")) {
        self.status = status
    }

    public func openDocument(path: String) throws {
        guard case .linked = status else {
            throw EngineIntegrationError.stTextViewUnavailable
        }
    }
}

public enum EngineIntegrationError: Error, Equatable {
    case stTextViewUnavailable
}

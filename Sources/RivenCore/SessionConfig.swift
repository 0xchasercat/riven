import Foundation
import Yams

public enum RestartPolicy: String, Codable, Sendable {
    case never
}

public struct TaskPaneConfig: Equatable, Codable, Sendable {
    public var name: String
    public var cwd: String?
    public var command: String
    public var restart: RestartPolicy

    public init(name: String, cwd: String? = nil, command: String, restart: RestartPolicy = .never) {
        self.name = name
        self.cwd = cwd
        self.command = command
        self.restart = restart
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        self.command = try container.decode(String.self, forKey: .command)
        self.restart = try container.decodeIfPresent(RestartPolicy.self, forKey: .restart) ?? .never
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case cwd
        case command = "cmd"
        case restart
    }
}

public struct SessionConfig: Equatable, Codable, Sendable {
    public var version: Int
    public var panes: [TaskPaneConfig]

    public init(version: Int, panes: [TaskPaneConfig]) {
        self.version = version
        self.panes = panes
    }

    public static func parse(_ yaml: String) throws -> SessionConfig {
        let decoder = YAMLDecoder()
        let decoded = try decoder.decode(SessionConfig.self, from: yaml)
        guard decoded.version == 1 else {
            throw SessionConfigError.unsupportedVersion(decoded.version)
        }
        return decoded
    }
}

public enum SessionConfigError: Error, Equatable {
    case unsupportedVersion(Int)
    case invalidPane([String: String])
}

public final class ProjectTrustStore: @unchecked Sendable {
    private var trustedProjectPaths: Set<String>

    public init(trustedProjectPaths: Set<String> = []) {
        self.trustedProjectPaths = trustedProjectPaths
    }

    public func trust(projectRoot: URL) {
        trustedProjectPaths.insert(projectRoot.standardizedFileURL.path)
    }

    public func isTrusted(projectRoot: URL) -> Bool {
        trustedProjectPaths.contains(projectRoot.standardizedFileURL.path)
    }
}

import Foundation

public struct TaskPanePlanner: Sendable {
    public var config: SessionConfig
    public var projectRoot: URL
    public var trustStore: ProjectTrustStore

    public init(config: SessionConfig, projectRoot: URL, trustStore: ProjectTrustStore) {
        self.config = config
        self.projectRoot = projectRoot.standardizedFileURL
        self.trustStore = trustStore
    }

    public var requiresTrustPrompt: Bool {
        !config.panes.isEmpty && !trustStore.isTrusted(projectRoot: projectRoot)
    }

    public func agentRequests() -> [AgentRequest] {
        guard !requiresTrustPrompt else { return [] }
        return config.panes.map { pane in
            .createTerminal(
                PaneID("task-\(slug(pane.name))"),
                cwd: resolvedCWD(pane.cwd),
                command: pane.command
            )
        }
    }

    private func resolvedCWD(_ cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else {
            return projectRoot.path
        }
        if cwd.hasPrefix("/") {
            return cwd
        }
        return projectRoot.appendingPathComponent(cwd).standardizedFileURL.path
    }

    private func slug(_ value: String) -> String {
        value
            .lowercased()
            .map { character in
                character.isLetter || character.isNumber ? character : "-"
            }
            .reduce(into: "") { result, character in
                if character == "-", result.last == "-" { return }
                result.append(character)
            }
    }
}

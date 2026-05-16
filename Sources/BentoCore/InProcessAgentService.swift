import Foundation

public actor InProcessAgentService {
    private var terminals: [PaneID: TerminalPane] = [:]
    private let scrollbackStore: ScrollbackStore

    public init(scrollbackStore: ScrollbackStore) {
        self.scrollbackStore = scrollbackStore
    }

    public func handle(_ request: AgentRequest) async throws {
        switch request {
        case let .createTerminal(paneID, cwd, command):
            terminals[paneID] = TerminalPane(command: command, cwd: cwd)
            if let command {
                let output = try await awaitCommand(command, cwd: cwd)
                try scrollbackStore.append(output, to: paneID)
            }
        case let .terminate(paneID):
            terminals.removeValue(forKey: paneID)
        case .attach, .resize, .sendInput, .restore:
            break
        }
    }

    public func recordOutput(_ text: String, from paneID: PaneID) throws {
        try scrollbackStore.append(text, to: paneID)
    }

    public func searchScrollback(_ query: String) throws -> [ScrollbackMatch] {
        try scrollbackStore.search(query)
    }

    private func awaitCommand(_ command: String, cwd: String) async throws -> String {
        try await PseudoTerminalSession(
            executable: "/bin/zsh",
            arguments: ["-lc", command],
            cwd: cwd
        ).runUntilExit(timeout: .seconds(10))
    }
}

public extension ScrollbackStore {
    static func temporary() -> ScrollbackStore {
        ScrollbackStore(root: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString))
    }
}

import Foundation

public enum AgentRequest: Equatable, Codable, Sendable {
    case createTerminal(PaneID, cwd: String, command: String?)
    case attach(PaneID)
    case resize(PaneID, columns: Int, rows: Int)
    case sendInput(PaneID, String)
    case terminate(PaneID)
    case restore(WorkspaceSnapshot)
}

public enum AgentEvent: Equatable, Codable, Sendable {
    case output(PaneID, String)
    case exited(PaneID, status: Int32)
    case restored(WorkspaceSnapshot)
    case failed(String)
}

import Foundation

/// A terminal pane that a project's `.riven/session.yml` asks Riven to
/// open on launch — a name resolved to a working directory + command.
/// Produced by `TaskPanePlanner` and carried on
/// `WorkspaceState.taskTerminals`.
///
/// Modeled as a single-case enum (rather than a struct) so the call
/// sites read as `.createTerminal(...)` and so additional launch kinds
/// can be added later without a source break.
public enum TaskTerminalRequest: Codable, Equatable, Sendable {
    case createTerminal(PaneID, cwd: String, command: String?)
}

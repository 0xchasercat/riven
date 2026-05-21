import Foundation

public struct WorkspaceSnapshot: Equatable, Codable, Sendable {
    public var projectRoot: String
    public var selectedThemeID: String
    public var paneGraph: PaneGraph
    public var openFiles: [String]

    public init(projectRoot: String, selectedThemeID: String, paneGraph: PaneGraph, openFiles: [String]) {
        self.projectRoot = projectRoot
        self.selectedThemeID = selectedThemeID
        self.paneGraph = paneGraph
        self.openFiles = openFiles
    }
}

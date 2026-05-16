import Foundation

public struct ProjectFileTree: Equatable, Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case directory
        case file
    }

    public var id: String { path }
    public var name: String
    public var path: String
    public var kind: Kind
    public var children: [ProjectFileTree]

    public init(name: String, path: String, kind: Kind, children: [ProjectFileTree] = []) {
        self.name = name
        self.path = path
        self.kind = kind
        self.children = children
    }

    public static func scan(root: URL, maxDepth: Int = 6) throws -> ProjectFileTree {
        try scanNode(url: root.standardizedFileURL, depth: 0, maxDepth: maxDepth)
    }

    private static func scanNode(url: URL, depth: Int, maxDepth: Int) throws -> ProjectFileTree {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        let isDirectory = values.isDirectory == true
        guard isDirectory else {
            return ProjectFileTree(name: url.lastPathComponent, path: url.path, kind: .file)
        }

        let children: [ProjectFileTree]
        if depth >= maxDepth {
            children = []
        } else {
            let entries = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            children = try entries
                .filter { !ignoredNames.contains($0.lastPathComponent) }
                .map { try scanNode(url: $0, depth: depth + 1, maxDepth: maxDepth) }
                .sorted(by: sortNodes)
        }

        return ProjectFileTree(name: url.lastPathComponent, path: url.path, kind: .directory, children: children)
    }

    private static let ignoredNames: Set<String> = [
        ".git",
        ".build",
        ".swiftpm",
        "DerivedData",
        "node_modules",
        "target"
    ]

    private static func sortNodes(_ lhs: ProjectFileTree, _ rhs: ProjectFileTree) -> Bool {
        if lhs.kind != rhs.kind {
            return lhs.kind == .directory
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

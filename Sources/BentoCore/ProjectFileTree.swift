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
    /// H-12: number of additional children that were elided from
    /// `children` to keep the sidebar bounded on huge directories.
    /// Zero when the directory fit under the per-directory cap.
    /// Sidebar renders a "…N more" affordance when non-zero so users
    /// know there's hidden content (and can drop into Finder).
    public var truncatedChildren: Int

    public init(
        name: String,
        path: String,
        kind: Kind,
        children: [ProjectFileTree] = [],
        truncatedChildren: Int = 0
    ) {
        self.name = name
        self.path = path
        self.kind = kind
        self.children = children
        self.truncatedChildren = truncatedChildren
    }

    // Custom decoder so adding `truncatedChildren` doesn't break
    // decoding of any WorkspaceSnapshot persisted before this commit.
    // Older snapshots simply have no `truncatedChildren` key; we
    // default it to 0 (no elision) so a re-scan can populate the
    // real value on the next openProject.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.path = try c.decode(String.self, forKey: .path)
        self.kind = try c.decode(Kind.self, forKey: .kind)
        self.children = try c.decodeIfPresent([ProjectFileTree].self, forKey: .children) ?? []
        self.truncatedChildren = try c.decodeIfPresent(Int.self, forKey: .truncatedChildren) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case name, path, kind, children, truncatedChildren
    }

    /// H-12: default per-directory cap. Tested against a 10k-file
    /// project — capping at 1000 keeps SwiftUI's lazy stack happy on
    /// disclose (well under a second) while still rendering 100% of a
    /// normal source tree without truncation. The 6-level depth cap
    /// further bounds total memory.
    public static let defaultMaxChildrenPerDirectory: Int = 1000

    public static func scan(
        root: URL,
        maxDepth: Int = 6,
        maxChildrenPerDirectory: Int = defaultMaxChildrenPerDirectory
    ) throws -> ProjectFileTree {
        try scanNode(
            url: root.standardizedFileURL,
            depth: 0,
            maxDepth: maxDepth,
            maxChildren: maxChildrenPerDirectory
        )
    }

    private static func scanNode(
        url: URL,
        depth: Int,
        maxDepth: Int,
        maxChildren: Int
    ) throws -> ProjectFileTree {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        let isDirectory = values.isDirectory == true
        guard isDirectory else {
            return ProjectFileTree(name: url.lastPathComponent, path: url.path, kind: .file)
        }

        let children: [ProjectFileTree]
        var elided = 0
        if depth >= maxDepth {
            children = []
        } else {
            let entries = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            let filtered = entries.filter { !ignoredNames.contains($0.lastPathComponent) }
            // Cap before recursing — a directory with 10k file siblings
            // would otherwise pay a `lstat(2)` per entry just to be sorted
            // and then thrown away. Sort the elided suffix consistently
            // so the "first N" the user sees on subsequent scans match.
            let sortedURLs = filtered.sorted { lhs, rhs in
                // Cheap pre-sort by extension-less name; we don't have
                // `kind` info yet without recursing, so the sidebar's
                // final dir-then-file ordering is applied below after
                // scanNode resolves each entry.
                lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
            }
            let capped = Array(sortedURLs.prefix(maxChildren))
            elided = max(0, sortedURLs.count - capped.count)
            children = try capped
                .map { try scanNode(url: $0, depth: depth + 1, maxDepth: maxDepth, maxChildren: maxChildren) }
                .sorted(by: sortNodes)
        }

        return ProjectFileTree(
            name: url.lastPathComponent,
            path: url.path,
            kind: .directory,
            children: children,
            truncatedChildren: elided
        )
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

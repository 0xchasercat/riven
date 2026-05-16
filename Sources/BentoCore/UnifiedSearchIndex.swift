import Foundation

public enum UnifiedSearchResult: Equatable, Codable, Sendable {
    case file(path: String, lineNumber: Int, line: String)
    case scrollback(ScrollbackMatch)
}

public struct UnifiedSearchIndex: Sendable {
    public var projectRoot: URL
    public var scrollbackStore: ScrollbackStore

    public init(projectRoot: URL, scrollbackStore: ScrollbackStore) {
        self.projectRoot = projectRoot
        self.scrollbackStore = scrollbackStore
    }

    public func search(_ query: String) throws -> [UnifiedSearchResult] {
        var results: [UnifiedSearchResult] = try fileMatches(query)
        results.append(contentsOf: try scrollbackStore.search(query).map(UnifiedSearchResult.scrollback))
        return results
    }

    private func fileMatches(_ query: String) throws -> [UnifiedSearchResult] {
        guard FileManager.default.fileExists(atPath: projectRoot.path) else { return [] }
        let enumerator = FileManager.default.enumerator(
            at: projectRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        var results: [UnifiedSearchResult] = []

        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            guard isPlainTextCandidate(url) else { continue }
            let content = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if line.localizedCaseInsensitiveContains(query) {
                    results.append(.file(path: displayPath(for: url), lineNumber: index + 1, line: String(line)))
                }
            }
        }

        return results
    }

    private func isPlainTextCandidate(_ url: URL) -> Bool {
        let allowed = Set(["swift", "rs", "md", "txt", "json", "yml", "yaml", "toml"])
        return allowed.contains(url.pathExtension.lowercased())
    }

    private func displayPath(for url: URL) -> String {
        let canonicalRoot = projectRoot.standardizedFileURL.path
        let suppliedRoot = projectRoot.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(canonicalRoot) else { return url.path }
        return suppliedRoot + path.dropFirst(canonicalRoot.count)
    }
}

import Foundation

// MARK: - Result schema (v2)

/// Discriminated union returned by `UnifiedSearchIndex.search`. v2 swapped
/// the lightweight tuple cases for richer structs (`FileSearchHit`,
/// `ScrollbackMatchContext`) so the UI can decorate hits with surrounding
/// context, project provenance, pane labels, and timestamps.
public enum UnifiedSearchResult: Equatable, Codable, Sendable {
    case file(FileSearchHit)
    case scrollback(ScrollbackMatch, context: ScrollbackMatchContext?)
}

/// One ripgrep-style file hit. `contextBefore` / `contextAfter` carry a
/// single line of context on each side when available (nil for the first
/// or last line of a file, or when the underlying search engine didn't
/// emit context — the Swift fallback scanner currently does).
public struct FileSearchHit: Equatable, Codable, Sendable {
    public var projectRoot: String
    public var path: String
    public var lineNumber: Int
    public var line: String
    public var contextBefore: String?
    public var contextAfter: String?

    public init(
        projectRoot: String,
        path: String,
        lineNumber: Int,
        line: String,
        contextBefore: String? = nil,
        contextAfter: String? = nil
    ) {
        self.projectRoot = projectRoot
        self.path = path
        self.lineNumber = lineNumber
        self.line = line
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
    }
}

/// Decoration attached to a scrollback search hit when a sidecar exists.
/// Mirrors the most useful fields of `ScrollbackMetadata` (project,
/// workspace name, pane label, cwd, timestamps). When the source log has
/// no sidecar (legacy logs) the hit is still emitted, just with
/// `context: nil`.
public struct ScrollbackMatchContext: Equatable, Codable, Sendable {
    public var projectRoot: String?
    public var workspaceName: String?
    public var paneLabel: String?
    public var cwd: String
    public var firstSeenAt: Date
    public var lastWriteAt: Date

    public init(
        projectRoot: String?,
        workspaceName: String?,
        paneLabel: String?,
        cwd: String,
        firstSeenAt: Date,
        lastWriteAt: Date
    ) {
        self.projectRoot = projectRoot
        self.workspaceName = workspaceName
        self.paneLabel = paneLabel
        self.cwd = cwd
        self.firstSeenAt = firstSeenAt
        self.lastWriteAt = lastWriteAt
    }

    /// Build a context from a sidecar metadata record.
    init(_ metadata: ScrollbackMetadata) {
        self.projectRoot = metadata.projectRoot
        self.workspaceName = metadata.workspaceName
        self.paneLabel = metadata.paneLabel
        self.cwd = metadata.cwd
        self.firstSeenAt = metadata.createdAt
        self.lastWriteAt = metadata.lastWriteAt
    }
}

// MARK: - Search scope

/// Controls which file roots are walked when searching. Scrollback is
/// always searched globally — pane logs live under the broker's single
/// scrollback root regardless of which project they came from.
public enum SearchScope: Equatable, Sendable {
    /// Walk only the index's `projectRoot`.
    case thisProject
    /// Walk every project root referenced by any sidecar metadata, plus
    /// the index's own `projectRoot`. Useful for cross-project search.
    case allProjects
}

// MARK: - UnifiedSearchIndex

public struct UnifiedSearchIndex: Sendable {
    public var projectRoot: URL
    public var scrollbackStore: ScrollbackStore

    public init(projectRoot: URL, scrollbackStore: ScrollbackStore) {
        self.projectRoot = projectRoot
        self.scrollbackStore = scrollbackStore
    }

    /// Search files (in `scope`) and scrollback (always global). File hits
    /// come back first, followed by scrollback hits. Scrollback hits are
    /// decorated with `ScrollbackMatchContext` when a sidecar is present.
    public func search(_ query: String, scope: SearchScope = .thisProject) throws -> [UnifiedSearchResult] {
        var results: [UnifiedSearchResult] = []

        for root in resolveRoots(for: scope) {
            results.append(contentsOf: try fileMatches(query, in: root))
        }

        for match in try scrollbackStore.search(query) {
            let metadata = (try? scrollbackStore.readMetadata(match.paneID)) ?? nil
            let context = metadata.map(ScrollbackMatchContext.init)
            results.append(.scrollback(match, context: context))
        }

        return results
    }

    private func resolveRoots(for scope: SearchScope) -> [URL] {
        switch scope {
        case .thisProject:
            return [projectRoot]
        case .allProjects:
            var seen: Set<String> = []
            var roots: [URL] = []
            let primary = projectRoot.standardizedFileURL
            seen.insert(primary.path)
            roots.append(primary)

            let metas = (try? scrollbackStore.listMetadata()) ?? []
            for meta in metas {
                guard let raw = meta.projectRoot, !raw.isEmpty else { continue }
                let url = URL(fileURLWithPath: raw).standardizedFileURL
                if seen.insert(url.path).inserted {
                    roots.append(url)
                }
            }
            return roots
        }
    }

    private func fileMatches(_ query: String, in root: URL) throws -> [UnifiedSearchResult] {
        // Try the ripgrep-backed engine first; fall back to the in-process
        // Swift scanner if the bundled binary is missing or rg fails.
        if let ripgrep = RipgrepFileSearch.bundled() {
            do {
                let hits = try ripgrep.search(query: query, root: root)
                return hits.map(UnifiedSearchResult.file)
            } catch {
                // fall through to Swift scanner
            }
        }
        return try swiftFallbackMatches(query, in: root)
    }

    /// Swift-only line scanner used when ripgrep is unavailable. Mirrors
    /// the v1 behaviour but emits the richer `FileSearchHit` shape and
    /// includes one line of leading/trailing context.
    private func swiftFallbackMatches(_ query: String, in root: URL) throws -> [UnifiedSearchResult] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        var results: [UnifiedSearchResult] = []

        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            guard isPlainTextCandidate(url) else { continue }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (index, line) in lines.enumerated() {
                if line.localizedCaseInsensitiveContains(query) {
                    let before = index > 0 ? lines[index - 1] : nil
                    let after = index + 1 < lines.count ? lines[index + 1] : nil
                    let hit = FileSearchHit(
                        projectRoot: root.path,
                        path: displayPath(for: url, root: root),
                        lineNumber: index + 1,
                        line: line,
                        contextBefore: before,
                        contextAfter: after
                    )
                    results.append(.file(hit))
                }
            }
        }

        return results
    }

    private func isPlainTextCandidate(_ url: URL) -> Bool {
        let allowed = Set(["swift", "rs", "md", "txt", "json", "yml", "yaml", "toml"])
        return allowed.contains(url.pathExtension.lowercased())
    }

    private func displayPath(for url: URL, root: URL) -> String {
        let canonicalRoot = root.standardizedFileURL.path
        let suppliedRoot = root.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(canonicalRoot) else { return url.path }
        return suppliedRoot + path.dropFirst(canonicalRoot.count)
    }
}

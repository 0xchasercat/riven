import Foundation

public struct ScrollbackMatch: Equatable, Codable, Sendable {
    public var paneID: PaneID
    public var lineNumber: Int
    public var line: String

    public init(paneID: PaneID, lineNumber: Int, line: String) {
        self.paneID = paneID
        self.lineNumber = lineNumber
        self.line = line
    }
}

/// File-backed scrollback persistence. One log file per `PaneID` lives at
/// `<root>/<paneID>.log`. The file is treated as opaque bytes — text-oriented
/// readers (`search`) decode it as UTF-8, but the byte-oriented writers/readers
/// (`appendData`, `tail`, `read`) preserve raw PTY output, including ANSI
/// escape sequences and partial multibyte runs at chunk boundaries.
public struct ScrollbackStore: Sendable {
    public var root: URL

    public init(root: URL) {
        self.root = root
    }

    // MARK: - Existing API (kept stable for backward compatibility)

    /// Append `text` (UTF-8) to the pane's log file.
    public func append(_ text: String, to paneID: PaneID) throws {
        try appendData(Data(text.utf8), to: paneID)
    }

    /// Search every pane log under `root` for lines matching `query`.
    ///
    /// Per-file reads are tolerated with `try?`: a single corrupted log
    /// (truncated UTF-8, missing permissions, removed mid-iteration) is
    /// logged to stderr and skipped, never aborting the whole search.
    /// Only directory-level errors (e.g. listing `root` itself) propagate.
    public func search(_ query: String) throws -> [ScrollbackMatch] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var matches: [ScrollbackMatch] = []

        for file in files where file.pathExtension == "log" {
            let paneID = PaneID(file.deletingPathExtension().lastPathComponent)
            guard let content = try? String(contentsOf: file, encoding: .utf8) else {
                FileHandle.standardError.write(
                    Data("[ScrollbackStore.search] skipping unreadable log: \(file.lastPathComponent)\n".utf8)
                )
                continue
            }
            for (index, line) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if line.localizedCaseInsensitiveContains(query) {
                    matches.append(ScrollbackMatch(paneID: paneID, lineNumber: index + 1, line: String(line)))
                }
            }
        }

        return matches
    }

    // MARK: - Byte-oriented API (new)

    /// Append raw bytes to the pane's log file. Creates the parent directory
    /// and the file on demand. The write is performed in append mode and is
    /// not fsync'd — callers that need durability across crashes should
    /// coalesce writes and call `flush(_:)` (currently a no-op since we use
    /// the platform's normal `write(2)` cadence; documented for future use).
    public func appendData(_ data: Data, to paneID: PaneID) throws {
        guard !data.isEmpty else { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = fileURL(for: paneID)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    /// Overwrite the pane's log with `text` (UTF-8). Used by the
    /// on-demand scrollback sync: libghostty owns the grid, so before a
    /// search/peek we pull the surface's full text and replace the log
    /// rather than append (appending the whole buffer each time would
    /// grow it without bound). Creates the parent directory on demand;
    /// empty text removes the file so stale content can't linger.
    public func replace(_ text: String, to paneID: PaneID) throws {
        let url = fileURL(for: paneID)
        guard !text.isEmpty else {
            try? delete(paneID)
            return
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// Read the whole log file for `paneID`. Returns empty `Data` when the
    /// file does not exist (a brand-new pane).
    public func read(_ paneID: PaneID) throws -> Data {
        let url = fileURL(for: paneID)
        guard FileManager.default.fileExists(atPath: url.path) else { return Data() }
        return try Data(contentsOf: url)
    }

    /// Return the trailing `bytes` of the pane's log file, or all of it if
    /// the file is smaller. Returns empty `Data` when the file does not exist.
    public func tail(_ paneID: PaneID, bytes: Int) throws -> Data {
        guard bytes > 0 else { return Data() }
        let url = fileURL(for: paneID)
        guard FileManager.default.fileExists(atPath: url.path) else { return Data() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        if size <= UInt64(bytes) {
            try handle.seek(toOffset: 0)
            return try handle.readToEnd() ?? Data()
        }
        let offset = size - UInt64(bytes)
        try handle.seek(toOffset: offset)
        return try handle.readToEnd() ?? Data()
    }

    /// Truncate the pane's log file from the head so that at most `bytes`
    /// remain (the most-recent suffix). No-op if the file is already small
    /// enough or doesn't exist.
    ///
    /// Implementation: read the tail bytes, write to a sibling temp file,
    /// then atomically replace the original. This is O(N) per truncation but
    /// only runs when the cap is exceeded, so amortized cost stays low when
    /// the cap is much larger than the per-call write size.
    public func truncate(_ paneID: PaneID, to bytes: Int) throws {
        guard bytes >= 0 else { return }
        let url = fileURL(for: paneID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        if size <= bytes { return }

        let tail = try tail(paneID, bytes: bytes)
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp.\(UUID().uuidString)")
        try tail.write(to: tempURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
    }

    /// Truncate the pane's log file to `cap` bytes only when it has grown
    /// past `cap + slack`. Lets callers amortize the O(N) rewrite cost over
    /// many small appends rather than paying it on every flush.
    public func truncateIfExceeds(_ paneID: PaneID, cap: Int, slack: Int) throws {
        let url = fileURL(for: paneID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        if size <= cap + slack { return }
        try truncate(paneID, to: cap)
    }

    /// Remove the log file for `paneID`. No-op if it doesn't exist.
    public func delete(_ paneID: PaneID) throws {
        let url = fileURL(for: paneID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// List every `PaneID` that has an existing scrollback file under `root`.
    /// Used by the broker on startup to know which panes have history to
    /// replay even though there's no live PTY for them.
    public func listPaneIDs() throws -> [PaneID] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        return files
            .filter { $0.pathExtension == "log" }
            .map { PaneID($0.deletingPathExtension().lastPathComponent) }
    }

    private func fileURL(for paneID: PaneID) -> URL {
        root.appendingPathComponent(paneID.rawValue).appendingPathExtension("log")
    }
}

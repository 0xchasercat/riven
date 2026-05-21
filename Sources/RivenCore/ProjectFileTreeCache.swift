import Foundation

/// In-memory cache of `ProjectFileTree.scan` results, keyed by the
/// scanned root path.
///
/// The sidebar re-scans whenever its `currentCwd` changes — which
/// happens on every `cd` in the shell via the OSC 7 cwd report.
/// For a workspace rooted at `~/` (the common case after launching
/// Riven from the Dock), that's a depth-3 filesystem walk over a
/// home directory with thousands of entries on every navigation —
/// hundreds of milliseconds per `cd` blocking the sidebar update.
///
/// `ProjectFileTreeCache` flips that to:
///
///   * Synchronous lookup → returns the previously-scanned tree
///     immediately so the sidebar updates without waiting on I/O.
///   * Async background revalidate → a `Task.detached` rescans
///     and updates the cache so the next read picks up additions /
///     deletions that happened in the meantime.
///
/// The cache is process-wide (a `static let shared`). One entry per
/// distinct path; revisiting a path is O(1). No TTL — the assumption
/// is that for a typing-speed session, in-place edits + creates
/// are surfaced on the next revalidate pass, and that's good
/// enough. Long-running sessions where the user creates a file
/// outside of Riven and immediately expects it in the sidebar
/// can hit the refresh affordance (manual scan).
///
/// Thread safety: the cache is an `actor` so concurrent
/// background refreshes don't race. All getters/setters await the
/// actor; the call sites are already in async contexts (sidebar
/// view's `task(id:)`).
public actor ProjectFileTreeCache {
    public static let shared = ProjectFileTreeCache()

    /// Cached scan results keyed by absolute path. We deliberately
    /// don't store mtime / scan-timestamp metadata — the
    /// stale-while-revalidate contract is that any cache hit
    /// triggers an immediate background refresh, so a strict TTL
    /// would only add complexity without changing the user-visible
    /// behaviour.
    private var entries: [String: ProjectFileTree] = [:]

    /// Snapshot the cached tree for `path`, or nil on a cache miss.
    public func snapshot(for path: String) -> ProjectFileTree? {
        entries[path]
    }

    /// Replace the cached tree for `path`. Called after a background
    /// scan completes.
    public func store(_ tree: ProjectFileTree, for path: String) {
        entries[path] = tree
    }

    /// Drop all entries — used by a future "rescan everything" hook
    /// (e.g. on system wake from sleep where the filesystem could
    /// have changed dramatically while we slept).
    public func clear() {
        entries.removeAll()
    }

    /// Scan `path` synchronously and cache the result. Returns nil
    /// if the scan throws (caller decides whether to surface an
    /// error or fall back to a placeholder).
    @discardableResult
    public func loadAndCache(
        path: String,
        maxDepth: Int = 3,
        maxChildrenPerDirectory: Int = ProjectFileTree.defaultMaxChildrenPerDirectory
    ) -> ProjectFileTree? {
        let url = URL(fileURLWithPath: path)
        guard let tree = try? ProjectFileTree.scan(
            root: url,
            maxDepth: maxDepth,
            maxChildrenPerDirectory: maxChildrenPerDirectory
        ) else {
            return nil
        }
        entries[path] = tree
        return tree
    }
}

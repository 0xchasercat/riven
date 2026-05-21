import Foundation

/// UserDefaults-backed ring of the user's most recent search queries.
/// Most-recent-first, deduplicated (a repeat query is hoisted to the
/// head), capped at `limit` (default 20).
///
/// The store is intentionally value-typed: callers can construct one per
/// scope (e.g. `"Riven.search.recent"` for the unified search overlay,
/// or a different key for an editor-only Find dialog) without sharing
/// state. All mutations write through to `defaults` immediately — the
/// list is small, the writes are cheap, and durability across launches
/// is more valuable than latency micro-optimisation.
// UserDefaults itself isn't formally `Sendable` in the SDK but is
// thread-safe in practice (documented by Apple). `@unchecked Sendable`
// is the canonical workaround so callers can pass the store across
// actor boundaries without ceremony.
public struct RecentSearchesStore: @unchecked Sendable {
    public let defaults: UserDefaults
    public let key: String
    public let limit: Int

    public init(
        defaults: UserDefaults = .standard,
        key: String = "Riven.search.recent",
        limit: Int = 20
    ) {
        self.defaults = defaults
        self.key = key
        self.limit = max(0, limit)
    }

    /// Record `query` as the newest entry. Trimmed; empty/whitespace-only
    /// queries are ignored. A duplicate of an existing entry is removed
    /// from its old position and re-inserted at the head.
    public func record(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return }

        var entries = recent()
        // Case-sensitive dedupe: "Foo" and "foo" are different queries.
        // (Search itself is case-insensitive; the dropdown shows what the
        // user typed.)
        entries.removeAll(where: { $0 == trimmed })
        entries.insert(trimmed, at: 0)
        if entries.count > limit {
            entries = Array(entries.prefix(limit))
        }
        defaults.set(entries, forKey: key)
    }

    /// Snapshot the current ring, newest first. Returns `[]` when the
    /// underlying value is missing or malformed.
    public func recent() -> [String] {
        guard let raw = defaults.array(forKey: key) as? [String] else { return [] }
        return raw
    }

    /// Wipe the ring. Used by "Clear recent" controls in the UI and by
    /// tests that want a known starting state.
    public func clear() {
        defaults.removeObject(forKey: key)
    }
}

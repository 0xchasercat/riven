import Foundation

/// Pure, view-agnostic history cursor for the command bar.
///
/// The command bar lets the user walk back through previously-submitted
/// commands with the up arrow (and forward with the down arrow). The
/// rules — borrowed from shells and Warp — are slightly subtle:
///
/// * `submit(_:)` appends the entry, drops the cursor back to "live"
///   (i.e. no history entry is selected), and de-dupes consecutive
///   duplicates so spamming Enter on the same command doesn't pollute
///   the buffer.
/// * `previous(currentBuffer:)` walks one step back. When called from
///   the live state we stash the current draft so the user can return
///   to it; subsequent calls just walk further back.
/// * `next(currentBuffer:)` walks one step forward. Walking past the
///   newest entry returns to the stashed draft (or empty string).
/// * `reset()` clears the cursor so the next up-arrow starts from the
///   most recent submission again. Call this when the user types into
///   the buffer between history navigations.
///
/// The struct is `Sendable` and trivially copyable, which makes it easy
/// to keep inside a SwiftUI coordinator without locking.
public struct CommandHistory: Sendable, Equatable {
    /// Newest entries are appended to the end. Empty submissions are
    /// dropped so Enter-on-empty doesn't grow the history.
    public private(set) var entries: [String]

    /// `nil` means "live": the user is editing their draft, no history
    /// entry is selected. Otherwise an index into `entries`.
    public private(set) var cursor: Int?

    /// Holds the in-progress buffer the user had typed before they
    /// started navigating history, so `next` can restore it once they
    /// walk past the newest entry.
    public private(set) var stashedDraft: String?

    /// Maximum entries we keep. Older entries are dropped FIFO so the
    /// buffer can't grow unbounded across long-lived sessions.
    public let capacity: Int

    public init(entries: [String] = [], capacity: Int = 500) {
        precondition(capacity > 0, "history capacity must be positive")
        // Trim any oversized seed up-front so the invariant holds.
        if entries.count > capacity {
            self.entries = Array(entries.suffix(capacity))
        } else {
            self.entries = entries
        }
        self.capacity = capacity
        self.cursor = nil
        self.stashedDraft = nil
    }

    /// Records a submission. Returns `true` if the entry was actually
    /// stored (i.e. non-empty after trim and not a consecutive dup).
    @discardableResult
    public mutating func submit(_ text: String) -> Bool {
        cursor = nil
        stashedDraft = nil

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Store the submitted text verbatim (preserving whitespace and
        // embedded newlines) but use the trimmed form for dedupe.
        if let last = entries.last,
           last.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed {
            return false
        }
        entries.append(text)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        return true
    }

    /// Walks one step back through history. Returns the entry to display
    /// in the buffer, or `nil` if there is no further history (already
    /// at the oldest entry, or history is empty).
    ///
    /// `currentBuffer` is what the user has currently typed. If we're
    /// in the live state we stash it so a later `next` can restore it.
    public mutating func previous(currentBuffer: String) -> String? {
        guard !entries.isEmpty else { return nil }
        switch cursor {
        case nil:
            // First step back from live: stash the draft and select the
            // newest entry.
            stashedDraft = currentBuffer
            cursor = entries.count - 1
            return entries[entries.count - 1]
        case .some(let idx):
            guard idx > 0 else { return nil }
            let next = idx - 1
            cursor = next
            return entries[next]
        }
    }

    /// Walks one step forward through history. Returns the buffer the
    /// caller should display:
    ///   * a newer history entry, or
    ///   * the stashed draft (or empty string) when walking past the newest.
    /// Returns `nil` when we're already in the live state — the caller
    /// should leave the buffer untouched.
    public mutating func next(currentBuffer _: String) -> String? {
        guard let idx = cursor else { return nil }
        let upcoming = idx + 1
        if upcoming >= entries.count {
            // Walked past the newest entry — restore the stash.
            cursor = nil
            let draft = stashedDraft ?? ""
            stashedDraft = nil
            return draft
        }
        cursor = upcoming
        return entries[upcoming]
    }

    /// Drops the cursor back to live. Call this when the user edits the
    /// buffer between history navigations so the next up-arrow starts
    /// from the most-recent submission again.
    public mutating func reset() {
        cursor = nil
        stashedDraft = nil
    }

    /// `true` when the cursor is parked in a history entry (vs. live).
    public var isNavigating: Bool { cursor != nil }

    /// Most-recent entry whose text starts with `prefix`. Used by the
    /// command bar's zsh-autosuggestions-style ghost-text feature:
    /// as the user types, this returns the most recent matching
    /// command so the bar can render the rest of it dimmed. Right-
    /// arrow at end-of-buffer accepts.
    ///
    /// `prefix` must be non-empty (suggesting from an empty buffer
    /// would just show the most recent command, which is what the
    /// up arrow already does explicitly). The match itself must be
    /// strictly longer than the prefix — a "suggestion" that's just
    /// the prefix the user already typed is meaningless. Case-
    /// sensitive: shell history is case-significant.
    public func suggestion(for prefix: String) -> String? {
        guard !prefix.isEmpty else { return nil }
        for entry in entries.reversed() {
            if entry.hasPrefix(prefix), entry.count > prefix.count {
                return entry
            }
        }
        return nil
    }
}

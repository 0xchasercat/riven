import Foundation

/// Pure-Swift model for the editor pane's text buffer.
///
/// Holds the current file URL, the in-memory text, and a dirty flag. All
/// state transitions are deterministic and have no side effects so they
/// can be unit tested without spinning up an `STTextView`.
///
/// File I/O lives in the SwiftUI shell — this struct only describes how
/// the buffer should react when the host reports a load, an edit, a save,
/// or a URL change.
public struct EditorBuffer: Equatable, Sendable {
    /// The URL backing the buffer. `nil` means a scratch buffer that has no
    /// on-disk file (Cmd+S is a no-op until the user assigns a URL).
    public private(set) var url: URL?

    /// The current in-memory text. This is the source of truth the view
    /// renders; it may differ from on-disk contents when `isDirty` is true.
    public private(set) var text: String

    /// True when `text` has unsaved edits relative to the last load/save.
    public private(set) var isDirty: Bool

    public init(url: URL? = nil, text: String = "", isDirty: Bool = false) {
        self.url = url
        self.text = text
        self.isDirty = isDirty
    }

    /// Replace the buffer with freshly loaded contents and clear dirty.
    /// Used after a successful disk read.
    public mutating func load(url: URL?, text: String) {
        self.url = url
        self.text = text
        self.isDirty = false
    }

    /// Record that the user typed/edited inside the view. We treat any
    /// reported text as the new source of truth and flip dirty on if the
    /// content actually differs from what was last loaded/saved.
    ///
    /// Callers should pass the live string out of the text view; we only
    /// flip dirty when the text actually changes so spurious change
    /// notifications don't mark a clean buffer dirty.
    public mutating func recordEdit(text newText: String) {
        let changed = newText != text
        text = newText
        if changed {
            isDirty = true
        }
    }

    /// Apply a save: the caller wrote `text` to disk successfully, so we
    /// drop the dirty flag without touching the text or URL.
    public mutating func markSaved() {
        isDirty = false
    }

    /// Reconcile a URL change requested by the host.
    ///
    /// Policy (alpha): if the host re-asserts the same URL we already have
    /// open, preserve the in-memory buffer (including unsaved edits). If
    /// the URL actually changes — even from `nil` to a real URL — we
    /// signal the host to load fresh contents and discard any dirty
    /// buffer. The host is responsible for the actual disk read.
    public mutating func reconcile(targetURL: URL?) -> Reconciliation {
        if targetURL == url {
            return .noChange
        }
        // Different URL (including nil <-> non-nil transitions): discard
        // the current buffer and ask the host to load the new file.
        url = targetURL
        text = ""
        isDirty = false
        if let targetURL {
            return .needsLoad(targetURL)
        } else {
            return .clearedToScratch
        }
    }

    /// The outcome of a URL reconciliation, telling the host what (if
    /// anything) it should do next.
    public enum Reconciliation: Equatable, Sendable {
        /// The requested URL matches the current URL; preserve in-memory
        /// state including any unsaved edits.
        case noChange
        /// The URL changed to a real file; host should read it from disk
        /// and call `load(url:text:)` with the contents (or surface a
        /// decode error).
        case needsLoad(URL)
        /// The URL became nil; the buffer has been cleared to a scratch
        /// state.
        case clearedToScratch
    }
}

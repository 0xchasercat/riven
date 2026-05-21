import Foundation

/// Visual-truncation helpers for chrome labels — tab strips, status
/// chips, anywhere a filename might run long enough to push siblings
/// off-screen but still need to keep the leading + trailing chars
/// legible (so the user can tell `…View.swift` from `…Spec.swift`).
///
/// `truncationMode(.middle)` on a `Text` does similar work, but only
/// works when SwiftUI has measured the surrounding container and
/// decided to ellipsize. For chips that grow with their content
/// (inner tab chips) we want a hard upper bound on length regardless
/// of available width — pre-truncating the string is the simplest
/// way to enforce it.
extension String {
    /// Returns a copy of the string truncated to `maxLength` characters
    /// with a horizontal ellipsis (`…`) in the middle when the original
    /// exceeds the cap. Strings within the limit are returned verbatim.
    ///
    /// The cap is expressed in `Character`s, not bytes — emoji / CJK
    /// glyphs each count as one. The leading and trailing halves split
    /// `maxLength - 1` between them; on odd splits the leading half
    /// keeps the extra char so prefixes (the part the eye reads first)
    /// stay slightly more verbose than suffixes.
    ///
    /// `maxLength` defaults to 24 to match the inner-tab-strip cap the
    /// chrome was sized for — long enough for any reasonable filename
    /// without forcing the strip to grow into the `+` button.
    public func middleEllipsized(maxLength: Int = 24) -> String {
        precondition(maxLength >= 3, "maxLength must leave room for the ellipsis")
        guard self.count > maxLength else { return self }
        // Reserve one slot for the ellipsis glyph; split the rest so
        // the leading half wins the extra char on odd remainders.
        let usable = maxLength - 1
        let head = (usable + 1) / 2
        let tail = usable - head
        let prefix = self.prefix(head)
        let suffix = self.suffix(tail)
        return "\(prefix)\u{2026}\(suffix)"
    }
}

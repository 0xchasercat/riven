import AppKit
import BentoCore
import SwiftUI

/// H-16: read-only two-column overlay listing every shortcut a user
/// can hit from anywhere in Bento. Triggered by the Help menu's
/// "Bento Keyboard Shortcuts" item (⌘?). Sits on the same backdrop
/// as the command palette / search overlay so the chrome stays
/// visually consistent — same width, same corner radius, same modal
/// scrim opacity.
///
/// The layout is two columns × three rows so the eye can chunk the
/// surface into a "shortcuts I use" (left) / "shortcuts I should
/// learn" (right) grouping without forcing the user to scroll. If
/// we ever outgrow the static grid we can swap to a ScrollView; for
/// now, the fixed layout reads as a deliberately scoped reference
/// card rather than an exhaustive dump.
struct ShortcutsCheatsheetOverlay: View {
    let theme: ThemeSpec
    let onClose: () -> Void

    private struct ShortcutGroup: Identifiable {
        let title: String
        let entries: [Entry]
        var id: String { title }
        struct Entry: Identifiable {
            let shortcut: String
            let label: String
            var id: String { shortcut + label }
        }
    }

    private static let groups: [ShortcutGroup] = [
        .init(title: "PANE", entries: [
            .init(shortcut: "\u{2318}T",     label: "New tab"),
            .init(shortcut: "\u{2318}D",     label: "Split right"),
            .init(shortcut: "\u{2318}\u{21E7}D", label: "Split down"),
            .init(shortcut: "\u{2318}W",     label: "Close tab"),
            .init(shortcut: "\u{2318}N",     label: "New workspace"),
            .init(shortcut: "\u{2303}\u{21E5}", label: "Cycle surface focus"),
        ]),
        .init(title: "EDITOR", entries: [
            .init(shortcut: "\u{2318}S",        label: "Save"),
            .init(shortcut: "\u{2318}Z",        label: "Undo"),
            .init(shortcut: "\u{2318}\u{21E7}Z", label: "Redo"),
        ]),
        .init(title: "SEARCH", entries: [
            .init(shortcut: "\u{2318}\u{21E7}F", label: "Search files + scrollback"),
            .init(shortcut: "\u{2318}\u{21E7}P", label: "Command palette"),
            .init(shortcut: "\u{2318}\u{21E7}O", label: "Open project\u{2026}"),
        ]),
        .init(title: "THEME", entries: [
            .init(shortcut: "palette", label: "Open \u{201C}Pick theme\u{2026}\u{201D}"),
        ]),
        .init(title: "TERMINAL", entries: [
            .init(shortcut: "\u{2318}K", label: "Clear focused terminal"),
            .init(shortcut: "\u{2303}C", label: "Interrupt (SIGINT)"),
            .init(shortcut: "\u{2303}D", label: "EOF"),
            .init(shortcut: "\u{2303}Z", label: "Stop (SIGTSTP)"),
        ]),
        .init(title: "COMMAND BAR", entries: [
            .init(shortcut: "\u{2191} / \u{2193}", label: "Walk history"),
            .init(shortcut: "\u{23CE}",            label: "Submit / newline"),
            .init(shortcut: "\u{238B}",            label: "Clear"),
        ]),
    ]

    /// Pair adjacent groups so the grid renders two columns per row.
    private var rows: [(left: ShortcutGroup, right: ShortcutGroup?)] {
        var out: [(ShortcutGroup, ShortcutGroup?)] = []
        var idx = Self.groups.startIndex
        while idx < Self.groups.endIndex {
            let left = Self.groups[idx]
            let right: ShortcutGroup? = (idx + 1 < Self.groups.endIndex)
                ? Self.groups[idx + 1]
                : nil
            out.append((left, right))
            idx += 2
        }
        return out
    }

    var body: some View {
        OverlayBackdrop(theme: theme, width: OverlayWidth.picker, onClose: onClose) {
            VStack(spacing: 0) {
                OverlayHeader(theme: theme, title: "Keyboard Shortcuts") {
                    Text("\u{238B} dismiss")
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: BentoSpacing.l) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, pair in
                            HStack(alignment: .top, spacing: BentoSpacing.xxl) {
                                column(pair.left)
                                if let right = pair.right {
                                    column(right)
                                } else {
                                    Spacer()
                                        .frame(maxWidth: .infinity)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, BentoSpacing.l)
                    .padding(.vertical, BentoSpacing.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 460)
                OverlayFooter(theme: theme) {
                    Text("Help \u{2192} About Bento for version info")
                }
            }
        }
        .background(KeyEventHandling(handler: handleKey))
    }

    private func column(_ group: ShortcutGroup) -> some View {
        VStack(alignment: .leading, spacing: BentoSpacing.xs) {
            SectionLabel(theme: theme, group.title)
                .padding(.bottom, BentoSpacing.xxs)
            ForEach(group.entries) { entry in
                HStack(alignment: .firstTextBaseline, spacing: BentoSpacing.m) {
                    Text(entry.shortcut)
                        .font(BentoType.mono(BentoType.body, weight: .semibold))
                        .foregroundStyle(Color(hex: theme.chrome.accent.hex))
                        .frame(width: 92, alignment: .leading)
                    Text(entry.label)
                        .font(BentoType.chrome(BentoType.body))
                        .foregroundStyle(Color(hex: theme.chrome.text.hex))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        // 53 = escape, 36 = return. Either closes the sheet — the
        // overlay is informational, there's nothing else to commit.
        switch event.keyCode {
        case 53, 36:
            onClose()
            return nil
        default:
            return event
        }
    }
}

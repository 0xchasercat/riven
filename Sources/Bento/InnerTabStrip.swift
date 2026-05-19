import AppKit
import BentoCore
import SwiftUI

/// Inner tab strip rendered above a workspace's terminal area. One row
/// per `WorkspaceInnerTab` — the focused tab gets the accent indicator
/// underneath. Click a tab to focus it, click its `×` to close it (when
/// more than one tab exists). The `+` button appends a fresh tab.
///
/// Tab focus / close / add all flow through NotificationCenter (the
/// same pattern as `WorkspaceTabBar` and the sidebar toggle) so we
/// don't have to thread per-row callbacks through six layers of split
/// views and hosting controllers.
struct InnerTabStrip: View {
    let theme: ThemeSpec
    let tabs: [WorkspaceInnerTab]
    let focusedID: TabID

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(tabs) { tab in
                        InnerTabChip(
                            theme: theme,
                            tab: tab,
                            isActive: tab.id == focusedID,
                            canClose: tabs.count > 1
                        )
                        Hairline(theme: theme, axis: .vertical)
                    }
                }
            }
            Spacer(minLength: 0)
            AddInnerTabButton(theme: theme)
        }
        .frame(height: 36)
        .background(Color(hex: theme.chrome.background.hex))
    }
}

private struct InnerTabChip: View {
    let theme: ThemeSpec
    let tab: WorkspaceInnerTab
    let isActive: Bool
    let canClose: Bool

    @State private var isHovered = false

    var body: some View {
        Button {
            NotificationCenter.default.post(
                name: .bentoFocusInnerTab,
                object: tab.id
            )
        } label: {
            HStack(spacing: BentoSpacing.xs) {
                // Tiny kind glyph so a user can scan terminal vs editor
                // tabs at a glance without reading the label. `›_` for
                // terminal (prompt-shaped), `✎` for editor.
                Text(kindGlyph)
                    .font(BentoType.mono(BentoType.body, weight: .semibold))
                    .foregroundStyle(Color(hex: isActive
                        ? theme.chrome.accent.hex
                        : theme.chrome.tertiaryText.hex))
                Text(tab.displayName)
                    .font(BentoType.chrome(12, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(Color(hex: isActive
                        ? theme.chrome.text.hex
                        : theme.chrome.dimText.hex))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if canClose {
                    Button {
                        NotificationCenter.default.post(
                            name: .bentoCloseInnerTab,
                            object: tab.id
                        )
                    } label: {
                        Text("×")
                            .font(BentoType.chrome(13, weight: .medium))
                            .foregroundStyle(Color(hex: theme.chrome.tertiaryText.hex))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                            .background(
                                RoundedRectangle(cornerRadius: BentoRadius.small, style: .continuous)
                                    .fill(Color(hex: theme.chrome.accentSoft.hex)
                                        .opacity(isHovered ? 1 : 0))
                            )
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                }
            }
            .padding(.horizontal, BentoSpacing.m)
            .frame(height: 36)
            .background(
                ZStack(alignment: .bottom) {
                    Color(hex: isActive
                        ? theme.chrome.elevated.hex
                        : theme.chrome.background.hex)
                    if isActive {
                        Color(hex: theme.chrome.accent.hex)
                            .frame(height: 2)
                    }
                }
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovered = $0 }
        .animation(BentoMotion.hover, value: isHovered)
        .animation(BentoMotion.hover, value: isActive)
    }

    /// `›_` reads as a tiny shell prompt; `✎` (pencil) reads as "editor".
    /// Both are single glyphs so the strip stays compact.
    private var kindGlyph: String {
        switch tab.kind {
        case .terminal: return "›_"
        case .editor: return "✎"
        }
    }
}

private struct AddInnerTabButton: View {
    let theme: ThemeSpec

    @State private var isHovered = false

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .bentoNewTab, object: nil)
        } label: {
            Text("+")
                .font(BentoType.chrome(15, weight: .medium))
                .foregroundStyle(Color(hex: isHovered
                    ? theme.chrome.text.hex
                    : theme.chrome.tertiaryText.hex))
                .frame(width: 36, height: 36)
                .background(
                    Color(hex: theme.chrome.accentSoft.hex).opacity(isHovered ? 1 : 0)
                )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovered = $0 }
        .help("New tab (⌘T)")
        .animation(BentoMotion.hover, value: isHovered)
    }
}

extension Notification.Name {
    static let bentoFocusInnerTab = Notification.Name("BentoFocusInnerTab")
    static let bentoCloseInnerTab = Notification.Name("BentoCloseInnerTab")
}

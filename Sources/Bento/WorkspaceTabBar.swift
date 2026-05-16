import AppKit
import BentoCore
import SwiftUI

/// Top-of-window tab strip. Each leaf in the pane graph becomes one tab —
/// no side-by-side splits, no squeezed panes. Click a tab to focus it.
///
/// The `+` on the right end adds a new tab (a fresh workspace leaf rooted
/// at the project's cwd). The `×` on each tab closes it; if it's the last
/// tab, the close is a no-op (graph never goes empty).
///
/// This is the same shape Warp / iTerm2 / Code use: tabs at the top, one
/// content area below. Active tab is highlighted with the accent bar; the
/// rest sit at panel color.
struct WorkspaceTabBar: View {
    let theme: ThemeSpec
    let tabs: [PaneDescriptor]
    let focusedID: PaneID
    let onSelect: (PaneID) -> Void
    let onClose: (PaneID) -> Void
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(tabs, id: \.id) { tab in
                        TabChip(
                            theme: theme,
                            label: label(for: tab),
                            isActive: tab.id == focusedID,
                            canClose: tabs.count > 1,
                            onSelect: { onSelect(tab.id) },
                            onClose: { onClose(tab.id) }
                        )
                        Hairline(theme: theme, axis: .vertical)
                    }
                }
            }
            Spacer(minLength: 0)
            AddTabButton(theme: theme, action: onAdd)
        }
        .frame(height: 36)
        .background(Color(hex: theme.chrome.background.hex))
        .overlay(alignment: .bottom) {
            Hairline(theme: theme)
        }
    }

    /// Produce a short tab label. Workspaces prefer the cwd's last folder
    /// component (more contextual than "workspace"); other kinds use the
    /// pane's own name.
    private func label(for pane: PaneDescriptor) -> String {
        if let ws = pane.workspace {
            let path = ws.currentCwd
            let name = URL(fileURLWithPath: path).lastPathComponent
            return name.isEmpty ? "workspace" : name
        }
        return pane.name
    }
}

private struct TabChip: View {
    let theme: ThemeSpec
    let label: String
    let isActive: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: BentoSpacing.s) {
                Text(label)
                    .font(BentoType.chrome(12, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(Color(hex: isActive
                        ? theme.chrome.text.hex
                        : theme.chrome.dimText.hex))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if canClose {
                    Button(action: onClose) {
                        Text("×")
                            .font(BentoType.chrome(13, weight: .medium))
                            .foregroundStyle(Color(hex: theme.chrome.tertiaryText.hex))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                            .background(
                                RoundedRectangle(cornerRadius: BentoRadius.small, style: .continuous)
                                    .fill(Color(hex: theme.chrome.accentSoft.hex).opacity(isHovered ? 1 : 0))
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
}

private struct AddTabButton: View {
    let theme: ThemeSpec
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
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
        .animation(BentoMotion.hover, value: isHovered)
    }
}

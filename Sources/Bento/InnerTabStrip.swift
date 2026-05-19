import AppKit
import BentoCore
import SwiftUI

/// Inner tab strip rendered above a workspace's terminal area. One row
/// per `WorkspaceInnerTab` — the focused tab gets the accent indicator
/// underneath. Click a tab to focus it, double-click to rename it
/// inline, click its `×` to close it (when more than one tab exists).
/// The `+` button appends a fresh tab.
///
/// Tab focus / close / add / rename all flow through NotificationCenter
/// (the same pattern as `WorkspaceTabBar` and the sidebar toggle) so we
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
    @State private var isEditing = false
    @State private var draft: String = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            ZStack(alignment: .bottom) {
                Color(hex: isActive
                    ? theme.chrome.elevated.hex
                    : theme.chrome.background.hex)
                if isActive {
                    Color(hex: theme.chrome.accent.hex)
                        .frame(height: 2)
                }
            }

            HStack(spacing: BentoSpacing.xs) {
                // Tiny kind glyph so a user can scan terminal vs editor
                // tabs at a glance without reading the label. `›_` for
                // terminal (prompt-shaped), `✎` for editor.
                Text(kindGlyph)
                    .font(BentoType.mono(BentoType.body, weight: .semibold))
                    .foregroundStyle(Color(hex: isActive
                        ? theme.chrome.accent.hex
                        : theme.chrome.tertiaryText.hex))
                if isEditing {
                    inlineEditor
                } else {
                    Text(tab.displayName)
                        .font(BentoType.chrome(12, weight: isActive ? .semibold : .medium))
                        .foregroundStyle(Color(hex: isActive
                            ? theme.chrome.text.hex
                            : theme.chrome.dimText.hex))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
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
        }
        .frame(height: 36)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            draft = tab.displayName
            isEditing = true
            DispatchQueue.main.async { isFieldFocused = true }
        }
        .onTapGesture {
            if !isEditing {
                NotificationCenter.default.post(
                    name: .bentoFocusInnerTab,
                    object: tab.id
                )
            }
        }
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

    private var inlineEditor: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .focused($isFieldFocused)
            .font(BentoType.chrome(12, weight: isActive ? .semibold : .medium))
            .foregroundStyle(Color(hex: theme.chrome.text.hex))
            .frame(minWidth: 60)
            .onSubmit(commit)
            .onExitCommand(perform: cancel)
            .onChange(of: isFieldFocused) { _, focused in
                if !focused, isEditing { commit() }
            }
    }

    private func commit() {
        NotificationCenter.default.post(
            name: .bentoRenameInnerTab,
            object: InnerTabRename(id: tab.id, name: draft)
        )
        isEditing = false
        isFieldFocused = false
    }

    private func cancel() {
        isEditing = false
        isFieldFocused = false
        draft = tab.displayName
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

/// Payload for `.bentoRenameInnerTab` notifications. Notifications use
/// `Any?` for their object, so we need a typed wrapper to carry both
/// the tab id and the new name in one hop.
struct InnerTabRename: Equatable {
    let id: TabID
    let name: String
}

extension Notification.Name {
    static let bentoFocusInnerTab = Notification.Name("BentoFocusInnerTab")
    static let bentoCloseInnerTab = Notification.Name("BentoCloseInnerTab")
    static let bentoRenameInnerTab = Notification.Name("BentoRenameInnerTab")
}

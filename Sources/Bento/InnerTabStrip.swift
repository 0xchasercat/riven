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
    /// SurfaceIDs whose editor buffers have unsaved changes. Passed
    /// down from the controller so each chip can render a "•" prefix
    /// when its tab contains any dirty editor surface.
    let dirtySurfaces: Set<SurfaceID>
    /// H-2: SurfaceIDs whose backing file vanished underneath the
    /// open buffer. Drives the "(missing)" suffix on the chip's
    /// displayName when the tab's focused editor surface is in the
    /// set.
    let vanishedSurfaces: Set<SurfaceID>

    init(
        theme: ThemeSpec,
        tabs: [WorkspaceInnerTab],
        focusedID: TabID,
        dirtySurfaces: Set<SurfaceID>,
        vanishedSurfaces: Set<SurfaceID> = []
    ) {
        self.theme = theme
        self.tabs = tabs
        self.focusedID = focusedID
        self.dirtySurfaces = dirtySurfaces
        self.vanishedSurfaces = vanishedSurfaces
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(tabs) { tab in
                        InnerTabChip(
                            theme: theme,
                            tab: tab,
                            isActive: tab.id == focusedID,
                            canClose: tabs.count > 1,
                            isDirty: tab.surfaces.contains(where: { dirtySurfaces.contains($0.id) }),
                            isVanished: tab.surfaces.contains(where: { vanishedSurfaces.contains($0.id) })
                        )
                        Hairline(theme: theme, axis: .vertical)
                    }
                }
            }
            Spacer(minLength: 0)
            SplitSurfaceButton(theme: theme)
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
    let isDirty: Bool
    /// H-2: when true the chip appends " (missing)" to the
    /// displayName so the strip surfaces the deleted-under-the-editor
    /// state without needing a banner. The tab is still
    /// closeable / focusable — this is a label-only treatment.
    var isVanished: Bool = false

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
                // Unsaved-changes dot. Tucks between the kind glyph
                // and the label, in accent color, so it reads as a
                // status marker rather than typography. Hidden (zero
                // frame) when clean to keep the row width identical
                // between dirty / clean states — chips don't shift
                // horizontally just because someone typed in another
                // tab.
                if isDirty {
                    Circle()
                        .fill(Color(hex: theme.chrome.accent.hex))
                        .frame(width: 6, height: 6)
                        .accessibilityLabel("Unsaved changes")
                }
                if isEditing {
                    inlineEditor
                } else {
                    Text(displayLabel)
                        .font(BentoType.chrome(12, weight: isActive ? .semibold : .medium))
                        .foregroundStyle(Color(hex: labelHex))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                // Pencil-icon rename affordance (hover-only). Replaces
                // the prior double-click-to-rename pattern, which
                // delayed every single-tap on this chip — including
                // the close × — by ~250ms while SwiftUI waited to
                // see if a double-tap was forming. Discoverable AND
                // responsive.
                if !isEditing && isHovered {
                    Button(action: beginRename) {
                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color(hex: theme.chrome.tertiaryText.hex))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help("Rename tab")
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

    private func beginRename() {
        draft = tab.displayName
        isEditing = true
        DispatchQueue.main.async { isFieldFocused = true }
    }

    /// `›_` reads as a tiny shell prompt; `✎` (pencil) reads as "editor".
    /// Both are single glyphs so the strip stays compact.
    private var kindGlyph: String {
        switch tab.kind {
        case .terminal: return "›_"
        case .editor: return "✎"
        }
    }

    /// Tab label with the H-2 "(missing)" suffix appended when the
    /// underlying editor file was deleted / renamed under us.
    private var displayLabel: String {
        isVanished ? "\(tab.displayName) (missing)" : tab.displayName
    }

    /// Active = the standard text colour; vanished = the warning
    /// tone (matches the editor toolbar treatment); otherwise the
    /// usual dim text.
    private var labelHex: String {
        if isVanished { return theme.chrome.warning.hex }
        return isActive ? theme.chrome.text.hex : theme.chrome.dimText.hex
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

/// `[][]` button next to `+` in the inner tab strip. Click splits the
/// currently-focused surface in its tab to the right (matching Cmd+D);
/// long-press / Option-click would split down (Cmd+Shift+D — wired
/// through the menu for now, not the button, to keep the chrome
/// simple). Posts `.bentoSplitFocusedSurface(.right)`.
private struct SplitSurfaceButton: View {
    let theme: ThemeSpec

    @State private var isHovered = false

    var body: some View {
        Button {
            NotificationCenter.default.post(
                name: .bentoSplitFocusedSurface,
                object: SplitDirection.right
            )
        } label: {
            // `[][]` glyph reads as "two side-by-side panes". Drawn as
            // two narrow rectangles with a 1pt gap so the icon scales
            // cleanly at the inner tab strip's 36pt height.
            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .stroke(Color(hex: isHovered
                        ? theme.chrome.text.hex
                        : theme.chrome.tertiaryText.hex), lineWidth: 1.2)
                    .frame(width: 7, height: 13)
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .stroke(Color(hex: isHovered
                        ? theme.chrome.text.hex
                        : theme.chrome.tertiaryText.hex), lineWidth: 1.2)
                    .frame(width: 7, height: 13)
            }
            .frame(width: 36, height: 36)
            .background(
                Color(hex: theme.chrome.accentSoft.hex).opacity(isHovered ? 1 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovered = $0 }
        .help("Split focused surface right (⌘D · ⌘⇧D for vertical)")
        .animation(BentoMotion.hover, value: isHovered)
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

import AppKit
import BentoCore
import SwiftUI

/// Top-of-window tab strip. Each leaf in the pane graph becomes one tab —
/// no side-by-side splits, no squeezed panes. Click a tab to focus it,
/// double-click to rename it.
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
    let onRename: (PaneID, String) -> Void

    init(
        theme: ThemeSpec,
        tabs: [PaneDescriptor],
        focusedID: PaneID,
        onSelect: @escaping (PaneID) -> Void,
        onClose: @escaping (PaneID) -> Void,
        onAdd: @escaping () -> Void,
        onRename: @escaping (PaneID, String) -> Void = { _, _ in }
    ) {
        self.theme = theme
        self.tabs = tabs
        self.focusedID = focusedID
        self.onSelect = onSelect
        self.onClose = onClose
        self.onAdd = onAdd
        self.onRename = onRename
    }

    var body: some View {
        HStack(spacing: 0) {
            // Leave room for the macOS traffic-light buttons that sit
            // in the top-left of the window. ~78pt is enough for the
            // three buttons (close / minimize / fullscreen) at their
            // default geometry plus a small breathing-room gap before
            // the first tab. Without this the first tab would sit
            // under the traffic lights and be unreachable.
            Spacer().frame(width: 78)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(tabs, id: \.id) { tab in
                        TabChip(
                            theme: theme,
                            paneID: tab.id,
                            label: label(for: tab),
                            isActive: tab.id == focusedID,
                            canClose: tabs.count > 1,
                            onSelect: { onSelect(tab.id) },
                            onClose: { onClose(tab.id) },
                            onRename: { newName in onRename(tab.id, newName) }
                        )
                        Hairline(theme: theme, axis: .vertical)
                    }
                }
            }
            Spacer(minLength: 0)
            AddTabButton(theme: theme, action: onAdd)
        }
        // Slightly taller than before to comfortably absorb the
        // titlebar's vertical real estate (~28pt of which is the
        // macOS-reserved titlebar height). Tabs + close-× still
        // breathe at this height.
        .frame(height: 52)
        // Solid `paneHeaderBg` tint sits on top of the theme-aware
        // vibrancy wrapped around the chrome strip in
        // `RootView.mainColumn` (H8). Mockup uses this exact slot for
        // every header bar, and a fully opaque cream / sumi reads
        // crisper than the old `elevated.opacity(0.92)` blend — which
        // washed Paper out to grey and let Carbon's dark vibrancy
        // bleed through too aggressively.
        .background(Color(hex: theme.chrome.paneHeaderBg.hex))
    }

    /// Produce a short tab label. Workspaces prefer the user-set
    /// `customName`, falling back to the cwd's last folder component
    /// (more contextual than "workspace"); other kinds use the pane's
    /// own name.
    private func label(for pane: PaneDescriptor) -> String {
        if let ws = pane.workspace {
            if let custom = ws.customName, !custom.isEmpty { return custom }
            let path = ws.currentCwd
            let name = URL(fileURLWithPath: path).lastPathComponent
            return name.isEmpty ? "workspace" : name
        }
        return pane.name
    }
}

/// One chip in the workspace tab bar. Single-click selects, double-click
/// drops the label into an inline `TextField` so the user can rename
/// in-place. Enter commits via `onRename`; Escape cancels.
private struct TabChip: View {
    let theme: ThemeSpec
    let paneID: PaneID
    let label: String
    let isActive: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: (String) -> Void

    @State private var isHovered = false
    @State private var isEditing = false
    @State private var draft: String = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            // Background + accent indicator. Same shape whether editing
            // or not, so the chip dimensions don't jump when the user
            // clicks the pencil to rename.
            ZStack(alignment: .bottom) {
                // Active tab gets a fully opaque elevated tint so it
                // anchors against the vibrancy behind the tab bar; inactive
                // tabs let the vibrancy through with a soft tint so the
                // bar still reads as a panel rather than a window cutout.
                Color(hex: isActive
                    ? theme.chrome.elevated.hex
                    : theme.chrome.background.hex)
                    .opacity(isActive ? 1.0 : 0.0)
                if isActive {
                    // Accent bar stays at full opacity so it remains the
                    // strongest cue on the strip, even with vibrancy
                    // active behind it.
                    Color(hex: theme.chrome.accent.hex)
                        .opacity(1.0)
                        .frame(height: 2)
                }
            }

            HStack(spacing: BentoSpacing.s) {
                if isEditing {
                    inlineEditor
                } else {
                    // H-8: pre-truncate workspace tab labels too so a
                    // workspace rooted at a long path doesn't run the
                    // tab off the strip. Full label sits in the
                    // tooltip so the user can still confirm which
                    // workspace is which without expanding the chip.
                    Text(label.middleEllipsized())
                        .font(BentoType.chrome(13, weight: isActive ? .semibold : .medium))
                        .foregroundStyle(Color(hex: isActive
                            ? theme.chrome.text.hex
                            : theme.chrome.dimText.hex))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(label)
                }
                // Pencil-icon edit affordance. Hover-only so the chip
                // stays clean in the resting state; clicking switches
                // the label into the inline TextField. Previously
                // rename was double-click on the chip, but the
                // .onTapGesture(count: 2) made single-clicks on the
                // close × wait for a double-tap timeout (~250ms),
                // which read as the whole close button being sluggish.
                // Pencil + a Button gesture sidesteps both problems.
                if !isEditing && isHovered {
                    Button(action: beginRename) {
                        Image(systemName: "pencil")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(hex: theme.chrome.tertiaryText.hex))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help("Rename tab")
                    .accessibilityLabel("Rename workspace tab \(label)")
                }
                if canClose {
                    Button(action: onClose) {
                        Text("×")
                            .font(BentoType.chrome(14, weight: .medium))
                            .foregroundStyle(Color(hex: theme.chrome.tertiaryText.hex))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                            .background(
                                RoundedRectangle(cornerRadius: BentoRadius.small, style: .continuous)
                                    .fill(Color(hex: theme.chrome.accentSoft.hex).opacity(isHovered ? 1 : 0))
                            )
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help("Close workspace \u{00B7} \u{2318}W")
                    .accessibilityLabel("Close workspace \(label)")
                    .accessibilityHint("Command-W. Prompts to save unsaved editor changes first.")
                }
            }
            .padding(.horizontal, BentoSpacing.l)
        }
        .frame(height: 52)
        .contentShape(Rectangle())
        // Single-tap → focus the tab. No `count: 2` gesture anywhere
        // on the chip — that introduced a 250ms double-tap-detection
        // delay on every single tap (including the close × Button),
        // making the whole strip feel sluggish.
        .onTapGesture {
            if !isEditing { onSelect() }
        }
        .onHover { isHovered = $0 }
        .animation(BentoMotion.hover, value: isHovered)
        .animation(BentoMotion.hover, value: isActive)
    }

    private func beginRename() {
        draft = label
        isEditing = true
        DispatchQueue.main.async { isFieldFocused = true }
    }

    private var inlineEditor: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .focused($isFieldFocused)
            .font(BentoType.chrome(13, weight: isActive ? .semibold : .medium))
            .foregroundStyle(Color(hex: theme.chrome.text.hex))
            .frame(minWidth: 80)
            .onSubmit(commit)
            .onExitCommand(perform: cancel)
            .onChange(of: isFieldFocused) { _, focused in
                // Focus loss commits — matches the user's mental model
                // of "click elsewhere to keep what I typed".
                if !focused, isEditing { commit() }
            }
    }

    private func commit() {
        onRename(draft)
        isEditing = false
        isFieldFocused = false
    }

    private func cancel() {
        isEditing = false
        isFieldFocused = false
        draft = label
    }
}

private struct AddTabButton: View {
    let theme: ThemeSpec
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text("+")
                .font(BentoType.chrome(17, weight: .medium))
                .foregroundStyle(Color(hex: isHovered
                    ? theme.chrome.text.hex
                    : theme.chrome.tertiaryText.hex))
                .frame(width: 52, height: 52)
                .background(
                    Color(hex: theme.chrome.accentSoft.hex).opacity(isHovered ? 1 : 0)
                )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovered = $0 }
        .help("New workspace \u{00B7} \u{2318}N")
        // H-14: VoiceOver reads "+" literally — replace with the
        // semantic label + shortcut.
        .accessibilityLabel("New workspace")
        .accessibilityHint("Command-N. Adds a new workspace tab.")
        .animation(BentoMotion.hover, value: isHovered)
    }
}

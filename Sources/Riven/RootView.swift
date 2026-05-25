import AppKit
import RivenCore
import SwiftUI

struct RivenRootView: View {
    @EnvironmentObject private var controller: RivenRootController
    @State private var selectedThemeID: String?
    @State private var activeOverlay: Overlay?
    @State private var paletteQuery = ""
    @State private var searchQuery = ""
    /// `true` when the user opened the picker via the menu / palette /
    /// status-bar swatch (vs. the first-run flow where the picker is
    /// modal and esc-dismiss is disabled).
    @State private var themePickerDismissible: Bool = false
    @State private var themePickerVisible: Bool = false
    /// Projects whose trust prompt we've already auto-shown in *this
    /// session*. Keyed by `projectRoot` so opening a different project
    /// (or restarting the app) still triggers exactly one auto-show.
    /// Set when the prompt opens; never cleared. The user can dismiss
    /// and the toolbar pill remains as the always-available re-entry.
    @State private var autoPromptedTrustForProjects: Set<String> = []
    /// Live draft of the toolbar's workspace-path field. Re-synced to
    /// the focused workspace's `initialCwd` via `.onChange(of:)`, so
    /// switching workspaces (or new-workspace) flips the field's
    /// contents to match — no stale path from a previous workspace.
    @State private var workspacePathDraft: String = ""
    /// `true` immediately after a failed commit; the toolbar shows a
    /// 1-line "path doesn't exist" hint for ~3s. Cleared on next edit.
    @State private var workspacePathRejected: Bool = false

    private var theme: ThemeSpec {
        let id = selectedThemeID ?? controller.state.selectedThemeID
        return ThemeSpec.theme(id: id) ?? ThemeSpec.builtIns[0]
    }

    var body: some View {
        ZStack {
            mainColumn
                // Extend the chrome into the OS titlebar area. The
                // window's `fullSizeContentView` style mask + a 78pt
                // leading spacer on WorkspaceTabBar make this safe;
                // the traffic-light buttons stay clickable in the
                // reserved corner.
                .ignoresSafeArea(.container, edges: .top)
            // Two entry points share the same overlay:
            //   • first-run (no explicit selection yet) — modal,
            //     blocks until the user picks a theme.
            //   • Preferences → Theme… menu, the palette's "Pick
            //     theme…" command, and the status-bar swatch's
            //     "more" entry all flip `themePickerVisible` and
            //     `themePickerDismissible = true` so esc / Done /
            //     backdrop click each dismiss without forcing a
            //     choice.
            if !controller.preference.hasExplicitSelection {
                ThemePicker(
                    theme: theme,
                    onSelect: { id in
                        controller.selectTheme(id: id)
                        selectedThemeID = id
                    },
                    dismissible: false
                )
            } else if themePickerVisible {
                ThemePicker(
                    theme: theme,
                    onSelect: { id in
                        controller.selectTheme(id: id)
                        selectedThemeID = id
                    },
                    dismissible: themePickerDismissible,
                    onClose: {
                        themePickerVisible = false
                    }
                )
            }
            if let activeOverlay {
                overlay(activeOverlay)
            }
        }
        .background(Color(hex: theme.chrome.background.hex))
        .foregroundStyle(Color(hex: theme.chrome.text.hex))
        .modifier(NotificationWiring(
            onPalette: { activeOverlay = .palette; paletteQuery = "" },
            onSearch: { activeOverlay = .search; searchQuery = "" },
            onShowThemePicker: { showThemePicker() },
            onShortcuts: { activeOverlay = .shortcuts },
            onNewTab: { controller.openNewInnerTab() },
            onNewWorkspace: { controller.openNewWorkspace() },
            onOpenProject: { presentOpenProjectPicker() },
            onCloseTab: { controller.closeTab(controller.state.paneGraph.focusedPaneID) },
            onCloseEditor: { controller.closeFocusedEditor() },
            onToggleSidebar: { controller.toggleFocusedSidebar() },
            onClearTerminal: { controller.clearFocusedTerminal() },
            onFocusInnerTab: { controller.focusInnerTab($0) },
            onCloseInnerTab: { controller.closeInnerTab($0) },
            onRenameInnerTab: { rename in
                controller.renameInnerTab(rename.id, to: rename.name)
            },
            onSplitSurface: { direction in
                controller.splitFocusedSurface(direction: direction)
            },
            onFocusSurface: { focus in
                controller.focusSurface(tabID: focus.tabID, surfaceID: focus.surfaceID)
            },
            onCloseSurface: { focus in
                controller.closeSurface(tabID: focus.tabID, surfaceID: focus.surfaceID)
            },
            onCycleSurfaceFocus: { controller.cycleFocusedTabSurface() },
            onEditorDirtyChanged: { change in
                controller.setSurfaceDirty(change.surfaceID, dirty: change.isDirty)
            },
            onEditorFileVanished: { surfaceID in
                controller.markSurfaceVanished(surfaceID)
            },
            onEditorFileRestored: { surfaceID in
                controller.clearSurfaceVanished(surfaceID)
            },
            onCommandSubmitted: { text in
                controller.recordCommandSubmission(text)
            },
            onCommandHistoryRequest: { request in
                switch request.direction {
                case .previous:
                    request.response.text = controller.recallPreviousCommand(
                        currentBuffer: request.currentBuffer
                    )
                case .next:
                    request.response.text = controller.recallNextCommand(
                        currentBuffer: request.currentBuffer
                    )
                }
            }
        ))
        // Auto-open the trust prompt the first time we see a project
        // that requires trust this session. The toolbar pill remains as
        // the re-entry point if the user dismisses.
        .onChange(of: trustPromptTrigger) { _, trigger in
            maybeAutoShowTrust(for: trigger)
        }
        // Also handle the first-render case: openProject may complete
        // before any user interaction, so SwiftUI doesn't fire the
        // .onChange above. Mirror the same gate here.
        .task(id: trustPromptTrigger) {
            maybeAutoShowTrust(for: trustPromptTrigger)
        }
        // H-6: surface project-fallback notices through the unified
        // banner pipe instead of a bespoke strip. The controller
        // sets `projectFallbackReason` when `openProject` falls back
        // to `~`; we mirror it into the toast layer (sticky — nil
        // auto-dismiss — so the user reads it before it vanishes)
        // and clear the source field so we don't double-surface on
        // a subsequent re-render.
        .onChange(of: controller.state.projectFallbackReason) { _, reason in
            if let reason {
                controller.showBanner(reason, kind: .warning, autoDismissAfter: nil)
                controller.dismissProjectFallbackReason()
            }
        }
        .task(id: controller.state.projectFallbackReason) {
            if let reason = controller.state.projectFallbackReason {
                controller.showBanner(reason, kind: .warning, autoDismissAfter: nil)
                controller.dismissProjectFallbackReason()
            }
        }
    }

    private var mainColumn: some View {
        // Pull the whole chrome up so the WorkspaceTabBar fills the
        // titlebar area (the window already has
        // `titlebarAppearsTransparent + .fullSizeContentView` set in
        // RivenApp). Without this the OS-reserved titlebar height
        // (~28pt) read as dead empty space above the tab bar.
        // WorkspaceTabBar reserves a 78pt leading spacer for the
        // traffic-light buttons so they remain clickable.
        VStack(spacing: 0) {
            // H8: WorkspaceTabBar + toolbar share a single
            // NSVisualEffectView background so the translucent title bar
            // (set in RivenApp via `titlebarAppearsTransparent` +
            // `.fullSizeContentView`) bleeds downward through both. The
            // result is one continuous chrome panel from title bar →
            // tab strip → toolbar → hairline → pane content.
            //
            // `.windowBackground` matches the title bar's resting tint
            // (so there's no visible seam at y=titlebarHeight), and
            // `.behindWindow` blends with whatever sits behind the window
            // rather than the next sibling layer, giving the "frosted
            // glass" look macOS users expect from native chrome.
            //
            // The vibrancy lives as a `.background()` modifier — NOT a
            // sibling ZStack. `NSViewRepresentable` has no intrinsic
            // size, so a sibling would stretch to fill the outer VStack
            // and crush the tab bar into a thin strip at the bottom of
            // a huge dead zone. `.background()` constrains the vibrancy
            // to exactly the natural size of the chrome strip (tab bar
            // + toolbar = 76pt), which is what we want.
            VStack(spacing: 0) {
                WorkspaceTabBar(
                    theme: theme,
                    tabs: controller.state.paneGraph.leaves(),
                    focusedID: controller.state.paneGraph.focusedPaneID,
                    onSelect: { controller.focusTab($0) },
                    onClose: { controller.closeTab($0) },
                    onAdd: { controller.openNewWorkspace() },
                    onRename: { id, name in controller.renameWorkspace(paneID: id, to: name) }
                )
                toolbar
            }
            .background(
                // Pick the vibrancy material from the active theme.
                // Dark themes ship `.headerView` (toolbar/titlebar
                // surface — much less translucent than
                // `.windowBackground`, which made the chrome read as
                // one washed-out grey strip against the dark Riven
                // themes). Paper ships `.titlebar` so the cream
                // chrome stays light and warm rather than picking up
                // the system's window-background tint. The chrome's
                // own elevated tint sits on top via
                // `WorkspaceTabBar.background` so the panel still
                // feels like a proper surface, with just enough
                // vibrancy under it to anchor against the titlebar.
                VibrancyBackground(theme: theme, blendingMode: .behindWindow)
            )
            // Single hairline at the bottom marks the seam between the
            // vibrant chrome and the opaque pane grid below.
            .overlay(alignment: .bottom) {
                Hairline(theme: theme)
            }
            // H-6: app-wide toast band. Single slot above the pane
            // grid; calling `showBanner` replaces whatever was here.
            // The H-3 project-fallback strip used to live here as a
            // bespoke component — it now flows through this same
            // pipe with `kind: .warning` and `autoDismissAfter: nil`
            // (sticky until the user clicks ×).
            if let banner = controller.currentBanner {
                RivenBannerHost(
                    theme: theme,
                    state: banner,
                    onDismiss: { controller.dismissBanner() }
                )
                .animation(RivenMotion.standard, value: banner.id)
            }
            PaneGridView(
                theme: theme,
                paneGraph: controller.state.paneGraph,
                projectRoot: controller.state.projectRoot,
                fileMap: controller.fileMap,
                submitMode: controller.submitsOnEnter ? .enterSubmits : .enterIsNewline,
                dirtySurfaces: controller.dirtyEditorSurfaces,
                vanishedSurfaces: controller.vanishedFileSurfaces,
                scrollback: controller.scrollback,
                onGraphChange: { controller.recordPaneGraph($0) },
                onOpenFile: { controller.openFile($0) },
                onCwdChanged: { paneID, cwd in
                    controller.updateWorkspaceCwd(paneID: paneID, cwd: cwd)
                }
            )
            // #40 follow-up: opening a scratch editor inner tab used
            // to grow the mainColumn past the viewport (status bar
            // pushed off-screen) because the editor's STTextView
            // intrinsic content height leaked up through SwiftUI's
            // VStack sizing — even with `.frame(maxHeight: .infinity)`
            // on EditorTabContent itself, the VStack still needed a
            // sibling claiming the slack to anchor against. Pinning
            // PaneGridView to maxHeight: .infinity tells the outer
            // VStack "the pane area takes whatever's left after the
            // chrome strip + banner + status bar," and the layout
            // stays inside the window even when a brand-new scratch
            // tab is doing its first layout pass.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            statusBar
        }
    }

    /// Open the dismissible theme picker. Called by the
    /// `.rivenShowThemePicker` notification (menu + palette + swatch
    /// "more" affordance). First-run picker is handled inline in the
    /// view body and uses `dismissible: false` — this entry is for
    /// users who already have an explicit selection but want to change
    /// it without restarting.
    private func showThemePicker() {
        themePickerDismissible = true
        themePickerVisible = true
        // If another overlay is open, close it first — the picker is
        // its own modal layer and stacking two overlays would dim
        // twice.
        activeOverlay = nil
    }

    private func maybeAutoShowTrust(for trigger: TrustPromptTrigger) {
        guard
            trigger.requires,
            !trigger.root.isEmpty,
            !autoPromptedTrustForProjects.contains(trigger.root),
            activeOverlay == nil
        else { return }
        autoPromptedTrustForProjects.insert(trigger.root)
        activeOverlay = .trust
    }

    /// Composite key tracking "does this project still need trust?". Used
    /// as both the `onChange` value AND the `task(id:)` key so we react
    /// to (a) the controller landing a fresh project state, and (b) the
    /// `requiresTaskTrust` flag flipping true asynchronously after open.
    private var trustPromptTrigger: TrustPromptTrigger {
        TrustPromptTrigger(
            root: controller.state.projectRoot,
            requires: controller.state.requiresTaskTrust
        )
    }

    private struct TrustPromptTrigger: Equatable, Hashable {
        let root: String
        let requires: Bool
    }

    /// The focused workspace's live pwd — what the toolbar input
    /// displays. Updated by OSC 7 from any of the workspace's
    /// terminal surfaces, so `cd` in the shell flows back into the
    /// toolbar automatically. Falls back to the project root when no
    /// workspace is focused (defensive; shouldn't happen).
    private var focusedWorkspaceCwd: String {
        controller.state.paneGraph
            .pane(controller.state.paneGraph.focusedPaneID)?
            .workspace?.currentCwd
            ?? controller.state.projectRoot
    }

    private var toolbar: some View {
        HStack(spacing: RivenSpacing.s) {
            workspacePathField
            Spacer()
            if controller.state.restoredFromSnapshot {
                Text("session restored")
                    .foregroundStyle(Color(hex: theme.chrome.activeBorder.hex))
            }
            if controller.state.requiresTaskTrust {
                Button {
                    activeOverlay = .trust
                } label: {
                    Text("\(controller.state.pendingTaskCommands.count) task panes pending trust")
                        .foregroundStyle(Color(hex: theme.chrome.activeBorder.hex))
                        .underline()
                }
                .buttonStyle(.plain)
            }
            if workspacePathRejected {
                Text("path doesn't exist")
                    .foregroundStyle(Color(hex: theme.chrome.activeBorder.hex))
            }
            Text("⌘⇧P palette · ⌘K clear · ⌘T new tab · ⌘N new workspace")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
        }
        .padding(.horizontal, 16)
        .frame(height: 32)
        // Solid `paneHeaderBg` tint over the shared vibrancy underlay
        // so the toolbar and the tab bar read as one continuous
        // header panel — see WorkspaceTabBar's matching background.
        .background(Color(hex: theme.chrome.paneHeaderBg.hex))
        .onAppear {
            // Seed the draft on first render so the field shows the
            // focused workspace's path, not an empty string.
            if workspacePathDraft.isEmpty {
                workspacePathDraft = focusedWorkspaceCwd
            }
        }
        .onChange(of: focusedWorkspaceCwd) { _, new in
            // Re-sync when the focused workspace changes (Cmd+N, click
            // another tab, etc.) so the field never shows a stale path.
            workspacePathDraft = new
            workspacePathRejected = false
        }
    }

    private var workspacePathField: some View {
        TextField("", text: $workspacePathDraft, onCommit: commitWorkspacePath)
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(Color(hex: workspacePathRejected
                ? theme.chrome.activeBorder.hex
                : theme.chrome.text.hex))
            .frame(maxWidth: 460, alignment: .leading)
            .help("Workspace path · enter to rebind sidebar, ⎋ to cancel")
            .onSubmit(commitWorkspacePath)
            .onExitCommand {
                // Escape: revert to current cwd, drop focus.
                workspacePathDraft = focusedWorkspaceCwd
                workspacePathRejected = false
            }
            .onChange(of: workspacePathDraft) { _, _ in
                // Any keystroke clears the rejection hint.
                if workspacePathRejected { workspacePathRejected = false }
            }
    }

    /// Send the typed path as a `cd` into the focused terminal. The
    /// shell does the actual navigation and emits OSC 7 → the
    /// workspace's `currentCwd` updates → the sidebar follows. We
    /// don't mutate the workspace model directly here, so the path
    /// field is genuinely a convenience indicator that mirrors what
    /// the shell is doing, not a workspace-pinning binding.
    ///
    /// On rejection (path doesn't exist or focus is on an editor
    /// tab), flip the rejected flag so the toolbar shows the hint
    /// for ~3s, then auto-clear.
    private func commitWorkspacePath() {
        let ok = controller.changeFocusedShellPwd(workspacePathDraft)
        if !ok {
            workspacePathRejected = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                workspacePathRejected = false
            }
        }
    }

    @ViewBuilder
    private func overlay(_ overlay: Overlay) -> some View {
        switch overlay {
        case .palette:
            CommandPaletteOverlay(
                theme: theme,
                query: $paletteQuery,
                commands: CommandPalette(commands: Command.rivenBuiltIns).search(paletteQuery),
                onSelect: { dispatch($0) },
                onClose: { activeOverlay = nil }
            )
        case .search:
            SearchOverlay(
                theme: theme,
                query: $searchQuery,
                search: { query, scope in
                    try await controller.search(query, scope: scope)
                },
                onOpenFile: { url in
                    activeOverlay = nil
                    controller.openFile(url)
                },
                onPeekScrollback: { match, _ in
                    activeOverlay = nil
                    controller.openScrollbackPeek(
                        paneID: match.paneID,
                        focusLine: match.lineNumber
                    )
                },
                onClose: { activeOverlay = nil }
            )
        case .trust:
            TrustPromptOverlay(
                theme: theme,
                projectRoot: controller.state.projectRoot,
                pendingCommands: controller.state.pendingTaskCommands,
                onTrust: {
                    controller.trustCurrentProject()
                    activeOverlay = nil
                },
                onDismiss: { activeOverlay = nil }
            )
        case .shortcuts:
            ShortcutsCheatsheetOverlay(
                theme: theme,
                onClose: { activeOverlay = nil }
            )
        }
    }

    private func dispatch(_ action: CommandAction) {
        switch action {
        case .splitRight:
            // Splits came back with #23 — palette now routes through
            // the same surface-tree path as Cmd+D + the [][] button.
            // (Pre-#23 this fell back to `openNewTab` because the old
            // pane-graph splits had been gutted; that stub leaked
            // through and made the palette's split commands create a
            // top-level tab instead of an actual within-tab split.)
            controller.splitFocusedSurface(direction: .right)
        case .splitDown:
            controller.splitFocusedSurface(direction: .down)
        case .closePane:
            controller.closeTab(controller.state.paneGraph.focusedPaneID)
        case .cycleFocus:
            // Cycle within-tab surface focus, matching Ctrl+Tab and
            // the menu's "Cycle Surface Focus" item. Previously
            // walked workspace-level panes via `graph.nextFocus()`,
            // which in our one-workspace-per-screen model just
            // shuffled tabs — not what the palette command
            // ("cycle focus") implies.
            controller.cycleFocusedTabSurface()
        case .cycleTheme:
            controller.cycleTheme()
            selectedThemeID = controller.state.selectedThemeID
        case .pickTheme:
            // Reuse the same overlay the first-run flow uses — keeps
            // the swatch grid in exactly one place. The dispatcher
            // chose `pickTheme` over inline-toggling so the picker
            // works regardless of which entry point fired (menu,
            // palette, swatch row).
            showThemePicker()
        case .showSearch:
            activeOverlay = .search
            searchQuery = ""
        case .openFile(let url):
            controller.openFile(url)
        case .openFilePicker:
            presentOpenFilePicker()
        case .openProjectPicker:
            presentOpenProjectPicker()
        case .showTrustPrompt:
            activeOverlay = .trust
        case .toggleSubmitOnEnter:
            controller.toggleSubmitsOnEnter()
        case .installShellIntegration:
            controller.installShellIntegration()
        case .uninstallShellIntegration:
            controller.uninstallShellIntegration()
        }
    }

    /// Run an `NSOpenPanel` and forward the chosen URL to the controller.
    /// Used by the palette's "Open file…" command.
    private func presentOpenFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: controller.state.projectRoot)
        if panel.runModal() == .OK, let url = panel.url {
            controller.openFile(url)
        }
    }

    /// Run an `NSOpenPanel` constrained to a single directory and append
    /// it as a new workspace tab. Used by both the palette ("Open
    /// project…") and the Cmd+Shift+O menu item.
    private func presentOpenProjectPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Project"
        panel.directoryURL = URL(fileURLWithPath: controller.state.projectRoot)
            .deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            controller.openNewWorkspace(at: url.path)
        }
    }

    private var statusBar: some View {
        // Status bar uses the dedicated `statusBg` / `statusText`
        // tokens (one notch off the canvas background — Riven ships
        // a near-black band; Paper a warm-cream one slightly darker
        // than the editor canvas). Matches `mockup/workspace.jsx`'s
        // `StatusBar` component.
        HStack(spacing: 14) {
            Text(URL(fileURLWithPath: controller.state.projectRoot).lastPathComponent)
            Text("\(controller.state.paneGraph.leaves().count) tab\(controller.state.paneGraph.leaves().count == 1 ? "" : "s")")
            Text("theme: \(theme.name)")
            Spacer()
            ScratchEditorButton(theme: theme) { controller.openScratchEditor() }
            // T-5: live theme swatch. One dot per builtin tinted with
            // that theme's `chrome.accent`; clicking persists +
            // re-renders chrome immediately. The currently-active
            // theme gets a hairline border so users can tell which
            // one's live without reading the "theme: X" label.
            ThemeSwatchRow(
                theme: theme,
                activeID: controller.state.selectedThemeID,
                onSelect: { id in
                    controller.selectTheme(id: id)
                    selectedThemeID = id
                },
                onMore: { showThemePicker() }
            )
            Text("0 telemetry")
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(Color(hex: theme.chrome.statusText.hex))
        .padding(.horizontal, 12)
        .frame(height: 22)
        .background(Color(hex: theme.chrome.statusBg.hex))
        .overlay(alignment: .top) {
            // Hairline seam between pane grid and status bar matches
            // the mockup's `borderTop: 1px solid theme.border`.
            Hairline(theme: theme)
        }
    }
}

/// Compact theme switcher in the status bar. Renders one circular
/// swatch per builtin (colored with that theme's `chrome.accent`)
/// followed by a small `…` chip that opens the full picker for users
/// who want to see the previews or who have user-authored custom
/// themes installed.
private struct ThemeSwatchRow: View {
    let theme: ThemeSpec
    let activeID: String
    let onSelect: (String) -> Void
    let onMore: () -> Void

    @State private var hoveredID: String?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ThemeSpec.builtIns, id: \.id) { option in
                Button {
                    onSelect(option.id)
                } label: {
                    swatch(for: option)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Switch to \(option.name)")
                .onHover { hovering in
                    hoveredID = hovering ? option.id : (hoveredID == option.id ? nil : hoveredID)
                }
            }
            Button(action: onMore) {
                Text("…")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(hex: theme.chrome.tertiaryText.hex))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Open theme picker")
        }
    }

    private func swatch(for option: ThemeSpec) -> some View {
        let isActive = option.id == activeID
        let isHovered = hoveredID == option.id
        // Active swatch is slightly bigger + carries a hairline ring;
        // hover swatch animates the same ring at the accent color so
        // the affordance is obvious without a label.
        let outerSize: CGFloat = isActive ? 12 : 10
        return ZStack {
            Circle()
                .fill(Color(hex: option.chrome.accent.hex))
                .frame(width: outerSize, height: outerSize)
            Circle()
                .strokeBorder(
                    isActive
                        ? Color(hex: theme.chrome.text.hex)
                        : (isHovered
                            ? Color(hex: theme.chrome.text.hex).opacity(0.5)
                            : Color.clear),
                    lineWidth: isActive ? 1 : 0.75
                )
                .frame(width: outerSize + 4, height: outerSize + 4)
        }
        .frame(width: 16, height: 16)
        .contentShape(Rectangle())
        .animation(RivenMotion.hover, value: isActive)
        .animation(RivenMotion.hover, value: isHovered)
    }
}

/// One-line banner shown above the pane grid when `openProject` fell
/// back to `~` because the requested root was missing. Uses the theme's
/// `chrome.warning` slot at 0.2 opacity for the background so it reads
/// as an advisory rather than an error. The × dismisses locally — the
/// fallback cwd stays put either way.
private struct ProjectFallbackBanner: View {
    let theme: ThemeSpec
    let reason: String
    let onDismiss: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: RivenSpacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(hex: theme.chrome.warning.hex))
            Text(reason)
                .font(RivenType.mono(RivenType.small))
                .foregroundStyle(Color(hex: theme.chrome.text.hex))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: RivenSpacing.s)
            Button(action: onDismiss) {
                Text("×")
                    .font(RivenType.chrome(13, weight: .medium))
                    .foregroundStyle(Color(hex: isHovered
                        ? theme.chrome.text.hex
                        : theme.chrome.tertiaryText.hex))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .onHover { isHovered = $0 }
            .help("Dismiss")
        }
        .padding(.horizontal, RivenSpacing.m)
        .frame(height: 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: theme.chrome.warning.hex).opacity(0.2))
        .overlay(alignment: .bottom) { Hairline(theme: theme) }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Small chip-button in the status bar that opens an unsaved scratch
/// editor tab. Useful for a quick "let me write something" surface
/// without first creating a file on disk.
private struct ScratchEditorButton: View {
    let theme: ThemeSpec
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text("\u{270E}") // pencil — matches editor-tab glyph
                Text("scratch")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(Color(hex: isHovered
                ? theme.chrome.text.hex
                : theme.chrome.dimText.hex))
            .background(
                RoundedRectangle(cornerRadius: RivenRadius.small, style: .continuous)
                    .fill(Color(hex: theme.chrome.accentSoft.hex)
                        .opacity(isHovered ? 1 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovered = $0 }
        .help("Open a scratch editor tab (no file on disk)")
        .animation(RivenMotion.hover, value: isHovered)
    }
}

/// Collects all NotificationCenter wiring into a single ViewModifier so
/// `RivenRootView.body` stays under the SwiftUI type-checker's complexity
/// budget. Every callback hops back to `RivenRootView`'s closures so the
/// state mutations still live with the view that owns the `@State`.
private struct NotificationWiring: ViewModifier {
    let onPalette: () -> Void
    let onSearch: () -> Void
    let onShowThemePicker: () -> Void
    let onShortcuts: () -> Void
    let onNewTab: () -> Void
    let onNewWorkspace: () -> Void
    let onOpenProject: () -> Void
    let onCloseTab: () -> Void
    let onCloseEditor: () -> Void
    let onToggleSidebar: () -> Void
    let onClearTerminal: () -> Void
    let onFocusInnerTab: (TabID) -> Void
    let onCloseInnerTab: (TabID) -> Void
    let onRenameInnerTab: (InnerTabRename) -> Void
    let onSplitSurface: (SplitDirection) -> Void
    let onFocusSurface: (SurfaceFocus) -> Void
    let onCloseSurface: (SurfaceFocus) -> Void
    let onCycleSurfaceFocus: () -> Void
    let onEditorDirtyChanged: (EditorDirtyChange) -> Void
    let onEditorFileVanished: (SurfaceID) -> Void
    let onEditorFileRestored: (SurfaceID) -> Void
    let onCommandSubmitted: (String) -> Void
    let onCommandHistoryRequest: (CommandHistoryRequest) -> Void

    func body(content: Content) -> some View {
        content
            .modifier(SurfaceWiring(
                onSplitSurface: onSplitSurface,
                onFocusSurface: onFocusSurface,
                onCloseSurface: onCloseSurface,
                onCycleSurfaceFocus: onCycleSurfaceFocus,
                onEditorDirtyChanged: onEditorDirtyChanged,
                onEditorFileVanished: onEditorFileVanished,
                onEditorFileRestored: onEditorFileRestored,
                onCommandSubmitted: onCommandSubmitted,
                onCommandHistoryRequest: onCommandHistoryRequest
            ))
            .onReceive(NotificationCenter.default.publisher(for: .rivenShowCommandPalette)) { _ in onPalette() }
            .onReceive(NotificationCenter.default.publisher(for: .rivenShowSearch)) { _ in onSearch() }
            .onReceive(NotificationCenter.default.publisher(for: .rivenShowThemePicker)) { _ in onShowThemePicker() }
            .onReceive(NotificationCenter.default.publisher(for: .rivenShowShortcutsCheatsheet)) { _ in onShortcuts() }
            .onReceive(NotificationCenter.default.publisher(for: .rivenNewTab)) { _ in onNewTab() }
            .onReceive(NotificationCenter.default.publisher(for: .rivenNewWorkspace)) { _ in onNewWorkspace() }
            .onReceive(NotificationCenter.default.publisher(for: .rivenOpenProject)) { _ in onOpenProject() }
            .onReceive(NotificationCenter.default.publisher(for: .rivenCloseTab)) { _ in onCloseTab() }
            .onReceive(NotificationCenter.default.publisher(for: .rivenCloseEditor)) { _ in onCloseEditor() }
            .onReceive(NotificationCenter.default.publisher(for: .rivenToggleSidebar)) { _ in onToggleSidebar() }
            .onReceive(NotificationCenter.default.publisher(for: .rivenClearFocusedTerminal)) { _ in onClearTerminal() }
            .onReceive(NotificationCenter.default.publisher(for: .rivenFocusInnerTab)) { note in
                if let id = note.object as? TabID { onFocusInnerTab(id) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .rivenCloseInnerTab)) { note in
                if let id = note.object as? TabID { onCloseInnerTab(id) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .rivenRenameInnerTab)) { note in
                if let rename = note.object as? InnerTabRename { onRenameInnerTab(rename) }
            }
    }
}

/// Sub-wiring for the surface-split notifications. Extracted so the
/// parent `NotificationWiring.body` doesn't blow past the SwiftUI
/// type-checker's depth budget — same trick we used when adding the
/// trust-prompt + path-field listeners earlier.
private struct SurfaceWiring: ViewModifier {
    let onSplitSurface: (SplitDirection) -> Void
    let onFocusSurface: (SurfaceFocus) -> Void
    let onCloseSurface: (SurfaceFocus) -> Void
    let onCycleSurfaceFocus: () -> Void
    let onEditorDirtyChanged: (EditorDirtyChange) -> Void
    let onEditorFileVanished: (SurfaceID) -> Void
    let onEditorFileRestored: (SurfaceID) -> Void
    let onCommandSubmitted: (String) -> Void
    let onCommandHistoryRequest: (CommandHistoryRequest) -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .rivenSplitFocusedSurface)) { note in
                if let direction = note.object as? SplitDirection { onSplitSurface(direction) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .rivenFocusSurface)) { note in
                if let focus = note.object as? SurfaceFocus { onFocusSurface(focus) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .rivenCloseSurface)) { note in
                if let focus = note.object as? SurfaceFocus { onCloseSurface(focus) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .rivenCycleSurfaceFocus)) { _ in
                onCycleSurfaceFocus()
            }
            .onReceive(NotificationCenter.default.publisher(for: .rivenEditorDirtyChanged)) { note in
                if let change = note.object as? EditorDirtyChange { onEditorDirtyChanged(change) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .rivenEditorFileVanished)) { note in
                if let id = note.object as? SurfaceID { onEditorFileVanished(id) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .rivenEditorFileRestored)) { note in
                if let id = note.object as? SurfaceID { onEditorFileRestored(id) }
            }
            // NOTE: deliberately NOT subscribing to
            // `.rivenCommandHistoryRequest` here. It's already handled
            // synchronously by a `NotificationCenter.addObserver` token
            // in `RivenRootController.init` (see `historyObserver`).
            // Adding `.onReceive` duplicates was a double-handling bug —
            // the controller mutated state twice per notification, and
            // the SwiftUI observer fired a render-tick later than the
            // synchronous one (so command-bar history reads always saw a nil
            // response box in the first race).
            .onReceive(NotificationCenter.default.publisher(for: .rivenCommandSubmitted)) { note in
                if let text = note.object as? String { onCommandSubmitted(text) }
            }
    }
}

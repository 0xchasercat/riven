import AppKit
import BentoCore
import SwiftUI

struct BentoRootView: View {
    @EnvironmentObject private var controller: BentoRootController
    @State private var selectedThemeID: String?
    @State private var activeOverlay: Overlay?
    @State private var paletteQuery = ""
    @State private var searchQuery = ""
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
            if !controller.preference.hasExplicitSelection {
                ThemePicker(theme: theme, onSelect: { id in
                    try? controller.preference.selectTheme(id: id)
                    selectedThemeID = id
                })
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
            onSendCtrlByte: { byte in
                controller.sendByteToFocusedTerminal(byte)
            },
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
    }

    private var mainColumn: some View {
        // Pull the whole chrome up so the WorkspaceTabBar fills the
        // titlebar area (the window already has
        // `titlebarAppearsTransparent + .fullSizeContentView` set in
        // BentoApp). Without this the OS-reserved titlebar height
        // (~28pt) read as dead empty space above the tab bar.
        // WorkspaceTabBar reserves a 78pt leading spacer for the
        // traffic-light buttons so they remain clickable.
        VStack(spacing: 0) {
            // H8: WorkspaceTabBar + toolbar share a single
            // NSVisualEffectView background so the translucent title bar
            // (set in BentoApp via `titlebarAppearsTransparent` +
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
                // one washed-out grey strip against the dark Bento
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
            // H-3: shown when openProject fell back to ~ because the
            // requested root was missing or unreadable. The user can
            // dismiss with the × — the fallback cwd stays put either
            // way; this banner is purely informational. Lives above
            // PaneGridView so it sits in the workspace chrome rather
            // than on top of one specific pane.
            if let reason = controller.state.projectFallbackReason {
                ProjectFallbackBanner(
                    theme: theme,
                    reason: reason,
                    onDismiss: { controller.dismissProjectFallbackReason() }
                )
            }
            PaneGridView(
                theme: theme,
                paneGraph: controller.state.paneGraph,
                projectRoot: controller.state.projectRoot,
                fileMap: controller.fileMap,
                agentClient: controller.agentClient,
                brokerEpoch: controller.brokerEpoch,
                submitMode: controller.submitsOnEnter ? .enterSubmits : .enterIsNewline,
                dirtySurfaces: controller.dirtyEditorSurfaces,
                vanishedSurfaces: controller.vanishedFileSurfaces,
                onGraphChange: { controller.recordPaneGraph($0) },
                onOpenFile: { controller.openFile($0) },
                onCwdChanged: { paneID, cwd in
                    controller.updateWorkspaceCwd(paneID: paneID, cwd: cwd)
                }
            )
            statusBar
        }
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
        HStack(spacing: BentoSpacing.s) {
            workspacePathField
            Spacer()
            if controller.agentClient == nil {
                Text("connecting to broker…")
                    .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
            }
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
                commands: CommandPalette(commands: Command.bentoBuiltIns).search(paletteQuery),
                onSelect: { dispatch($0) },
                onClose: { activeOverlay = nil }
            )
        case .search:
            SearchOverlay(
                theme: theme,
                query: $searchQuery,
                search: { try await controller.search($0) },
                onOpenFile: { url in
                    activeOverlay = nil
                    controller.openFile(url)
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
        // tokens (one notch off the canvas background — Bento ships
        // a near-black band; Paper a warm-cream one slightly darker
        // than the editor canvas). Matches `mockup/workspace.jsx`'s
        // `StatusBar` component.
        HStack(spacing: 14) {
            Text(URL(fileURLWithPath: controller.state.projectRoot).lastPathComponent)
            Text("\(controller.state.paneGraph.leaves().count) tab\(controller.state.paneGraph.leaves().count == 1 ? "" : "s")")
            Text("theme: \(theme.name)")
            Spacer()
            ScratchEditorButton(theme: theme) { controller.openScratchEditor() }
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
        HStack(spacing: BentoSpacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(hex: theme.chrome.warning.hex))
            Text(reason)
                .font(BentoType.mono(BentoType.small))
                .foregroundStyle(Color(hex: theme.chrome.text.hex))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: BentoSpacing.s)
            Button(action: onDismiss) {
                Text("×")
                    .font(BentoType.chrome(13, weight: .medium))
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
        .padding(.horizontal, BentoSpacing.m)
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
                RoundedRectangle(cornerRadius: BentoRadius.small, style: .continuous)
                    .fill(Color(hex: theme.chrome.accentSoft.hex)
                        .opacity(isHovered ? 1 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovered = $0 }
        .help("Open a scratch editor tab (no file on disk)")
        .animation(BentoMotion.hover, value: isHovered)
    }
}

/// Collects all NotificationCenter wiring into a single ViewModifier so
/// `BentoRootView.body` stays under the SwiftUI type-checker's complexity
/// budget. Every callback hops back to `BentoRootView`'s closures so the
/// state mutations still live with the view that owns the `@State`.
private struct NotificationWiring: ViewModifier {
    let onPalette: () -> Void
    let onSearch: () -> Void
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
    let onSendCtrlByte: (UInt8) -> Void
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
                onSendCtrlByte: onSendCtrlByte,
                onEditorDirtyChanged: onEditorDirtyChanged,
                onEditorFileVanished: onEditorFileVanished,
                onEditorFileRestored: onEditorFileRestored,
                onCommandSubmitted: onCommandSubmitted,
                onCommandHistoryRequest: onCommandHistoryRequest
            ))
            .onReceive(NotificationCenter.default.publisher(for: .bentoShowCommandPalette)) { _ in onPalette() }
            .onReceive(NotificationCenter.default.publisher(for: .bentoShowSearch)) { _ in onSearch() }
            .onReceive(NotificationCenter.default.publisher(for: .bentoNewTab)) { _ in onNewTab() }
            .onReceive(NotificationCenter.default.publisher(for: .bentoNewWorkspace)) { _ in onNewWorkspace() }
            .onReceive(NotificationCenter.default.publisher(for: .bentoOpenProject)) { _ in onOpenProject() }
            .onReceive(NotificationCenter.default.publisher(for: .bentoCloseTab)) { _ in onCloseTab() }
            .onReceive(NotificationCenter.default.publisher(for: .bentoCloseEditor)) { _ in onCloseEditor() }
            .onReceive(NotificationCenter.default.publisher(for: .bentoToggleSidebar)) { _ in onToggleSidebar() }
            .onReceive(NotificationCenter.default.publisher(for: .bentoClearFocusedTerminal)) { _ in onClearTerminal() }
            .onReceive(NotificationCenter.default.publisher(for: .bentoFocusInnerTab)) { note in
                if let id = note.object as? TabID { onFocusInnerTab(id) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .bentoCloseInnerTab)) { note in
                if let id = note.object as? TabID { onCloseInnerTab(id) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .bentoRenameInnerTab)) { note in
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
    let onSendCtrlByte: (UInt8) -> Void
    let onEditorDirtyChanged: (EditorDirtyChange) -> Void
    let onEditorFileVanished: (SurfaceID) -> Void
    let onEditorFileRestored: (SurfaceID) -> Void
    let onCommandSubmitted: (String) -> Void
    let onCommandHistoryRequest: (CommandHistoryRequest) -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .bentoSplitFocusedSurface)) { note in
                if let direction = note.object as? SplitDirection { onSplitSurface(direction) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .bentoFocusSurface)) { note in
                if let focus = note.object as? SurfaceFocus { onFocusSurface(focus) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .bentoCloseSurface)) { note in
                if let focus = note.object as? SurfaceFocus { onCloseSurface(focus) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .bentoCycleSurfaceFocus)) { _ in
                onCycleSurfaceFocus()
            }
            .onReceive(NotificationCenter.default.publisher(for: .bentoSendCtrlByte)) { note in
                if let n = note.object as? NSNumber { onSendCtrlByte(n.uint8Value) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .bentoEditorDirtyChanged)) { note in
                if let change = note.object as? EditorDirtyChange { onEditorDirtyChanged(change) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .bentoEditorFileVanished)) { note in
                if let id = note.object as? SurfaceID { onEditorFileVanished(id) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .bentoEditorFileRestored)) { note in
                if let id = note.object as? SurfaceID { onEditorFileRestored(id) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .bentoCommandSubmitted)) { note in
                if let text = note.object as? String { onCommandSubmitted(text) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .bentoCommandHistoryRequest)) { note in
                if let request = note.object as? CommandHistoryRequest { onCommandHistoryRequest(request) }
            }
    }
}

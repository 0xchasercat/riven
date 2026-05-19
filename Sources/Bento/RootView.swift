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
            onCloseInnerTab: { controller.closeInnerTab($0) }
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
        VStack(spacing: 0) {
            WorkspaceTabBar(
                theme: theme,
                tabs: controller.state.paneGraph.leaves(),
                focusedID: controller.state.paneGraph.focusedPaneID,
                onSelect: { controller.focusTab($0) },
                onClose: { controller.closeTab($0) },
                onAdd: { controller.openNewWorkspace() }
            )
            toolbar
            PaneGridView(
                theme: theme,
                paneGraph: controller.state.paneGraph,
                projectRoot: controller.state.projectRoot,
                fileMap: controller.fileMap,
                agentClient: controller.agentClient,
                brokerEpoch: controller.brokerEpoch,
                submitMode: controller.submitsOnEnter ? .enterSubmits : .enterIsNewline,
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

    /// The focused workspace's root cwd — what the toolbar input edits.
    /// Falls back to the project root when no workspace is focused
    /// (defensive; shouldn't happen in normal use).
    private var focusedWorkspaceCwd: String {
        controller.state.paneGraph
            .pane(controller.state.paneGraph.focusedPaneID)?
            .workspace?.initialCwd
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
        .background(Color(hex: theme.chrome.background.hex))
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

    /// Hand the typed path to the controller; on rejection (path doesn't
    /// exist), flip the rejected flag so the toolbar shows the hint.
    /// Auto-clears after 3s so the user isn't stuck looking at it.
    private func commitWorkspacePath() {
        let ok = controller.setFocusedWorkspaceCwd(workspacePathDraft)
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
        case .splitRight, .splitDown:
            // Splits are gone — treat split commands as "new tab" for
            // backward palette compatibility.
            controller.openNewTab()
        case .closePane:
            controller.closeTab(controller.state.paneGraph.focusedPaneID)
        case .cycleFocus:
            controller.recordPaneGraph(controller.state.paneGraph.nextFocus())
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
        HStack(spacing: 14) {
            Text(URL(fileURLWithPath: controller.state.projectRoot).lastPathComponent)
            Text("\(controller.state.paneGraph.leaves().count) tab\(controller.state.paneGraph.leaves().count == 1 ? "" : "s")")
            Text("theme: \(theme.name)")
            Spacer()
            ScratchEditorButton(theme: theme) { controller.openScratchEditor() }
            Text("0 telemetry")
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
        .padding(.horizontal, 12)
        .frame(height: 22)
        .background(Color(hex: theme.chrome.background.hex))
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

    func body(content: Content) -> some View {
        content
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
    }
}

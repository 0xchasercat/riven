import AppKit
import BentoCore
import Combine
import Foundation

/// Bridges the actor-based `WorkspaceController` into SwiftUI.
///
/// Owns the persistent stores (trust, snapshots, scrollback), opens the cwd
/// as the current project at launch, and republishes the resulting
/// `WorkspaceState` on the main actor so views can bind to it.
@MainActor
final class BentoRootController: ObservableObject {
    let preference = ThemePreferenceStore()
    let workspace: WorkspaceController
    let fileMap = PaneFileMap()

    @Published private(set) var state: WorkspaceState
    @Published var openFilePaths: [String] = []
    @Published private(set) var agentClient: AgentClient?
    /// Bumped each time `agentClient` is replaced — initial connect counts
    /// as epoch 1, every subsequent watchdog respawn bumps to 2, 3, …
    /// Views that hold long-lived broker sessions stamp this into their
    /// SwiftUI `.id(...)` so they tear down + rebuild against the fresh
    /// client when the broker is respawned.
    @Published private(set) var brokerEpoch: Int = 0
    /// Mirrors `preference.submitsOnEnter` so SwiftUI views see the change
    /// the moment the user toggles via the palette. `false` (default) =
    /// Enter inserts a newline, Cmd+Enter submits — Slack/Claude pattern.
    @Published private(set) var submitsOnEnter: Bool = false
    /// Set of editor surfaces with unsaved changes. Updated by
    /// EditorTabContent via `setSurfaceDirty(_:, dirty:)` whenever
    /// its underlying EditorBuffer's `isDirty` flips. Views that
    /// need to display the dirty indicator (inner tab strip "•"
    /// prefix, editor toolbar save-enabled state) read from this
    /// directly.
    @Published private(set) var dirtyEditorSurfaces: Set<SurfaceID> = []
    /// Window-global command history. Each command bar submit
    /// appends here, and the up/down arrows in any command bar walk
    /// through the entries. Scoped to the controller (one history
    /// per Bento window) rather than per-terminal because the user's
    /// most common use is "I just ran that, let me edit it" — they
    /// don't usually care which terminal it landed in.
    /// Not `@Published` — mutating it would re-render every observer
    /// for purely-internal state churn. Views read from it only via
    /// the notification handlers, which take ad-hoc snapshots.
    var commandHistory = CommandHistory()

    init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Bento", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let trust = ProjectTrustStore()
        let snapshots = WorkspaceSnapshotStore(root: support.appendingPathComponent("snapshots", isDirectory: true))
        let scrollback = ScrollbackStore(root: support.appendingPathComponent("scrollback", isDirectory: true))
        let workspace = WorkspaceController(trustStore: trust, snapshotStore: snapshots, scrollbackStore: scrollback)
        self.workspace = workspace

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let themeID = preference.selectedTheme.id

        // Render with a synchronous fallback so the first frame has something
        // real, then refresh from the controller (which loads snapshots,
        // parses session.yml, scans the tree) on the next runloop tick.
        self.state = Self.fallbackState(cwd: cwd, themeID: themeID)
        self.openFilePaths = self.state.openFiles
        self.submitsOnEnter = preference.submitsOnEnter

        Task { [weak self] in
            guard let self else { return }
            if let real = try? await self.workspace.openProject(cwd, selectedThemeID: themeID) {
                self.state = real
                self.openFilePaths = real.openFiles
            }
        }
    }

    /// Hand off the broker connection once `AgentLauncher` finishes its
    /// startup handshake. Until this fires, terminal panes render a
    /// "connecting" placeholder.
    ///
    /// Also called by the launcher's watchdog after a respawn — in that
    /// case the previous `agentClient` is already closed and views need
    /// to rebuild against the new one. We bump `brokerEpoch` so views
    /// that key off it (`PaneGridView`, terminal tab content) tear down
    /// their cached NSViews and ask SwiftUI for a fresh build.
    func attachAgentClient(_ client: AgentClient) {
        self.agentClient = client
        self.brokerEpoch &+= 1
    }

    /// Open `url` in the focused workspace as an editor tab.
    ///
    /// If the focused workspace already has an editor tab pointed at
    /// `url`, focus that tab. Otherwise append a fresh editor tab and
    /// focus it. The sidebar is unchanged — that's the whole point of
    /// the bento model: the editor lives as a peer of the terminal in
    /// the inner tab strip, sharing one sidebar.
    ///
    /// Legacy non-workspace pane kinds (terminal / editor leaves from
    /// pre-workspace snapshots) fall back to the old auto-split behavior
    /// so old graphs keep working.
    func openFile(_ url: URL) {
        var graph = state.paneGraph
        let focusedID = graph.focusedPaneID
        let focused = graph.pane(focusedID)

        if let workspace = focused?.workspace {
            var updated = workspace
            if let existing = updated.tabs.first(where: { $0.editorPath == url.path }) {
                // Already open — just focus the existing tab.
                updated.focusedTabID = existing.id
            } else {
                let newTab = WorkspaceInnerTab(
                    id: TabID(),
                    displayName: url.lastPathComponent,
                    kind: .editor(path: url.path),
                    cwd: updated.initialCwd
                )
                updated.tabs.append(newTab)
                updated.focusedTabID = newTab.id
            }
            var pane = focused!
            pane.kind = .workspace(updated)
            graph = graph.replacingPane(pane)
        } else {
            // Legacy fallback (terminal/editor leaves): preserve previous
            // behavior of splitting in an editor pane.
            let leaves = graph.leaves()
            let editorPaneID: PaneID

            if let focusedEditor = leaves.first(where: { $0.id == focusedID && $0.editor != nil }) {
                editorPaneID = focusedEditor.id
            } else if let firstEditor = leaves.first(where: { $0.editor != nil }) {
                editorPaneID = firstEditor.id
                graph = graph.focus(firstEditor.id)
            } else {
                let newEditor = PaneDescriptor(
                    id: PaneID(),
                    name: url.lastPathComponent,
                    kind: .editor(EditorPane(path: url.path)),
                    isFocused: true
                )
                graph = graph.split(focusedID, direction: .right, newPane: newEditor)
                editorPaneID = newEditor.id
            }
            fileMap.setFile(url, for: editorPaneID)
        }

        recordPaneGraph(graph)

        var paths = openFilePaths
        if !paths.contains(url.path) {
            paths.insert(url.path, at: 0)
            recordOpenFiles(paths)
        }
    }

    /// Update the in-memory open-file list and tell the controller so the
    /// next snapshot reflects what the editor surface is showing.
    func recordOpenFiles(_ paths: [String]) {
        openFilePaths = paths
        Task { [workspace] in
            await workspace.setOpenFiles(paths)
        }
    }

    /// Update the `currentCwd` of a workspace pane in response to an OSC 7
    /// report from its shell. Re-publishes the pane graph so the workspace's
    /// sidebar re-scans the new path. No-op if the pane isn't a workspace
    /// (or the cwd didn't actually change).
    func updateWorkspaceCwd(paneID: PaneID, cwd: String) {
        guard var pane = state.paneGraph.pane(paneID),
              var workspace = pane.workspace,
              workspace.currentCwd != cwd else {
            return
        }
        workspace.currentCwd = cwd
        pane.kind = .workspace(workspace)
        let graph = state.paneGraph.replacingPane(pane)
        recordPaneGraph(graph)
    }

    /// Replace the tracked pane graph after a UI-driven mutation (split,
    /// focus change, pane close).
    func recordPaneGraph(_ graph: PaneGraph) {
        Task { [workspace] in
            await workspace.updatePaneGraph(graph)
        }
        self.state.paneGraph = graph
    }

    /// Run a unified search (files + scrollback) against the currently
    /// open project. Used by the search overlay.
    func search(_ query: String) async throws -> [UnifiedSearchResult] {
        try await workspace.search(query)
    }

    /// Add a brand-new top-level **workspace** (a new screen-level bento
    /// box) rooted at `~`. Wired to Cmd+N. Each workspace owns its own
    /// sidebar and its own collection of inner terminal tabs.
    func openNewWorkspace() {
        openNewWorkspace(at: NSHomeDirectory())
    }

    /// Send a `cd <path>` into the focused workspace's focused
    /// terminal. The shell processes it and emits OSC 7 on the next
    /// prompt, which propagates back as `workspace.currentCwd` →
    /// the sidebar + toolbar both follow automatically.
    ///
    /// This is the toolbar's editable-path-field commit path. We
    /// deliberately do NOT mutate the workspace model directly — the
    /// shell is the source of truth for "where am I", and the
    /// workspace just mirrors what the shell is doing. This matches
    /// the "workspaces are spaces, not directory locks" mental model.
    ///
    /// Path normalization:
    ///   - leading `~` expands to `$HOME`
    ///   - relative paths resolve against the workspace's current pwd
    ///   - the resolved path must exist as a directory; otherwise the
    ///     call is a no-op and returns `false` so the toolbar can
    ///     flag the bad input. The `cd` itself isn't sent unless the
    ///     path validates client-side.
    ///
    /// No-op (returns false) when the focused surface isn't a
    /// terminal (e.g. an editor tab is focused) — there's no PTY to
    /// `cd` in that case.
    @discardableResult
    func changeFocusedShellPwd(_ raw: String) -> Bool {
        guard let pane = state.paneGraph.pane(state.paneGraph.focusedPaneID),
              let workspace = pane.workspace,
              let paneID = workspace.focusedTab.terminalPaneID,
              let client = agentClient else { return false }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let resolved: String
        if expanded.hasPrefix("/") {
            resolved = (expanded as NSString).standardizingPath
        } else {
            let base = URL(fileURLWithPath: workspace.currentCwd)
            resolved = base.appendingPathComponent(expanded)
                .standardizedFileURL.path
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        // Single-quote so paths with spaces / special chars get
        // through the shell intact.
        let payload = "cd '\(resolved)'\n"
        let data = Data(payload.utf8)
        Task { try? await client.writeInput(paneID: paneID, data: data) }
        return true
    }

    /// Add a new workspace rooted at `cwd` and focus it.
    func openNewWorkspace(at cwd: String) {
        let newPane = PaneDescriptor(
            id: PaneID(),
            name: "workspace",
            kind: .workspace(WorkspaceGroup(initialCwd: cwd)),
            isFocused: true
        )
        let graph = state.paneGraph.split(
            state.paneGraph.focusedPaneID,
            direction: .right,
            newPane: newPane
        )
        recordPaneGraph(graph)
    }

    /// Add a new **inner tab** to the currently focused workspace. Wired
    /// to Cmd+T. The new tab gets its own broker PaneID (own PTY), and
    /// focus moves to it. The new shell starts in the workspace's
    /// **current** pwd (where the user is right now), not the
    /// workspace's original directory — workspaces are spaces, not
    /// directory locks.
    func openNewInnerTab() {
        guard var pane = state.paneGraph.pane(state.paneGraph.focusedPaneID),
              let workspace = pane.workspace else {
            // No focused workspace — fall back to creating a new top-level
            // workspace so Cmd+T always does something useful.
            openNewWorkspace()
            return
        }
        let tab = WorkspaceInnerTab(
            displayName: "shell",
            kind: .terminal(paneID: PaneID(), command: nil),
            cwd: workspace.currentCwd
        )
        pane.kind = .workspace(workspace.appendingTab(tab))
        recordPaneGraph(state.paneGraph.replacingPane(pane))
    }

    /// Close an inner tab within the focused workspace. If it's the
    /// last inner tab, no-op — the workspace always has at least one
    /// terminal. If the closed tab was focused, focus moves to a
    /// neighbour.
    ///
    /// When the tab contains a dirty editor surface, an NSAlert
    /// prompts the user to save / discard / cancel before closing.
    /// Cancel aborts the close; Save sends a `.bentoSaveSurface`
    /// notification (the editor's coordinator picks it up
    /// synchronously and writes to disk) before proceeding; Don't
    /// Save proceeds without saving.
    func closeInnerTab(_ id: TabID) {
        guard var pane = state.paneGraph.pane(state.paneGraph.focusedPaneID),
              let workspace = pane.workspace,
              let tab = workspace.tabs.first(where: { $0.id == id }) else {
            return
        }
        let dirty = dirtySurfacesIn(tab)
        if !dirty.isEmpty {
            switch promptForDirtyClose(filenames: dirty.compactMap(\.filename)) {
            case .cancel: return
            case .save:
                for surface in dirty {
                    NotificationCenter.default.post(
                        name: .bentoSaveSurface,
                        object: surface.id
                    )
                }
            case .dontSave:
                break
            }
        }
        let updated = workspace.removingTab(id)
        guard updated != workspace else { return }
        // Drop dirty tracking for surfaces inside the closed tab so
        // we don't carry stale state if a new tab reuses an id later
        // (UUIDs make collisions vanishingly rare but the cleanup is
        // free).
        for surface in tab.surfaces {
            dirtyEditorSurfaces.remove(surface.id)
        }
        pane.kind = .workspace(updated)
        recordPaneGraph(state.paneGraph.replacingPane(pane))
    }

    /// Split the focused workspace's focused tab's focused surface in
    /// `direction`. The new surface is a terminal that starts in the
    /// workspace's **current** pwd — where the user is right now,
    /// not where the tab was originally created. Focus moves to the
    /// new surface so the user can type immediately.
    ///
    /// Wired to Cmd+D (split right), Cmd+Shift+D (split down), and the
    /// `[][]` button next to `+` in the inner tab strip.
    func splitFocusedSurface(direction: SplitDirection) {
        guard var pane = state.paneGraph.pane(state.paneGraph.focusedPaneID),
              var workspace = pane.workspace else { return }
        // Update the focused tab's `cwd` to the workspace's live pwd
        // before splitting — that field is what BrokeredTerminalView
        // reads on PTY startup, and we want the new shell to start
        // where the user is, not where the tab was originally
        // created. Existing surfaces in the tab are unaffected:
        // their PTYs are already running with their own cwds.
        if let tabIdx = workspace.tabs.firstIndex(where: { $0.id == workspace.focusedTabID }) {
            workspace.tabs[tabIdx].cwd = workspace.currentCwd
        }
        let newSurface = TabSurface(
            kind: .terminal(paneID: PaneID(), command: nil)
        )
        let updated = workspace.splittingFocusedSurface(
            direction: direction,
            newSurface: newSurface
        )
        guard updated != workspace else { return }
        pane.kind = .workspace(updated)
        recordPaneGraph(state.paneGraph.replacingPane(pane))
    }

    /// Focus a specific surface inside a tab. Called from a click on a
    /// non-focused split surface.
    func focusSurface(tabID: TabID, surfaceID: SurfaceID) {
        guard var pane = state.paneGraph.pane(state.paneGraph.focusedPaneID),
              let workspace = pane.workspace else { return }
        let updated = workspace.focusingSurface(tabID: tabID, surfaceID: surfaceID)
        guard updated != workspace else { return }
        pane.kind = .workspace(updated)
        recordPaneGraph(state.paneGraph.replacingPane(pane))
    }

    /// Cycle focus to the next surface in the focused tab's layout
    /// (DFS order). Wired to Ctrl+Tab; useful when the user has
    /// multiple splits inside one tab and wants to keyboard-walk
    /// through them without reaching for the trackpad.
    func cycleFocusedTabSurface() {
        guard var pane = state.paneGraph.pane(state.paneGraph.focusedPaneID),
              let workspace = pane.workspace else { return }
        let updated = workspace.focusingNextSurface(tabID: workspace.focusedTabID)
        guard updated != workspace else { return }
        pane.kind = .workspace(updated)
        recordPaneGraph(state.paneGraph.replacingPane(pane))
    }

    /// Close a specific surface inside a tab. Single-surface tabs can't
    /// have their only surface closed via this path — close the whole
    /// tab via `closeInnerTab` instead. If the closed surface was the
    /// focused one, focus shifts to a neighbour.
    ///
    /// If the surface is a dirty editor, prompts (same alert flow as
    /// `closeInnerTab`).
    func closeSurface(tabID: TabID, surfaceID: SurfaceID) {
        guard var pane = state.paneGraph.pane(state.paneGraph.focusedPaneID),
              let workspace = pane.workspace,
              let tab = workspace.tabs.first(where: { $0.id == tabID }),
              let surface = tab.surfaces.first(where: { $0.id == surfaceID }) else { return }
        if dirtyEditorSurfaces.contains(surfaceID) {
            switch promptForDirtyClose(filenames: [surface.filename].compactMap { $0 }) {
            case .cancel: return
            case .save:
                NotificationCenter.default.post(
                    name: .bentoSaveSurface,
                    object: surfaceID
                )
            case .dontSave:
                break
            }
        }
        let updated = workspace.removingSurface(tabID: tabID, surfaceID: surfaceID)
        guard updated != workspace else { return }
        dirtyEditorSurfaces.remove(surfaceID)
        pane.kind = .workspace(updated)
        recordPaneGraph(state.paneGraph.replacingPane(pane))
    }

    /// Append a just-submitted command to the global history.
    /// CommandBar's onSubmit posts `.bentoCommandSubmitted` with the
    /// submitted text; the wiring routes here. Dedupe + capacity
    /// limits handled inside `CommandHistory.submit`.
    func recordCommandSubmission(_ text: String) {
        commandHistory.submit(text)
    }

    /// Walk one step back / forward through history for the up / down
    /// arrow in the command bar. Returns the new text the bar should
    /// display, or nil to leave the buffer untouched. `currentBuffer`
    /// is the user's in-progress draft (stashed so a subsequent
    /// down-arrow can restore it).
    func recallPreviousCommand(currentBuffer: String) -> String? {
        commandHistory.previous(currentBuffer: currentBuffer)
    }

    func recallNextCommand(currentBuffer: String) -> String? {
        commandHistory.next(currentBuffer: currentBuffer)
    }

    /// Reset the history cursor — the next up-arrow starts from the
    /// most recent submission. Called when the user edits the buffer
    /// between navigations.
    func resetCommandHistoryCursor() {
        commandHistory.reset()
    }

    /// Mark / clear a surface's dirty state. EditorTabContent's
    /// dirty binding writes here whenever its EditorBuffer flips.
    func setSurfaceDirty(_ surfaceID: SurfaceID, dirty: Bool) {
        if dirty {
            if !dirtyEditorSurfaces.contains(surfaceID) {
                dirtyEditorSurfaces.insert(surfaceID)
            }
        } else {
            dirtyEditorSurfaces.remove(surfaceID)
        }
    }

    /// Filter `tab.surfaces` down to the editor surfaces currently
    /// tracked as dirty. Used by the close-prompt to decide whether
    /// to show the alert + which filenames to list.
    private func dirtySurfacesIn(_ tab: WorkspaceInnerTab) -> [TabSurface] {
        tab.surfaces.filter { dirtyEditorSurfaces.contains($0.id) }
    }

    private enum DirtyCloseChoice { case save, dontSave, cancel }

    /// Modal NSAlert for the "you have unsaved changes" prompt.
    /// Returns the user's choice (Save / Don't Save / Cancel). Modal
    /// presentation is fine here — close is a discrete user action
    /// that's expected to block until they resolve the conflict.
    private func promptForDirtyClose(filenames: [String]) -> DirtyCloseChoice {
        let alert = NSAlert()
        switch filenames.count {
        case 0:
            // Should only happen if we lost track of which file was
            // dirty — fall back to the generic prompt.
            alert.messageText = "Save changes before closing?"
            alert.informativeText = "Your edits will be lost otherwise."
        case 1:
            alert.messageText = "Save changes to “\(filenames[0])” before closing?"
            alert.informativeText = "Your edits will be lost otherwise."
        default:
            alert.messageText = "Save changes to \(filenames.count) files before closing?"
            alert.informativeText = filenames.map { "• \($0)" }.joined(separator: "\n")
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .dontSave
        default: return .cancel
        }
    }

    /// Rename a workspace tab (the top strip). Empty / whitespace input
    /// reverts to the cwd-derived label. The workspace is found by its
    /// pane ID, not by focus — so the editor in WorkspaceTabBar can
    /// rename a tab that isn't currently focused.
    func renameWorkspace(paneID: PaneID, to newName: String) {
        guard var pane = state.paneGraph.pane(paneID),
              let workspace = pane.workspace else { return }
        let updated = workspace.renamed(to: newName)
        guard updated != workspace else { return }
        pane.kind = .workspace(updated)
        recordPaneGraph(state.paneGraph.replacingPane(pane))
    }

    /// Rename an inner tab inside the focused workspace. Empty input
    /// resets the displayName to the kind-default.
    func renameInnerTab(_ id: TabID, to newName: String) {
        guard var pane = state.paneGraph.pane(state.paneGraph.focusedPaneID),
              let workspace = pane.workspace else { return }
        let updated = workspace.renamingTab(id, to: newName)
        guard updated != workspace else { return }
        pane.kind = .workspace(updated)
        recordPaneGraph(state.paneGraph.replacingPane(pane))
    }

    /// Move focus to an inner tab within the focused workspace.
    func focusInnerTab(_ id: TabID) {
        guard var pane = state.paneGraph.pane(state.paneGraph.focusedPaneID),
              let workspace = pane.workspace else {
            return
        }
        let updated = workspace.focusingTab(id)
        guard updated != workspace else { return }
        pane.kind = .workspace(updated)
        recordPaneGraph(state.paneGraph.replacingPane(pane))
    }

    /// Backward-compat shim — older menu wiring calls `openNewTab()`.
    /// Maps to the new inner-tab semantics so Cmd+T behaves correctly
    /// even before the menu rewires.
    func openNewTab() {
        openNewInnerTab()
    }

    /// Append a fresh, unsaved scratch editor tab to the focused
    /// workspace (or fall back to creating a new workspace if no
    /// workspace is focused). The tab has a nil path until the user
    /// saves it; the display name is auto-numbered (Untitled-1,
    /// Untitled-2, …) per workspace so multiple scratch tabs read
    /// distinctly in the tab strip.
    func openScratchEditor() {
        guard var pane = state.paneGraph.pane(state.paneGraph.focusedPaneID),
              let workspace = pane.workspace else {
            openNewWorkspace()
            return
        }
        // Auto-number against existing Untitled-N tabs so the user's
        // own renamed tabs don't get clobbered. Find the next free
        // index by scanning the workspace's editor-scratch displayNames.
        let existingNumbers: [Int] = workspace.tabs.compactMap { tab in
            guard tab.editorPath == nil, tab.isEditor else { return nil }
            let prefix = "Untitled-"
            guard tab.displayName.hasPrefix(prefix) else { return nil }
            return Int(tab.displayName.dropFirst(prefix.count))
        }
        let nextN = (existingNumbers.max() ?? 0) + 1
        let scratch = WorkspaceInnerTab(
            id: TabID(),
            displayName: "Untitled-\(nextN)",
            kind: .editor(path: nil),
            cwd: workspace.initialCwd
        )
        pane.kind = .workspace(workspace.appendingTab(scratch))
        recordPaneGraph(state.paneGraph.replacingPane(pane))
    }

    /// Send a Ctrl+L (FF, 0x0C) byte to the focused workspace's focused
    /// terminal tab — the binding every shell already interprets as
    /// "clear screen". Editor tabs are a no-op for this command.
    ///
    /// Wired to Cmd+K (see `BentoApp.installMenu`) and routed through
    /// the `.bentoClearFocusedTerminal` notification so menu, palette,
    /// and any future entry point can converge on one path.
    func clearFocusedTerminal() {
        sendByteToFocusedTerminal(0x0C)
    }

    /// Generic byte-write helper for the global Ctrl+C / Ctrl+D /
    /// Ctrl+Z monitor in BentoApp. Editor tabs no-op — there's no PTY
    /// to send to. Lives here (not on the terminal view directly)
    /// because the global key monitor doesn't know which surface is
    /// focused; the controller's state graph does.
    func sendByteToFocusedTerminal(_ byte: UInt8) {
        guard
            let pane = state.paneGraph.pane(state.paneGraph.focusedPaneID),
            let workspace = pane.workspace,
            let paneID = workspace.focusedTab.terminalPaneID,
            let client = agentClient
        else { return }
        let payload = Data([byte])
        Task { try? await client.writeInput(paneID: paneID, data: payload) }
    }

    /// Toggle the focused workspace's sidebar between collapsed and
    /// expanded. Used by the sidebar header's toggle button.
    func toggleFocusedSidebar() {
        guard var pane = state.paneGraph.pane(state.paneGraph.focusedPaneID),
              var workspace = pane.workspace else {
            return
        }
        workspace.sidebarState = (workspace.sidebarState == .expanded) ? .collapsed : .expanded
        pane.kind = .workspace(workspace)
        recordPaneGraph(state.paneGraph.replacingPane(pane))
    }

    /// Close a workspace tab. If it's the last tab the call is a no-op
    /// (graph never goes empty). Otherwise focus moves to a neighbour.
    func closeTab(_ id: PaneID) {
        guard let next = state.paneGraph.close(id) else { return }
        recordPaneGraph(next)
    }

    /// Move keyboard focus to the given workspace tab.
    func focusTab(_ id: PaneID) {
        let next = state.paneGraph.focus(id)
        if next != state.paneGraph { recordPaneGraph(next) }
    }

    /// Close the focused inner tab if it's an editor. No-op when the
    /// focused pane isn't a workspace, when the focused inner tab is a
    /// terminal, or when the workspace has only one tab left (we never
    /// let a workspace go tabless).
    ///
    /// Wired to the `bentoCloseEditor` notification; the editor column
    /// header's `×` button used to fire this. Now that the editor is an
    /// inner tab, the per-tab `×` in `InnerTabStrip` is the primary
    /// close path — this remains as a fallback so older entry points
    /// (Cmd shortcuts, palette actions) still work.
    func closeFocusedEditor() {
        guard let pane = state.paneGraph.pane(state.paneGraph.focusedPaneID),
              let workspace = pane.workspace,
              workspace.focusedTab.editorPath != nil else {
            return
        }
        closeInnerTab(workspace.focusedTabID)
    }

    /// Trust the currently open project so its `.bento/session.yml` task
    /// panes will auto-start now and on every future open. Wired through
    /// the trust prompt overlay's "Trust this project" button.
    func trustCurrentProject() {
        Task { [weak self] in
            guard let self else { return }
            if let new = try? await self.workspace.trustCurrentProject() {
                self.state = new
            }
        }
    }

    /// Flip the Enter / Cmd+Enter binding in the command bar. Persists
    /// the new state via `ThemePreferenceStore` and republishes the
    /// mirrored `@Published` so live SwiftUI views see the change
    /// without restarting the session. Wired through the palette
    /// (`CommandAction.toggleSubmitOnEnter`).
    func toggleSubmitsOnEnter() {
        preference.toggleSubmitsOnEnter()
        submitsOnEnter = preference.submitsOnEnter
    }

    /// Cycle to the next built-in theme. Wired through `CommandAction.cycleTheme`.
    func cycleTheme() {
        let all = ThemeSpec.builtIns
        let current = preference.selectedTheme.id
        let nextIdx = (all.firstIndex(where: { $0.id == current }).map { $0 + 1 } ?? 0) % all.count
        try? preference.selectTheme(id: all[nextIdx].id)
        self.state.selectedThemeID = all[nextIdx].id
    }

    private static func fallbackState(cwd: URL, themeID: String) -> WorkspaceState {
        let tree = (try? ProjectFileTree.scan(root: cwd, maxDepth: 3))
            ?? ProjectFileTree(name: cwd.lastPathComponent, path: cwd.path, kind: .directory)
        let pane = PaneDescriptor(
            id: PaneID("workspace-root"),
            name: "workspace",
            kind: .workspace(WorkspaceGroup(initialCwd: cwd.path)),
            isFocused: true
        )
        return WorkspaceState(
            projectRoot: cwd.path,
            selectedThemeID: themeID,
            requiresTaskTrust: false,
            pendingTaskCommands: [],
            agentRequests: [],
            fileTree: tree,
            paneGraph: PaneGraph(root: pane),
            openFiles: [],
            restoredFromSnapshot: false
        )
    }
}

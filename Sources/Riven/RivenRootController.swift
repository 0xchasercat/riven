import AppKit
import RivenCore
import Combine
import Foundation

/// Bridges the actor-based `WorkspaceController` into SwiftUI.
///
/// Owns the persistent stores (trust, snapshots, scrollback), opens the cwd
/// as the current project at launch, and republishes the resulting
/// `WorkspaceState` on the main actor so views can bind to it.
@MainActor
final class RivenRootController: ObservableObject {
    let preference = ThemePreferenceStore()
    let workspace: WorkspaceController
    let fileMap = PaneFileMap()
    /// Shared scrollback store. The broker and the controller write to
    /// the same root under `~/Library/Application Support/Riven/
    /// scrollback`. The broker (`Sources/RivenAgent/main.swift`) seeds
    /// metadata sidecars at PTY spawn (sessionID, cwd, command-derived
    /// label); the controller patches them with project + workspace +
    /// pane-label context via `enrichScrollbackMetadata(...)` whenever
    /// it learns something the broker can't know.
    let scrollback: ScrollbackStore
    /// Z-3: installer for Riven's optional zsh shell integration.
    /// Stateless — the on-disk install status drives every read.
    let shellIntegration = ShellIntegrationInstaller()
    /// Mirrors `shellIntegration.isInstalled()` so SwiftUI views can
    /// re-render on install / uninstall without polling the filesystem.
    @Published private(set) var shellIntegrationInstalled: Bool = false

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
    /// H-2: editor surfaces whose backing file has been deleted /
    /// renamed underneath the open buffer. Updated by the editor
    /// coordinator's file watcher via `.rivenEditorFileVanished` /
    /// `.rivenEditorFileRestored`. UI consumers:
    ///   * `EditorToolbar` disables Save + shows a tooltip when the
    ///     surface is here.
    ///   * `InnerTabStrip` / `InnerTabChip` append "(missing)" to the
    ///     displayName.
    @Published private(set) var vanishedFileSurfaces: Set<SurfaceID> = []
    /// PaneIDs whose underlying terminal is currently on the alt
    /// screen (vim, nano, less, htop, claude-code, …). Posted by
    /// every `BrokeredTerminalView.draw` and mirrored here so the
    /// global Ctrl-byte monitor in `RivenApp` can route the entire
    /// Ctrl+letter surface to the PTY (not just C/D/Z) whenever a
    /// TUI owns the focused tab — without having to query the
    /// libghostty mode-state from app-delegate code.
    @Published private(set) var altScreenPaneIDs: Set<PaneID> = []
    /// Window-global command history. Each command bar submit
    /// appends here, and the up/down arrows in any command bar walk
    /// through the entries. Scoped to the controller (one history
    /// per Riven window) rather than per-terminal because the user's
    /// most common use is "I just ran that, let me edit it" — they
    /// don't usually care which terminal it landed in.
    /// Not `@Published` — mutating it would re-render every observer
    /// for purely-internal state churn. Views read from it only via
    /// the notification handlers, which take ad-hoc snapshots.
    var commandHistory = CommandHistory()
    /// H-6: currently-visible toast banner (or nil for none).
    /// Replaced wholesale on every `showBanner` call — there's no
    /// queue. SwiftUI keys auto-dismiss off `state.id` so a fresh
    /// banner restarts its own countdown rather than inheriting the
    /// previous one's remaining time.
    @Published private(set) var currentBanner: RivenBannerState?

    init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Riven", isDirectory: true)
        // H-15: probe Application Support for an existing snapshot /
        // scrollback footprint BEFORE we create the directories. The
        // absence of either dir means this is a first run; we'll
        // append a welcome scratch tab once the project is open. The
        // UserDefaults `welcomeShown` flag is the second gate so the
        // welcome can't reappear if a user nukes ~/Library/Application
        // Support/Riven by hand to reset state.
        let fileMgr = FileManager.default
        let snapshotsRoot = support.appendingPathComponent("snapshots", isDirectory: true)
        let scrollbackRoot = support.appendingPathComponent("scrollback", isDirectory: true)
        let snapshotsExisted = fileMgr.fileExists(atPath: snapshotsRoot.path)
        let scrollbackExisted = fileMgr.fileExists(atPath: scrollbackRoot.path)
        let welcomeAlreadyShown = UserDefaults.standard.bool(forKey: Self.welcomeShownDefaultsKey)
        let isFirstRun = !snapshotsExisted && !scrollbackExisted && !welcomeAlreadyShown

        try? fileMgr.createDirectory(at: support, withIntermediateDirectories: true)

        let trust = ProjectTrustStore()
        let snapshots = WorkspaceSnapshotStore(root: snapshotsRoot)
        let scrollback = ScrollbackStore(root: scrollbackRoot)
        let workspace = WorkspaceController(trustStore: trust, snapshotStore: snapshots, scrollbackStore: scrollback)
        self.workspace = workspace
        self.scrollback = scrollback
        self.shellIntegrationInstalled = ShellIntegrationInstaller().isInstalled()

        // Pick the cwd Riven boots into. When the user launches us
        // via `swift run` or `riven .` from a terminal, the
        // inherited working directory is usually a real project root
        // — use it. When LaunchServices launches us from
        // /Applications (Finder double-click, Dock click, Spotlight),
        // the inherited cwd is "/", which is the system root: TCC
        // protects most of it and the file viewer shows an empty
        // tree, which reads as "permissions broken" to the user.
        // Falling back to $HOME in that case gives the file viewer a
        // browseable starting point the user always has access to.
        let inheritedCwd = fileMgr.currentDirectoryPath
        let bootCwdPath = (inheritedCwd == "/" || inheritedCwd.isEmpty)
            ? NSHomeDirectory()
            : inheritedCwd
        let cwd = URL(fileURLWithPath: bootCwdPath)
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
            // One-shot sidebar-visibility migration. Before the
            // default flipped to `.expanded` the model shipped with
            // `.collapsed`, so any user who ran Riven before that
            // change has a snapshot saved with `sidebarState:
            // .collapsed`. The Codable decoder reads stored values
            // exactly, so the new default never takes effect for
            // them — they keep getting a 56-pt icon rail (or worse,
            // a width-zero pane if NSSplitView's holding priority
            // lost an earlier layout fight). Flip everyone to
            // `.expanded` exactly once and re-persist the snapshot
            // so the change sticks.
            let defaults = UserDefaults.standard
            if !defaults.bool(forKey: Self.sidebarMigrationV1Key) {
                self.forceExpandAllSidebars()
                defaults.set(true, forKey: Self.sidebarMigrationV1Key)
            }
            // H-15: append the welcome scratch tab AFTER the project
            // settles so the new tab lands inside the focused
            // workspace rather than the empty fallback graph.
            if isFirstRun {
                self.openWelcomeScratchTab()
                UserDefaults.standard.set(true, forKey: Self.welcomeShownDefaultsKey)
            }
        }

        // Synchronous observer for `.rivenCommandHistoryRequest`.
        // The command-bar arrow gesture posts the notification and
        // immediately reads `response.text` — SwiftUI's `.onReceive`
        // wiring runs on the next render tick which is far too late
        // for that synchronous read, so up/down arrow appears to do
        // nothing. NotificationCenter's `post(name:object:)` is
        // synchronous when there's a registered observer; installing
        // ours directly here means the response box is populated
        // before the post call returns.
        historyObserver = NotificationCenter.default.addObserver(
            forName: .rivenCommandHistoryRequest,
            object: nil,
            queue: nil
        ) { [weak self] note in
            // Pull the typed payload out on the calling thread —
            // CommandHistoryRequest is a class wrapping a reference
            // to a mutable response box, which Sendability across
            // the actor hop can't reason about. Reading it here
            // captures only the reference, which we then mutate on
            // MainActor.
            guard let request = note.object as? CommandHistoryRequest else { return }
            let direction = request.direction
            let currentBuffer = request.currentBuffer
            let responseBox = request.response
            MainActor.assumeIsolated {
                guard let self else { return }
                switch direction {
                case .previous:
                    responseBox.text = self.recallPreviousCommand(currentBuffer: currentBuffer)
                case .next:
                    responseBox.text = self.recallNextCommand(currentBuffer: currentBuffer)
                }
            }
        }

        // Alt-screen state observer — same async-vs-sync problem the
        // history observer above solves. The global key monitor in
        // RivenApp asks `focusedTerminalIsInAltScreen` on every
        // Ctrl+letter keystroke; that relies on
        // `altScreenPaneIDs` being current. SwiftUI's .onReceive
        // wiring runs on the next render tick, so a user who hits
        // Ctrl+X right after nano boots can miss the routing
        // window. Direct NotificationCenter observer keeps the set
        // up-to-date synchronously with the BrokeredTerminalView's
        // draw cycle.
        altScreenObserver = NotificationCenter.default.addObserver(
            forName: .rivenAltScreenChanged,
            object: nil,
            queue: nil
        ) { [weak self] note in
            // AltScreenChange is a value type (Sendable), but we
            // copy out the fields before hopping the actor to keep
            // strict-concurrency happy.
            guard let change = note.object as? AltScreenChange else { return }
            let paneID = change.paneID
            let isInAltScreen = change.isInAltScreen
            MainActor.assumeIsolated {
                self?.setAltScreen(paneID: paneID, isInAltScreen: isInAltScreen)
            }
        }

        // Synchronous observer for autosuggestion lookups. Same
        // architecture as the history request above — the bar
        // posts a request carrying a mutable response box, we
        // fill `response.text` before the post returns. Async
        // SwiftUI `.onReceive` wiring won't work because the bar
        // reads back the result immediately for ghost-text
        // rendering.
        suggestObserver = NotificationCenter.default.addObserver(
            forName: .rivenCommandSuggestRequest,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let request = note.object as? CommandSuggestRequest else { return }
            let prefix = request.prefix
            let responseBox = request.response
            MainActor.assumeIsolated {
                guard let self else { return }
                responseBox.text = self.suggestionForCommandBar(prefix: prefix)
            }
        }

        // BEL → audible system beep. The visual side (a bell dot on
        // the tab) is handled by InnerTabChip observing .rivenBell
        // directly — it knows its own terminalPaneID, so no state
        // needs threading through the controller / pane-graph
        // snapshot. The title label is likewise handled in the chip
        // via .rivenTerminalTitleChanged. The controller owns only
        // the centralized beep so it fires once per bell regardless
        // of which tab (if any) is visible.
        bellObserver = NotificationCenter.default.addObserver(
            forName: .rivenBell,
            object: nil,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated { NSSound.beep() }
        }
    }

    /// Returns the most-recent submitted command starting with
    /// `prefix`, or nil. Pure pass-through to the in-memory
    /// `CommandHistory` — kept here as a controller-level method
    /// (rather than wiring the bar straight to `commandHistory`)
    /// so the bar doesn't have to know about the underlying
    /// history-store shape.
    func suggestionForCommandBar(prefix: String) -> String? {
        commandHistory.suggestion(for: prefix)
    }

    /// Observer token retained for the lifetime of the controller.
    /// nonisolated(unsafe) so the deinit (nonisolated) can remove
    /// it without crossing actor boundaries.
    private nonisolated(unsafe) var historyObserver: NSObjectProtocol?
    private nonisolated(unsafe) var altScreenObserver: NSObjectProtocol?
    private nonisolated(unsafe) var suggestObserver: NSObjectProtocol?
    private nonisolated(unsafe) var bellObserver: NSObjectProtocol?

    deinit {
        if let historyObserver {
            NotificationCenter.default.removeObserver(historyObserver)
        }
        if let altScreenObserver {
            NotificationCenter.default.removeObserver(altScreenObserver)
        }
        if let suggestObserver {
            NotificationCenter.default.removeObserver(suggestObserver)
        }
        if let bellObserver {
            NotificationCenter.default.removeObserver(bellObserver)
        }
    }

    /// UserDefaults key that gates the H-15 first-run scratch tab.
    /// One-shot: once `true`, the welcome never reappears for the
    /// life of the user account.
    static let welcomeShownDefaultsKey = "Riven.welcomeShown"
    /// Marker for the one-shot sidebar-visibility migration that
    /// flips any stored `.collapsed` workspace sidebar back to
    /// `.expanded`. Bump the version suffix if a future change
    /// needs the same kind of one-shot reset.
    static let sidebarMigrationV1Key = "Riven.sidebarMigrationV1"

    /// Walk every workspace currently in the pane graph and set
    /// `sidebarState = .expanded` + bump `sidebarWidth` to at
    /// least 240. Re-persists the snapshot so the heal sticks
    /// across launches.
    private func forceExpandAllSidebars() {
        var graph = state.paneGraph
        var anyChanged = false
        for var pane in graph.panes.values {
            guard var ws = pane.workspace else { continue }
            var wsChanged = false
            if ws.sidebarState != .expanded {
                ws.sidebarState = .expanded
                wsChanged = true
            }
            if ws.sidebarWidth < 240 {
                ws.sidebarWidth = 240
                wsChanged = true
            }
            guard wsChanged else { continue }
            pane.kind = .workspace(ws)
            graph = graph.replacingPane(pane)
            anyChanged = true
        }
        if anyChanged {
            recordPaneGraph(graph)
            Task { [workspace] in
                try? await workspace.persistSnapshot()
            }
        }
    }

    /// H-15: append a primer markdown tab on first launch.
    ///
    /// We write the welcome to a real file (`~/Library/Application
    /// Support/Riven/welcome.md`) rather than seeding an in-memory
    /// scratch buffer because:
    ///   * EditorBuffer's `load` path needs a URL — the editor's
    ///     coordinator loads contents from disk when it mounts, not
    ///     from an injected string.
    ///   * A real file means Cmd+S works, the user can rename it,
    ///     and they can delete it once they're done. A pure scratch
    ///     buffer would discard their notes if they accidentally
    ///     closed the tab.
    /// The file is only written if it doesn't already exist, so a
    /// user who customized their welcome (or moved it elsewhere)
    /// won't get their copy clobbered if the gate somehow re-fires.
    /// Install Riven's optional zsh shell integration. Copies the
    /// bundled config + plugin tree to `~/.config/riven/shell/` and
    /// appends a fenced source block to `~/.zshrc`. Surfaces success
    /// or failure through the shared banner pipe.
    ///
    /// The install only affects newly-opened shells. Existing PTYs
    /// don't reload — that's how zsh works, and forcing them to
    /// would be more surprising than leaving them be.
    func installShellIntegration() {
        do {
            try shellIntegration.install()
            shellIntegrationInstalled = true
            showBanner(
                "Shell integration installed. Open a new terminal to see it.",
                kind: .success
            )
        } catch {
            showBanner(
                "Couldn't install shell integration: \(error)",
                kind: .error,
                autoDismissAfter: nil
            )
        }
    }

    /// Reverse of `installShellIntegration`. Removes the fenced
    /// block from `~/.zshrc` and deletes the destination directory.
    /// Leaves `~/.zsh_history` + `~/.z` alone — those are user data.
    func uninstallShellIntegration() {
        do {
            try shellIntegration.uninstall()
            shellIntegrationInstalled = false
            showBanner(
                "Shell integration removed.",
                kind: .info
            )
        } catch {
            showBanner(
                "Couldn't uninstall shell integration: \(error)",
                kind: .error,
                autoDismissAfter: nil
            )
        }
    }

    func openWelcomeScratchTab() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Riven", isDirectory: true)
        let welcomeURL = support.appendingPathComponent("welcome.md")
        if !FileManager.default.fileExists(atPath: welcomeURL.path) {
            let body = Self.welcomeMarkdown
            try? body.data(using: .utf8)?.write(to: welcomeURL, options: .atomic)
        }
        openFile(welcomeURL)
    }

    /// Markdown shown in the H-15 welcome tab. Kept short (~250
    /// words) and biased toward the muscle-memory shortcuts that
    /// pay off the fastest. Lives as a static so it's easy to spot-
    /// check in code review without hunting through a resource
    /// bundle.
    private static let welcomeMarkdown: String = """
# Welcome to Riven

Riven is a terminal + editor multiplexer that treats panes, tabs, and
workspaces as one connected surface.

## Try these first

- `⌘T` — new tab in the current workspace
- `⌘D` — split the focused surface to the right
- `⌘⇧D` — split it downward
- `⌘W` — close the focused tab
- `⌘N` — new workspace (own sidebar, own root directory)
- `⌘K` — clear the focused terminal
- `⌘⇧F` — search files and scrollback together
- `⌘⇧P` — open the command palette (every action is here)
- `⌃Tab` — cycle focus across surfaces inside the current tab

## A few non-obvious things

- The **command bar** at the bottom is the default writing surface.
  Click anywhere on a terminal pane and start typing — the bar
  catches the keystroke. `↑` / `↓` walk command history.
- `cd` in any terminal updates that workspace's sidebar via OSC 7.
- Drag the sidebar divider to resize; tap `‹` to collapse it into a
  56-pt icon rail. The rail keeps your favourite folders one click
  away without giving up the horizontal real estate.
- Open the command palette (`⌘⇧P`) and search "theme" to switch
  between Riven, Carbon, Tokyo Night, and Paper. The pick persists
  across launches.

## Optional: install the Riven shell integration

Riven ships with an optional zsh config that gives you:

- A minimal, theme-aware prompt that follows whichever theme you pick.
- Ghost-text completion from history (`→` or `⌃E` to accept).
- Substring history search on `↑` / `↓` — type `git ` then `↑` to
  walk every past `git …`.
- Live syntax highlighting as you type.
- `z <fragment>` for frecency-based jumps to past directories.
- OSC 7 / 133 hooks so Riven's sidebar follows `cd` and Riven can
  navigate by prompt boundaries.

Open the command palette (`⌘⇧P`) and search for **shell integration**
to install (or skip — every feature above is opt-in, and uninstalling
later is one click).

## What now?

You can rename or delete this tab — it's a regular file at
`~/Library/Application Support/Riven/welcome.md`. Happy hacking.
"""

    /// Hand off the broker connection once `AgentLauncher` finishes its
    /// startup handshake. Until this fires, terminal panes render a
    /// "connecting" placeholder.
    ///
    /// Also called by the launcher's watchdog after a respawn — in that
    /// case the previous `agentClient` is already closed and views need
    /// to rebuild against the new one. We bump `brokerEpoch` so views
    /// that key off it (`PaneGridView`, terminal tab content) tear down
    /// their cached NSViews and ask SwiftUI for a fresh build.
    ///
    /// H-5: when this fires for a **respawn** (epoch goes 1 → 2 → …,
    /// i.e. not the initial connect), we capture the focused pane +
    /// surface BEFORE the bump and re-apply them via a deferred
    /// `.rivenBrokerRespawned` post AFTER the SwiftUI tree has had a
    /// runloop tick to rebuild against the fresh client. Without this,
    /// the cached-host teardown the epoch bump triggers can leave
    /// AppKit first-responder pointed at whichever surface SwiftUI
    /// happened to mount first.
    func attachAgentClient(_ client: AgentClient) {
        // Initial connect has no prior focus to preserve; only the
        // respawn path needs the restore dance.
        let isRespawn = brokerEpoch > 0
        let preservedFocus = preservedSurfaceFocus()
        self.agentClient = client
        self.brokerEpoch &+= 1
        guard isRespawn else { return }

        // Hop the focus restore to the next runloop tick so the
        // SwiftUI tree has rebuilt against the new agentClient +
        // brokerEpoch first. Re-applying focus immediately would race
        // against the teardown of the old hosting controllers and
        // either no-op or leave AppKit pointed at a stale view.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.restorePreservedFocus(preservedFocus)
            NotificationCenter.default.post(name: .rivenBrokerRespawned, object: nil)
        }
    }

    /// Snapshot of the user's pre-respawn focus position. Pair of
    /// (workspace pane id, optional inner surface focus). Used by
    /// `attachAgentClient` to restore exactly where the user was after
    /// the broker respawn rebuilds the view tree.
    private struct PreservedFocus {
        let paneID: PaneID
        let tabFocus: (tabID: TabID, surfaceID: SurfaceID)?
    }

    private func preservedSurfaceFocus() -> PreservedFocus {
        let paneID = state.paneGraph.focusedPaneID
        if let workspace = state.paneGraph.pane(paneID)?.workspace {
            let tab = workspace.focusedTab
            return PreservedFocus(
                paneID: paneID,
                tabFocus: (tab.id, tab.focusedSurfaceID)
            )
        }
        return PreservedFocus(paneID: paneID, tabFocus: nil)
    }

    private func restorePreservedFocus(_ preserved: PreservedFocus) {
        // Re-apply the pane-graph focus first. If the focused pane
        // already matches (typical case), `focus(...)` no-ops.
        let next = state.paneGraph.focus(preserved.paneID)
        if next != state.paneGraph {
            recordPaneGraph(next)
        }
        // If we were inside a workspace, also re-apply the inner-tab
        // surface focus so the visible accent border + the
        // command-bar target route to the surface the user had
        // before the respawn.
        if let tabFocus = preserved.tabFocus {
            focusSurface(tabID: tabFocus.tabID, surfaceID: tabFocus.surfaceID)
        }
    }

    /// Open `url` in the focused workspace as an editor tab.
    ///
    /// If the focused workspace already has an editor tab pointed at
    /// `url`, focus that tab. Otherwise append a fresh editor tab and
    /// focus it. The sidebar is unchanged — that's the whole point of
    /// the Riven model: the editor lives as a peer of the terminal in
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
        // S-2: OSC 7 just reported a fresh pwd — patch the sidecar so
        // search results stamp the right cwd. The focused inner tab is
        // the one the shell is reporting from; other tabs in the same
        // workspace have their own PTYs and report independently.
        if let focusedPaneID = workspace.focusedTab.terminalPaneID {
            try? scrollback.updateMetadataCwd(paneID: focusedPaneID, cwd: cwd)
        }
        recordPaneGraph(graph)
    }

    /// Replace the tracked pane graph after a UI-driven mutation (split,
    /// focus change, pane close).
    ///
    /// Perf-critical path. Every split / close / focus-shift / OSC 7
    /// cwd update flows through here, and each one must feel instant.
    /// Two pieces of off-main work are kicked off concurrently:
    ///
    ///   * `workspace.updatePaneGraph` — actor hop to the
    ///     WorkspaceController to keep its snapshot-source-of-truth
    ///     in sync. Was already off-main.
    ///   * `syncScrollbackMetadataWithPaneGraph` — disk I/O loop
    ///     across every terminal pane to patch their sidecars. USED
    ///     to run synchronously on the main thread, so a workspace
    ///     with N panes did 2N (read + maybe-write) JSON file ops
    ///     per mutation. On a contended SSD that read as "splitting
    ///     a pane takes half a second." Moved to `Task.detached`
    ///     with a captured graph snapshot — the user sees the
    ///     SwiftUI re-render the moment `state.paneGraph` is
    ///     assigned; sidecar files catch up a few ms later off-
    ///     thread.
    func recordPaneGraph(_ graph: PaneGraph) {
        Task { [workspace] in
            await workspace.updatePaneGraph(graph)
        }
        self.state.paneGraph = graph
        // Capture the values the off-thread sync needs while we're
        // still on the main actor; PaneGraph is a value type, so the
        // closure gets its own copy.
        let projectRoot = state.projectRoot
        let store = scrollback
        Task.detached(priority: .utility) {
            Self.syncScrollbackMetadataOffThread(
                graph: graph,
                projectRoot: projectRoot,
                scrollback: store
            )
        }
        // Persist the snapshot on state change (debounced), not only
        // at quit. The terminate-time save is fragile: it doesn't run
        // on a crash / force-quit / kill, and even a clean quit caps
        // it at a 2 s timeout — so a session restored from the LAST
        // clean quit could be stale ("randomly opens older sessions").
        // Saving here keeps the on-disk snapshot continuously current.
        scheduleSnapshotSave()
    }

    /// Debounced background snapshot write. Coalesces a burst of state
    /// changes (rapid splits, a flurry of cd's) into one save ~800 ms
    /// after the last change. The save hops to the WorkspaceController
    /// actor + writes JSON off the main thread, so it never blocks the
    /// UI. The terminate-time `persistSnapshot` remains as a final
    /// flush, but the session no longer depends on a clean quit to be
    /// current.
    private func scheduleSnapshotSave() {
        snapshotSaveTask?.cancel()
        let workspace = self.workspace
        snapshotSaveTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            // `updatePaneGraph` was queued on the actor before this
            // 800 ms sleep elapsed, so `persistSnapshot` reads the
            // up-to-date graph.
            try? await workspace.persistSnapshot()
        }
    }

    private var snapshotSaveTask: Task<Void, Never>?

    /// Walk the captured pane graph and patch every terminal pane's
    /// sidecar to reflect the current project root + workspace label
    /// + inner-tab label. Runs off-main on a utility-priority
    /// detached Task; takes its dependencies as plain `Sendable`
    /// values so it never has to hop back to the controller actor.
    ///
    /// Per-pane writes are gated on a change check (no-op when
    /// nothing differs), so the steady-state cost is one cheap JSON
    /// read per terminal pane — and even those happen off the UI
    /// thread.
    nonisolated private static func syncScrollbackMetadataOffThread(
        graph: PaneGraph,
        projectRoot: String,
        scrollback: ScrollbackStore
    ) {
        for pane in graph.panes.values {
            guard let ws = pane.workspace else { continue }
            let workspaceName = ws.customName
                ?? URL(fileURLWithPath: ws.currentCwd).lastPathComponent
            for tab in ws.tabs {
                guard let paneID = tab.terminalPaneID else { continue }
                Self.enrichScrollbackMetadataOffThread(
                    paneID: paneID,
                    projectRoot: projectRoot,
                    workspaceName: workspaceName,
                    paneLabel: tab.displayName,
                    scrollback: scrollback
                )
            }
        }
    }

    /// Patch the metadata sidecar for `paneID` with whatever app-level
    /// context we know. Static / nonisolated so the off-thread sync
    /// can call it without hopping back to the controller actor.
    ///
    /// Skips the write when the sidecar doesn't exist yet (the broker
    /// may still be spawning the PTY); subsequent calls will retry.
    nonisolated private static func enrichScrollbackMetadataOffThread(
        paneID: PaneID,
        projectRoot: String?,
        workspaceName: String?,
        paneLabel: String?,
        scrollback: ScrollbackStore
    ) {
        guard var meta = try? scrollback.readMetadata(paneID) else { return }
        var changed = false
        if let projectRoot, meta.projectRoot != projectRoot {
            meta.projectRoot = projectRoot
            changed = true
        }
        if let workspaceName, meta.workspaceName != workspaceName {
            meta.workspaceName = workspaceName
            changed = true
        }
        if let paneLabel, meta.paneLabel != paneLabel {
            meta.paneLabel = paneLabel
            changed = true
        }
        guard changed else { return }
        try? scrollback.writeMetadata(meta)
    }

    /// Run a unified search (files + scrollback) against the currently
    /// open project. Used by the search overlay. `scope` selects between
    /// "this project only" (default) and "all projects" (walks every
    /// project root referenced by any scrollback sidecar).
    func search(
        _ query: String,
        scope: SearchScope = .thisProject
    ) async throws -> [UnifiedSearchResult] {
        try await workspace.search(query, scope: scope)
    }

    /// Add a brand-new top-level **workspace** (a new screen-level Riven
    /// box) rooted at `~`. Wired to Cmd+N. Each workspace owns its own
    /// sidebar and its own collection of inner terminal tabs.
    func openNewWorkspace() {
        openNewWorkspace(at: NSHomeDirectory())
    }

    /// Set the focused workspace's directory from the toolbar's
    /// editable path field. Does BOTH halves of "go here":
    ///
    ///   1. Update `workspace.currentCwd` directly → the file viewer
    ///      re-scans + the toolbar breadcrumb update IMMEDIATELY, no
    ///      shell round-trip required.
    ///   2. Send `cd '<path>'` to the focused terminal → the shell
    ///      follows so subsequent commands run from the new pwd.
    ///
    /// Earlier this only did (2) and relied on the shell emitting
    /// OSC 7 to drive the sidebar. That's fragile — it does nothing
    /// if the integration isn't installed, the shell is mid-TUI, or
    /// the cd lands in a subshell — so "set workspace directory"
    /// appeared to move the shell but not the file viewer, which
    /// defeats the point. We validate the path exists client-side
    /// before either half, so setting currentCwd directly is safe
    /// (and the eventual OSC 7, if it arrives, is an idempotent
    /// no-op against the value we already set).
    ///
    /// Path normalization:
    ///   - leading `~` expands to `$HOME`
    ///   - relative paths resolve against the workspace's current pwd
    ///   - the resolved path must exist as a directory; otherwise the
    ///     call is a no-op and returns `false` so the toolbar can
    ///     flag the bad input.
    ///
    /// No-op (returns false) when the focused surface isn't a
    /// terminal (e.g. an editor tab is focused) — there's no PTY to
    /// `cd` in that case.
    @discardableResult
    func changeFocusedShellPwd(_ raw: String) -> Bool {
        guard var pane = state.paneGraph.pane(state.paneGraph.focusedPaneID),
              var workspace = pane.workspace,
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

        // (1) Move the workspace model NOW so the file viewer follows
        // without waiting on the shell. Skip the graph re-publish if
        // the cwd is already there (no-op).
        if workspace.currentCwd != resolved {
            workspace.currentCwd = resolved
            pane.kind = .workspace(workspace)
            recordPaneGraph(state.paneGraph.replacingPane(pane))
            try? scrollback.updateMetadataCwd(paneID: paneID, cwd: resolved)
        }

        // (2) Send the cd so the shell tracks the new pwd. Single-
        // quote so paths with spaces / special chars survive.
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

    /// S-6: open an inline scrollback-peek surface for `paneID`
    /// centered on `focusLine`. Creates a new inner tab inside the
    /// focused workspace; the peek view is read-only and loads bytes
    /// from `ScrollbackStore` rather than spawning a fresh PTY.
    func openScrollbackPeek(paneID: PaneID, focusLine: Int) {
        guard var pane = state.paneGraph.pane(state.paneGraph.focusedPaneID),
              let workspace = pane.workspace else {
            return
        }
        // De-dupe: if a peek tab for this (paneID, focusLine) already
        // exists, just focus it. Cheap because peek tabs are rare.
        if let existing = workspace.tabs.first(where: { tab in
            if case let .scrollbackPeek(existingID, line) = tab.kind {
                return existingID == paneID && line == focusLine
            }
            return false
        }) {
            pane.kind = .workspace(workspace.focusingTab(existing.id))
            recordPaneGraph(state.paneGraph.replacingPane(pane))
            return
        }
        let metadata = (try? scrollback.readMetadata(paneID)) ?? nil
        let label = metadata?.paneLabel ?? "scrollback"
        let tab = WorkspaceInnerTab(
            displayName: "↪ \(label):\(focusLine)",
            kind: .scrollbackPeek(paneID: paneID, focusLine: focusLine),
            cwd: workspace.currentCwd
        )
        pane.kind = .workspace(workspace.appendingTab(tab))
        recordPaneGraph(state.paneGraph.replacingPane(pane))
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
    /// Cancel aborts the close; Save sends a `.rivenSaveSurface`
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
                        name: .rivenSaveSurface,
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
                    name: .rivenSaveSurface,
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
    /// CommandBar's onSubmit posts `.rivenCommandSubmitted` with the
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
        let result = commandHistory.previous(currentBuffer: currentBuffer)
        // H-9: surface a one-shot info toast the first time a user
        // hits up-arrow with no submitted history yet. Without this
        // the arrow does nothing — a silent dead-end that reads as
        // "this app is broken." Five-second auto-dismiss keeps it
        // out of the user's way once they get the point.
        if result == nil, commandHistory.entries.isEmpty {
            showBanner(
                "Your shell history will appear here",
                kind: .info,
                autoDismissAfter: 3
            )
        }
        return result
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

    /// H-2: mirror the editor coordinator's file-watcher signals. The
    /// view-tree consumers read from `vanishedFileSurfaces` to render
    /// the "(missing)" affordance and disable Save.
    func markSurfaceVanished(_ surfaceID: SurfaceID) {
        if !vanishedFileSurfaces.contains(surfaceID) {
            vanishedFileSurfaces.insert(surfaceID)
        }
    }

    func clearSurfaceVanished(_ surfaceID: SurfaceID) {
        vanishedFileSurfaces.remove(surfaceID)
    }

    /// Mirror a `.rivenAltScreenChanged` payload into
    /// `altScreenPaneIDs`. Called from RootView's notification
    /// wiring so SwiftUI surfaces re-evaluate (the command bar
    /// dim-while-TUI signal lands on this state).
    func setAltScreen(paneID: PaneID, isInAltScreen: Bool) {
        if isInAltScreen {
            altScreenPaneIDs.insert(paneID)
        } else {
            altScreenPaneIDs.remove(paneID)
        }
    }

    /// True when the focused inner-tab's terminal is currently on
    /// the alt screen. The global key monitor in RivenApp uses this
    /// to route every Ctrl+letter combo to the PTY whenever a TUI
    /// owns the focused tab — without it, only Ctrl+C/D/Z would
    /// reach (e.g.) nano when focus is on the command bar.
    var focusedTerminalIsInAltScreen: Bool {
        guard let pane = state.paneGraph.pane(state.paneGraph.focusedPaneID),
              let workspace = pane.workspace,
              let paneID = workspace.focusedTab.terminalPaneID else {
            return false
        }
        return altScreenPaneIDs.contains(paneID)
    }

    /// Filter `tab.surfaces` down to the editor surfaces currently
    /// tracked as dirty. Used by the close-prompt to decide whether
    /// to show the alert + which filenames to list.
    private func dirtySurfacesIn(_ tab: WorkspaceInnerTab) -> [TabSurface] {
        tab.surfaces.filter { dirtyEditorSurfaces.contains($0.id) }
    }

    /// Walk every workspace + tab + surface in `state` and collect the
    /// display filenames for editor surfaces whose ids appear in
    /// `dirtyEditorSurfaces`. Used by the quit-prompt (H-1) to list
    /// "you have unsaved changes in N file(s)" with each file enumerated.
    ///
    /// Thin wrapper over `WorkspaceState.dirtyEditorFilenames(in:)` —
    /// the actual enumeration lives in RivenCore so it can be unit-
    /// tested without instantiating the @MainActor controller (which
    /// does file I/O at init).
    func dirtyFilenames() -> [String] {
        state.dirtyEditorFilenames(in: dirtyEditorSurfaces)
    }

    /// Outcome of the H-1 quit prompt. Surfaces the user's choice to
    /// the AppDelegate as a small enum so the delegate doesn't have to
    /// know about `NSAlert` button-return codes.
    enum QuitDecision {
        /// No dirty buffers, or the user picked "Don't Save". Caller
        /// should return `.terminateNow`.
        case quitNow
        /// User picked "Save All". The controller has already posted
        /// `.rivenSaveSurface` for every dirty surface; caller should
        /// return `.terminateNow` once those posts have propagated.
        case savedAllAndQuit
        /// User picked "Cancel". Caller should return `.terminateCancel`.
        case cancel
    }

    /// Run the H-1 modal alert if any editor surface is dirty. Returns
    /// `.quitNow` synchronously when there's nothing to save. Otherwise
    /// blocks on the alert (which is fine — quit is a discrete user
    /// action) and resolves to one of the three `QuitDecision` cases.
    ///
    /// Save All posts `.rivenSaveSurface` for each dirty surface; the
    /// editor coordinators observe the notification on the main thread
    /// and write to disk synchronously before returning. By the time
    /// the post call returns, the buffers are on disk.
    @discardableResult
    func handleQuitDirtyCheck() -> QuitDecision {
        let filenames = dirtyFilenames()
        if filenames.isEmpty { return .quitNow }

        switch promptForQuit(filenames: filenames) {
        case .cancel:
            return .cancel
        case .dontSave:
            return .quitNow
        case .save:
            for surfaceID in dirtyEditorSurfaces {
                NotificationCenter.default.post(
                    name: .rivenSaveSurface,
                    object: surfaceID
                )
            }
            return .savedAllAndQuit
        }
    }

    /// Modal "you have unsaved changes" alert specifically for the
    /// app-quit path (H-1). Same three-button shape as the per-tab
    /// close prompt but with copy that reads as "quitting the whole
    /// app" rather than "closing this tab".
    private func promptForQuit(filenames: [String]) -> DirtyCloseChoice {
        let alert = NSAlert()
        switch filenames.count {
        case 1:
            alert.messageText = "Save changes to “\(filenames[0])” before quitting?"
            alert.informativeText = "Your edits will be lost otherwise."
        default:
            alert.messageText = "You have unsaved changes in \(filenames.count) file\(filenames.count == 1 ? "" : "s")."
            alert.informativeText = filenames.map { "• \($0)" }.joined(separator: "\n")
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save All")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .dontSave
        default: return .cancel
        }
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
    /// Wired to Cmd+K (see `RivenApp.installMenu`) and routed through
    /// the `.rivenClearFocusedTerminal` notification so menu, palette,
    /// and any future entry point can converge on one path.
    func clearFocusedTerminal() {
        sendByteToFocusedTerminal(0x0C)
    }

    /// Generic byte-write helper for the global Ctrl+C / Ctrl+D /
    /// Ctrl+Z monitor in RivenApp. Editor tabs no-op — there's no PTY
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
    /// Wired to the `rivenCloseEditor` notification; the editor column
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

    /// Trust the currently open project so its `.riven/session.yml` task
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

    /// Clear `state.projectFallbackReason` after the user acknowledges
    /// the "project moved or deleted" banner. The cwd we landed in
    /// (`~`) stays put — only the banner copy goes away.
    func dismissProjectFallbackReason() {
        guard state.projectFallbackReason != nil else { return }
        state.projectFallbackReason = nil
    }

    /// H-6: surface a toast-style banner above the focused workspace.
    /// Replaces any banner currently on screen — no queue. Callers
    /// override `autoDismissAfter` to nil for sticky warnings the
    /// user has to acknowledge with the ×. Default 5s lines up with
    /// the macOS notification-banner dwell.
    ///
    /// This is the canonical path for *non-destructive* feedback —
    /// editor save failures, search-engine errors, project fallback
    /// notices, "your shell history will appear here," etc. Anything
    /// that blocks the user (close-dirty, quit-dirty) still uses
    /// NSAlert.
    func showBanner(
        _ message: String,
        kind: BannerKind,
        autoDismissAfter: TimeInterval? = 5
    ) {
        currentBanner = RivenBannerState(
            message: message,
            kind: kind,
            autoDismissAfter: autoDismissAfter
        )
    }

    /// Drop the current banner. Wired to the × button on the banner
    /// view AND fired by the SwiftUI auto-dismiss task once the
    /// configured delay elapses.
    func dismissBanner() {
        currentBanner = nil
    }

    /// Cycle to the next theme. Wired through `CommandAction.cycleTheme`.
    /// Walks `ThemeSpec.all()` so user-authored customs (T-6) are part
    /// of the rotation, not just the four builtins.
    func cycleTheme() {
        let all = ThemeSpec.all()
        guard !all.isEmpty else { return }
        let current = preference.selectedTheme.id
        let nextIdx = (all.firstIndex(where: { $0.id == current }).map { $0 + 1 } ?? 0) % all.count
        selectTheme(id: all[nextIdx].id)
    }

    /// Persist `id` as the active theme and republish `state` so every
    /// SwiftUI surface re-renders with the new chrome on the next
    /// runloop tick. Tolerates unknown ids by no-op'ing — the
    /// `ThemePreferenceStore` throws on bad input and we silently
    /// swallow rather than crash the menu/palette/swatch flow on a
    /// stale custom-theme id.
    func selectTheme(id: String) {
        guard ThemeSpec.theme(id: id) != nil else { return }
        try? preference.selectTheme(id: id)
        if self.state.selectedThemeID != id {
            self.state.selectedThemeID = id
        }
    }

    private static func fallbackState(cwd: URL, themeID: String) -> WorkspaceState {
        // Empty tree STUB only — do NOT scan here. This runs
        // synchronously inside `RivenRootController.init`, which is
        // @MainActor, so a real `ProjectFileTree.scan` would block
        // the main thread on a depth-3 filesystem walk during launch
        // — for a home directory (the cwd when launched from Finder)
        // that's a multi-second hang before the window even draws.
        // The real tree arrives off-thread two ways: the sidebar's
        // cached async `loadTree`, and the controller's `openProject`
        // Task (WorkspaceController is an actor, scan runs on its
        // executor). Both populate `fileTree` shortly after launch
        // without blocking the first frame.
        let tree = ProjectFileTree(name: cwd.lastPathComponent, path: cwd.path, kind: .directory)
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

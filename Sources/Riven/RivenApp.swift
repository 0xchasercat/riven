import AppKit
import RivenCore
import Combine
import SwiftUI

@main
@MainActor
final class RivenApplication: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var rootController: RivenRootController?
    private var titleSubscription: AnyCancellable?
    /// Local NSEvent monitor for the global Tab-snap behavior. Tab from
    /// anywhere outside a text-input surface routes focus to the
    /// command bar. Stored on the delegate so the monitor lives as
    /// long as the app does. Removed in `applicationWillTerminate`.
    private var tabFocusMonitor: Any?

    static func main() {
        let app = NSApplication.shared
        let delegate = RivenApplication()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()

        // Initialize the process-wide libghostty app before any surface
        // is built. Terminal panes spawn their PTY in-process via
        // `GhosttyApp.shared` — there is no out-of-process broker.
        _ = GhosttyApp.shared

        let controller = RivenRootController()
        self.rootController = controller

        let hosting = NSHostingController(rootView: RivenRootView().environmentObject(controller))
        let window = NSWindow(contentViewController: hosting)
        window.title = Self.windowTitle(for: controller.state)
        window.setContentSize(NSSize(width: 1600, height: 1000))
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        // Tab from anywhere outside a text-input or terminal surface
        // routes focus to the command bar — Riven's default writing
        // surface. Inside the command bar's NSTextView, Tab inserts
        // "\t" (shell heredocs); inside the editor it indents; inside a
        // focused terminal surface it reaches the PTY (shell completion).
        //
        // Control keys (Ctrl+C/D/Z and friends) are NOT intercepted
        // anymore: the focused ghostty surface owns its keyboard input
        // and handles them natively. To interrupt a running command,
        // focus the terminal (click it) and press Ctrl+C as usual.
        tabFocusMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let responder = NSApp.keyWindow?.firstResponder

            // Tab keyCode is 48 on every modern Mac keyboard layout.
            // Only intercept bare Tab — Shift+Tab keeps native
            // backward focus traversal so Cocoa's keyView chain still
            // works for accessibility users.
            guard event.keyCode == 48, mods.isEmpty else { return event }

            if responder is CommandInputTextView {
                // Already in the bar — let Tab insert "\t" as normal.
                return event
            }
            if responder is EditorTextView {
                // Editor pane — Tab indents in the buffer.
                return event
            }
            if responder is SurfacePaneView {
                // Focused terminal — Tab is real PTY input (completion).
                return event
            }
            // Anywhere else: snap to the command bar and consume the
            // event so the previous responder doesn't ALSO see the
            // tab (e.g. NSTextField would otherwise commit + beep).
            NotificationCenter.default.post(name: .rivenFocusCommandBar, object: nil)
            return nil
        }

        // Reflect the focused workspace in the window title. Even with
        // titleVisibility = .hidden the title still shows in Mission
        // Control / Stage Manager / Cmd+Tab previews, and many users
        // toggle title visibility on. Keep both the WorkspaceTabBar
        // (interactive switcher) and the title (passive cue).
        // Project state changes a lot more often than the window
        // title needs to update (every keystroke routed through the
        // controller, every OSC 7 cwd report, every dirty flag flip).
        // Map to the derived title string up-front + `removeDuplicates`
        // so we only touch `NSWindow.title` when the visible label
        // actually changed. `NSWindow.title =` is a Cocoa setter that
        // fires accessibility notifications and a window-title-bar
        // redraw, so even the no-op writes added up.
        titleSubscription = controller.$state
            .map(Self.windowTitle(for:))
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak window] title in
                MainActor.assumeIsolated {
                    window?.title = title
                    _ = self // keep the closure capture alive
                }
            }

        // One-shot Full Disk Access onboarding. A terminal genuinely
        // needs broad filesystem read access; without FDA the user
        // gets a per-folder TCC prompt on every cd into a protected
        // directory. Deferred a beat so the main window is on screen
        // before the alert (an alert with no window behind it reads
        // as a crash dialog). Skipped silently if FDA is already
        // granted or the user dismissed it with "Don't ask again."
        DispatchQueue.main.async {
            FullDiskAccess.promptIfNeeded()
        }
    }

    /// Build the window title from the focused workspace. Falls back to
    /// "Riven" before the controller has settled on a real state. If the
    /// graph has more than one workspace tab, suffixes the count so the
    /// user can tell at a glance how many parallel boxes are open.
    private static func windowTitle(for state: WorkspaceState) -> String {
        let leaves = state.paneGraph.leaves()
        guard let focused = leaves.first(where: { $0.id == state.paneGraph.focusedPaneID })
            ?? leaves.first
        else { return "Riven" }

        let base: String
        if let ws = focused.workspace {
            let last = URL(fileURLWithPath: ws.currentCwd).lastPathComponent
            base = last.isEmpty ? "workspace" : last
        } else {
            base = focused.name.isEmpty ? "Riven" : focused.name
        }

        if leaves.count > 1 {
            return "\(base) · \(leaves.count) workspaces"
        }
        return base
    }

    /// H-1: prompt the user before quitting if any editor surface has
    /// unsaved changes. Returns `.terminateCancel` only when the user
    /// picks "Cancel" — both "Save All" and "Don't Save" proceed to
    /// shutdown (Save All synchronously flushes each dirty buffer
    /// before the terminate continues, via `.rivenSaveSurface` posts
    /// the editor coordinators observe on the main thread).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // No controller yet (terminate fired before launch finished) —
        // nothing to lose, let the OS shut us down.
        guard let controller = rootController else { return .terminateNow }
        switch controller.handleQuitDirtyCheck() {
        case .quitNow, .savedAllAndQuit:
            return .terminateNow
        case .cancel:
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let tabFocusMonitor {
            NSEvent.removeMonitor(tabFocusMonitor)
            self.tabFocusMonitor = nil
        }
        // Persist the workspace snapshot on the way out so relaunch can
        // restore the tab/split/cwd layout (the in-process PTYs die with
        // the app — only the layout is restored, not live processes).
        let workspace = rootController?.workspace
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            if let workspace { try? await workspace.persistSnapshot() }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + .seconds(2))
    }

    private func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        // Riven → Preferences → Theme… opens the picker overlay (T-5).
        // Keep the Preferences entry as a submenu so future preferences
        // (font size, scrollback, etc.) can land next to it without
        // another menu rewrite.
        let prefsItem = NSMenuItem(title: "Preferences", action: nil, keyEquivalent: "")
        let prefsMenu = NSMenu(title: "Preferences")
        let themePickerItem = NSMenuItem(
            title: "Theme\u{2026}",
            action: #selector(showThemePicker),
            keyEquivalent: ""
        )
        prefsMenu.addItem(themePickerItem)
        // T-6: a discoverable hop into the custom-themes folder. Seeds
        // a starter `riven-default.json` on first reveal so the user
        // has a concrete template to crib from.
        let revealThemesItem = NSMenuItem(
            title: "Reveal Themes Folder",
            action: #selector(revealThemesFolder),
            keyEquivalent: ""
        )
        prefsMenu.addItem(revealThemesItem)
        prefsMenu.addItem(NSMenuItem.separator())
        // Z-4: shell integration toggle. The validateMenuItem hook
        // below swaps the title between "Install Shell Integration…"
        // and "Uninstall Shell Integration" based on live disk state.
        // Tag = 4221 lets validateMenuItem find this item without
        // matching on the title (which we're going to mutate).
        let shellItem = NSMenuItem(
            title: "Install Shell Integration\u{2026}",
            action: #selector(toggleShellIntegration),
            keyEquivalent: ""
        )
        shellItem.tag = 4221
        prefsMenu.addItem(shellItem)
        prefsMenu.addItem(
            NSMenuItem(
                title: "Grant Full Disk Access\u{2026}",
                action: #selector(grantFullDiskAccess),
                keyEquivalent: ""
            )
        )
        prefsItem.submenu = prefsMenu
        appMenu.addItem(prefsItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Riven", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        // File menu. Cmd+T = new inner tab (within the focused workspace,
        // shares its sidebar). Cmd+N = new workspace (top-level, full
        // Riven workspace with its own sidebar, defaults to ~).
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(title: "New Tab", action: #selector(newTab), keyEquivalent: "t"))
        fileMenu.addItem(NSMenuItem(title: "New Workspace", action: #selector(newWorkspace), keyEquivalent: "n"))
        fileMenu.addItem(NSMenuItem.separator())
        // Cmd+D splits the focused tab's focused surface to the right;
        // Cmd+Shift+D splits it downward. Matches iTerm2 / Warp.
        fileMenu.addItem(NSMenuItem(
            title: "Split Right",
            action: #selector(splitRight),
            keyEquivalent: "d"
        ))
        let splitDownItem = NSMenuItem(
            title: "Split Down",
            action: #selector(splitDown),
            keyEquivalent: "d"
        )
        splitDownItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(splitDownItem)
        // Ctrl+Tab cycles focus across surfaces within the focused tab.
        // Uses the raw tab character (0x09) + .control modifier; we
        // can't bind via keyEquivalent for the tab key cleanly, so
        // it's handled by the existing keyboard-shortcut path in
        // RivenPaneContainerView. Documented here for discoverability.
        let cycleItem = NSMenuItem(
            title: "Cycle Surface Focus",
            action: #selector(cycleSurfaceFocus),
            keyEquivalent: "]"
        )
        cycleItem.keyEquivalentModifierMask = [.command]
        fileMenu.addItem(cycleItem)
        // Cmd+Shift+O: open another directory as a workspace tab.
        let openItem = NSMenuItem(title: "Open Project…", action: #selector(openProject), keyEquivalent: "o")
        openItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(openItem)
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(NSMenuItem(title: "Close Tab", action: #selector(closeTab), keyEquivalent: "w"))
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        // Standard Edit menu. Without this, Cmd+A/C/V/X/Z don't work
        // inside the command bar's NSTextView (or anywhere else with a
        // text editor) — macOS dispatches the standard edit commands
        // through menu key equivalents, not through individual views'
        // performKeyEquivalent. Each NSMenuItem uses nil action so the
        // selector resolves dynamically against the first responder,
        // which is the canonical pattern for the responder-chain-driven
        // edit menu.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: #selector(UndoManager.undo), keyEquivalent: "z"))
        let redoItem = NSMenuItem(title: "Redo", action: #selector(UndoManager.redo), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        main.addItem(editItem)

        let commandItem = NSMenuItem()
        let commandMenu = NSMenu(title: "Commands")
        // Cmd+Shift+P — matches VSCode's command-palette muscle memory.
        // Freed up Cmd+K for the "clear focused terminal" binding below.
        let paletteItem = NSMenuItem(
            title: "Command Palette",
            action: #selector(showCommandPalette),
            keyEquivalent: "p"
        )
        paletteItem.keyEquivalentModifierMask = [.command, .shift]
        commandMenu.addItem(paletteItem)
        commandMenu.addItem(NSMenuItem(title: "Search Files and Scrollback", action: #selector(showSearch), keyEquivalent: "F"))
        // Cmd+K → clear focused terminal. We send a Ctrl+L (0x0C) byte to
        // the focused workspace's terminal tab, which is what every shell
        // is already wired to treat as "clear screen". Editor tabs are a
        // no-op for this binding.
        let clearItem = NSMenuItem(
            title: "Clear Terminal",
            action: #selector(clearTerminal),
            keyEquivalent: "k"
        )
        clearItem.keyEquivalentModifierMask = [.command]
        commandMenu.addItem(clearItem)
        commandItem.submenu = commandMenu
        main.addItem(commandItem)

        // Help menu (H-16). macOS auto-merges system entries into the
        // menu titled "Help", so we use that exact title and add our
        // own two items at the top. The cheatsheet posts a
        // notification RivenRootView observes; About is the standard
        // AppKit panel populated from Info.plist (or sensible
        // defaults when running unbundled).
        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        let cheatsheetItem = NSMenuItem(
            title: "Riven Keyboard Shortcuts",
            action: #selector(showShortcutsCheatsheet),
            keyEquivalent: "?"
        )
        // Cmd+? is conventionally shift-modified on US layouts (`?`
        // already requires Shift) so AppKit picks up the right glyph
        // without us explicitly setting `.shift`.
        helpMenu.addItem(cheatsheetItem)
        helpMenu.addItem(NSMenuItem(
            title: "About Riven",
            action: #selector(showAboutPanel),
            keyEquivalent: ""
        ))
        helpItem.submenu = helpMenu
        main.addItem(helpItem)

        NSApplication.shared.mainMenu = main
        // Tell AppKit which menu is the user-visible "Help" so it
        // can prepend the system search field at the top.
        NSApplication.shared.helpMenu = helpMenu
    }

    @objc private func showCommandPalette() {
        NotificationCenter.default.post(name: .rivenShowCommandPalette, object: nil)
    }

    @objc private func showSearch() {
        NotificationCenter.default.post(name: .rivenShowSearch, object: nil)
    }

    @objc private func grantFullDiskAccess() {
        // Menu-triggered: always show (no suppression), even if the
        // launch-time prompt was dismissed. If FDA is already
        // granted, say so rather than deep-linking pointlessly.
        if FullDiskAccess.isGranted {
            let alert = NSAlert()
            alert.messageText = "Full Disk Access already granted"
            alert.informativeText = "Riven can read everywhere you navigate. No action needed."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } else {
            FullDiskAccess.present(isReprompt: true)
        }
    }

    @objc private func newTab() {
        NotificationCenter.default.post(name: .rivenNewTab, object: nil)
    }

    @objc private func newWorkspace() {
        NotificationCenter.default.post(name: .rivenNewWorkspace, object: nil)
    }

    @objc private func closeTab() {
        NotificationCenter.default.post(name: .rivenCloseTab, object: nil)
    }

    @objc private func openProject() {
        NotificationCenter.default.post(name: .rivenOpenProject, object: nil)
    }

    @objc private func clearTerminal() {
        NotificationCenter.default.post(name: .rivenClearFocusedTerminal, object: nil)
    }

    @objc private func splitRight() {
        NotificationCenter.default.post(name: .rivenSplitFocusedSurface, object: SplitDirection.right)
    }

    @objc private func splitDown() {
        NotificationCenter.default.post(name: .rivenSplitFocusedSurface, object: SplitDirection.down)
    }

    @objc private func cycleSurfaceFocus() {
        NotificationCenter.default.post(name: .rivenCycleSurfaceFocus, object: nil)
    }

    @objc private func showThemePicker() {
        NotificationCenter.default.post(name: .rivenShowThemePicker, object: nil)
    }

    /// Open Finder at the user's themes directory so they can drop in
    /// custom `*.json` theme files. Seeds a starter template the first
    /// time so newcomers have something to crib from rather than an
    /// empty folder.
    @objc private func revealThemesFolder() {
        let dir = CustomThemeLoader.defaultDirectory()
        CustomThemeLoader.seedDefaultTemplate(directory: dir)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    @objc private func showShortcutsCheatsheet() {
        NotificationCenter.default.post(name: .rivenShowShortcutsCheatsheet, object: nil)
    }

    @objc private func showAboutPanel() {
        // Force-activate first so the panel appears in front rather
        // than tucked behind the workspace window — `orderFront` alone
        // doesn't bring the app forward when it's already key.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    /// Z-4: install (or uninstall) Riven's optional zsh shell
    /// integration. Routes through `RivenRootController` so the
    /// install/uninstall path and the banner surfacing match the
    /// palette + first-run flows.
    @objc private func toggleShellIntegration() {
        guard let controller = rootController else { return }
        if controller.shellIntegrationInstalled {
            controller.uninstallShellIntegration()
        } else {
            controller.installShellIntegration()
        }
    }

    /// Refresh the shell-integration menu item's title each time the
    /// menu opens. Cheaper than observing the controller; the menu
    /// is consulted on click which is the only time the user sees
    /// the title anyway.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.tag == 4221 {
            let installed = rootController?.shellIntegrationInstalled ?? false
            menuItem.title = installed
                ? "Uninstall Shell Integration"
                : "Install Shell Integration\u{2026}"
        }
        return true
    }
}

extension Notification.Name {
    static let rivenShowCommandPalette = Notification.Name("RivenShowCommandPalette")
    static let rivenShowSearch = Notification.Name("RivenShowSearch")
    /// Posted by the Preferences → Theme… menu item and the palette's
    /// `Pick theme…` command. `RivenRootView` listens and shows the
    /// `ThemePicker` overlay in dismissible mode (esc closes).
    static let rivenShowThemePicker = Notification.Name("RivenShowThemePicker")
    static let rivenNewTab = Notification.Name("RivenNewTab")
    static let rivenNewWorkspace = Notification.Name("RivenNewWorkspace")
    static let rivenCloseTab = Notification.Name("RivenCloseTab")
    static let rivenCloseEditor = Notification.Name("RivenCloseEditor")
    static let rivenToggleSidebar = Notification.Name("RivenToggleSidebar")
    static let rivenOpenProject = Notification.Name("RivenOpenProject")
    static let rivenClearFocusedTerminal = Notification.Name("RivenClearFocusedTerminal")
    /// Posted when a terminal pane is clicked. CommandInputTextView
    /// listens and grabs first-responder so the user can immediately
    /// type — the command bar is the default writing surface in Riven.
    static let rivenFocusCommandBar = Notification.Name("RivenFocusCommandBar")
    /// Posted when a within-tab split surface is clicked. The
    /// notification's `object` is a `SurfaceFocus` payload identifying
    /// `(tabID, surfaceID)`; RootView routes to
    /// `controller.focusSurface(...)`.
    static let rivenFocusSurface = Notification.Name("RivenFocusSurface")
    /// Posted by Cmd+D / Cmd+Shift+D / the [][] button. Object is the
    /// requested `SplitDirection` (`.right` or `.down`). RootView →
    /// controller.splitFocusedSurface.
    static let rivenSplitFocusedSurface = Notification.Name("RivenSplitFocusedSurface")
    /// Posted when the per-surface close-× is clicked. Object is a
    /// `SurfaceFocus` payload. RootView → controller.closeSurface.
    static let rivenCloseSurface = Notification.Name("RivenCloseSurface")
    /// Posted by Ctrl+Tab when the user wants to cycle focus to the
    /// next surface within the currently-focused tab.
    static let rivenCycleSurfaceFocus = Notification.Name("RivenCycleSurfaceFocus")
    /// Posted by the controller when closing a tab/surface with a
    /// dirty editor and the user picks "Save" in the prompt. Object
    /// is the SurfaceID. EditorTabContent observes this; the matching
    /// editor's coordinator runs its save synchronously before the
    /// close proceeds.
    static let rivenSaveSurface = Notification.Name("RivenSaveSurface")
    /// Posted by the editor toolbar's Undo button. Object is the
    /// SurfaceID. The matching editor's coordinator triggers
    /// `textView.undoManager?.undo()`. Cmd+Z still works via the
    /// standard Edit menu; this is the button-driven path.
    static let rivenUndoSurface = Notification.Name("RivenUndoSurface")
    /// Posted by EditorTabContent whenever its underlying buffer's
    /// dirty flag flips. Object is an `EditorDirtyChange` payload.
    /// RootView routes to `controller.setSurfaceDirty(_:, dirty:)`.
    static let rivenEditorDirtyChanged = Notification.Name("RivenEditorDirtyChanged")
    /// H-2: posted by the editor's file-watcher when the open file is
    /// deleted or renamed underneath us. Object is the SurfaceID. The
    /// controller mirrors into `vanishedFileSurfaces` so toolbar +
    /// inner-tab-strip can render the "(missing)" affordance and
    /// disable Save.
    static let rivenEditorFileVanished = Notification.Name("RivenEditorFileVanished")
    /// H-2 companion: posted when the editor reopens / re-saves a
    /// previously-vanished file. Object is the SurfaceID. The
    /// controller drops the surface from `vanishedFileSurfaces`.
    static let rivenEditorFileRestored = Notification.Name("RivenEditorFileRestored")
    /// Posted by the command bar on every textDidChange to ask the
    /// controller for an autosuggestion. Object is a
    /// `CommandSuggestRequest`; the observer fills `response.text`
    /// synchronously before the post returns.
    static let rivenCommandSuggestRequest = Notification.Name("RivenCommandSuggestRequest")
    /// A terminal pane rang the bell (BEL / 0x07). Object is the PaneID.
    static let rivenBell = Notification.Name("RivenBell")
    /// A terminal pane's shell exited / surface asked to close. Object
    /// is the PaneID. The controller closes the matching surface so a
    /// `exit`-ed shell tears its pane down (libghostty owns the PTY now,
    /// so this replaces the old broker child-exit path).
    static let rivenTerminalPaneExited = Notification.Name("RivenTerminalPaneExited")
    /// A terminal pane's OSC 0/2 title changed. Object is a
    /// `TerminalTitleChange` (paneID + title, nil = cleared).
    static let rivenTerminalTitleChanged = Notification.Name("RivenTerminalTitleChanged")
    /// Posted by the sidebar header's expand-all / collapse-all
    /// toggle. Object is `NSNumber(value: Bool)` — true = expand
    /// all rows, false = collapse all. Every WorkspaceFileRow
    /// listens and sets its isExpanded accordingly.
    static let rivenSidebarSetAllExpanded = Notification.Name("RivenSidebarSetAllExpanded")
    /// Posted by the command bar after a successful submit. Object
    /// is the submitted text (NSString). RootView routes to
    /// `controller.recordCommandSubmission(_:)`.
    static let rivenCommandSubmitted = Notification.Name("RivenCommandSubmitted")
    /// Posted by the command bar's up/down-arrow handler. Object is
    /// a `CommandHistoryRequest` carrying the direction, the user's
    /// current draft (so a later down-arrow can restore it), and a
    /// mutable response box the controller writes the recalled text
    /// into. NotificationCenter.post is synchronous, so by the time
    /// the post call returns, `response.text` is filled (or nil if
    /// there's no further history in that direction).
    static let rivenCommandHistoryRequest = Notification.Name("RivenCommandHistoryRequest")
    /// H-16: posted by the Help menu's "Riven Keyboard Shortcuts"
    /// item (⌘?). RootView listens and toggles the cheatsheet
    /// overlay open.
    static let rivenShowShortcutsCheatsheet = Notification.Name("RivenShowShortcutsCheatsheet")
}

/// Payload for `.rivenTerminalTitleChanged`. `title` nil means the
/// program cleared its title — the tab label falls back to its
/// cwd-derived default.
struct TerminalTitleChange: Equatable, Sendable {
    let paneID: PaneID
    let title: String?
}

/// Direction the command bar wants to walk through history.
enum CommandHistoryDirection {
    case previous
    case next
}

/// Mutable response carrier for `.rivenCommandHistoryRequest`. The
/// reference semantics let the controller-side observer write the
/// recalled text directly into the same object the requester is
/// holding, sidestepping notification-as-RPC awkwardness.
/// Mutable response box used by the synchronous request-response
/// gesture on `.rivenCommandHistoryRequest`. The notification poster
/// hands us a reference, the observer fills `text` before
/// `NotificationCenter.post` returns, and the poster reads it on
/// the same call. `@unchecked Sendable` because the actual usage
/// is single-writer single-reader on the main thread — there's no
/// cross-thread mutation despite the class shape.
final class CommandHistoryResponse: @unchecked Sendable {
    var text: String?
    init() { self.text = nil }
}

/// Payload for `.rivenCommandSuggestRequest`. The bar emits one of
/// these every time the user's typed text changes; the controller's
/// synchronous observer fills `response.text` with the most-recent
/// matching history entry (or leaves it nil if nothing matches).
/// The bar then renders the suffix as ghost text.
final class CommandSuggestResponse: @unchecked Sendable {
    var text: String?
    init() { self.text = nil }
}

struct CommandSuggestRequest {
    let prefix: String
    let response: CommandSuggestResponse
}

/// Payload for `.rivenCommandHistoryRequest`. Combines the inputs
/// (direction + current draft) and the output channel (response box).
struct CommandHistoryRequest {
    let direction: CommandHistoryDirection
    let currentBuffer: String
    let response: CommandHistoryResponse
}

/// Payload for `.rivenEditorDirtyChanged`. Equatable so the value can
/// sit in `@State` without ceremony and so NotificationCenter doesn't
/// trip over `Any?` shape inference.
struct EditorDirtyChange: Equatable {
    let surfaceID: SurfaceID
    let isDirty: Bool
}

/// Carries a `(tabID, surfaceID)` pair as an `Any?` object payload
/// for `.rivenFocusSurface` and `.rivenCloseSurface` notifications.
/// Equatable so the value can sit in `@State` without ceremony.
struct SurfaceFocus: Equatable {
    let tabID: TabID
    let surfaceID: SurfaceID
}

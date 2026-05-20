import AppKit
import BentoCore
import Combine
import SwiftUI

@main
@MainActor
final class BentoApplication: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var rootController: BentoRootController?
    private var agentLauncher: AgentLauncher?
    private var titleSubscription: AnyCancellable?
    /// Local NSEvent monitor for the global Tab-snap behavior. Tab from
    /// anywhere outside a text-input surface routes focus to the
    /// command bar. Stored on the delegate so the monitor lives as
    /// long as the app does. Removed in `applicationWillTerminate`.
    private var tabFocusMonitor: Any?

    static func main() {
        let app = NSApplication.shared
        let delegate = BentoApplication()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()

        let controller = BentoRootController()
        self.rootController = controller

        let launcher = AgentLauncher()
        // Wire the launcher's respawn callback to the controller so
        // terminal panes can rebuild against the fresh broker when the
        // watchdog brings one back up.
        launcher.onClientReplaced = { [weak controller] client in
            controller?.attachAgentClient(client)
        }
        self.agentLauncher = launcher

        // Spin up the broker and hand the connected client to the
        // controller. Until this finishes, terminal panes render a
        // "connecting to broker" placeholder.
        Task { [weak controller] in
            do {
                try await launcher.start()
                let client = try await launcher.client()
                controller?.attachAgentClient(client)
            } catch {
                NSLog("BentoAgent launch failed: \(error)")
            }
        }

        let hosting = NSHostingController(rootView: BentoRootView().environmentObject(controller))
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

        // Tab from anywhere outside a text-input view routes focus to
        // the command bar. The command bar is the default writing
        // surface in Bento — clicks already bounce there (BrokeredTerm-
        // inalView.mouseDown), and the user expects Tab to behave the
        // same way. Inside the command bar's own NSTextView, Tab still
        // inserts `\t` (useful for shell heredocs); inside the editor
        // pane's STTextView it indents (useful for code). Anywhere
        // else (workspace path field, sidebar, tab bar, terminal grid
        // chrome), Tab snaps to the bar.
        tabFocusMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Tab keyCode is 48 on every modern Mac keyboard layout.
            // Only intercept bare Tab — Shift+Tab keeps native
            // backward focus traversal so Cocoa's keyView chain still
            // works for accessibility users.
            guard
                event.keyCode == 48,
                event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
            else { return event }

            let responder = NSApp.keyWindow?.firstResponder
            if responder is CommandInputTextView {
                // Already in the bar — let Tab insert "\t" as normal.
                return event
            }
            if responder is EditorTextView {
                // Editor pane — Tab indents in the buffer.
                return event
            }
            // Anywhere else: snap to the command bar and consume the
            // event so the previous responder doesn't ALSO see the
            // tab (e.g. NSTextField would otherwise commit + beep).
            NotificationCenter.default.post(name: .bentoFocusCommandBar, object: nil)
            return nil
        }

        // Reflect the focused workspace in the window title. Even with
        // titleVisibility = .hidden the title still shows in Mission
        // Control / Stage Manager / Cmd+Tab previews, and many users
        // toggle title visibility on. Keep both the WorkspaceTabBar
        // (interactive switcher) and the title (passive cue).
        titleSubscription = controller.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak window] state in
                MainActor.assumeIsolated {
                    window?.title = Self.windowTitle(for: state)
                    _ = self // keep the closure capture alive
                }
            }
    }

    /// Build the window title from the focused workspace. Falls back to
    /// "Bento" before the controller has settled on a real state. If the
    /// graph has more than one workspace tab, suffixes the count so the
    /// user can tell at a glance how many parallel boxes are open.
    private static func windowTitle(for state: WorkspaceState) -> String {
        let leaves = state.paneGraph.leaves()
        guard let focused = leaves.first(where: { $0.id == state.paneGraph.focusedPaneID })
            ?? leaves.first
        else { return "Bento" }

        let base: String
        if let ws = focused.workspace {
            let last = URL(fileURLWithPath: ws.currentCwd).lastPathComponent
            base = last.isEmpty ? "workspace" : last
        } else {
            base = focused.name.isEmpty ? "Bento" : focused.name
        }

        if leaves.count > 1 {
            return "\(base) · \(leaves.count) workspaces"
        }
        return base
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let tabFocusMonitor {
            NSEvent.removeMonitor(tabFocusMonitor)
            self.tabFocusMonitor = nil
        }
        let workspace = rootController?.workspace
        let launcher = agentLauncher
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            if let workspace { try? await workspace.persistSnapshot() }
            await launcher?.shutdown()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + .seconds(2))
    }

    private func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Bento", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        // File menu. Cmd+T = new inner tab (within the focused workspace,
        // shares its sidebar). Cmd+N = new workspace (top-level, full
        // bento box with its own sidebar, defaults to ~).
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(title: "New Tab", action: #selector(newTab), keyEquivalent: "t"))
        fileMenu.addItem(NSMenuItem(title: "New Workspace", action: #selector(newWorkspace), keyEquivalent: "n"))
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
        NSApplication.shared.mainMenu = main
    }

    @objc private func showCommandPalette() {
        NotificationCenter.default.post(name: .bentoShowCommandPalette, object: nil)
    }

    @objc private func showSearch() {
        NotificationCenter.default.post(name: .bentoShowSearch, object: nil)
    }

    @objc private func newTab() {
        NotificationCenter.default.post(name: .bentoNewTab, object: nil)
    }

    @objc private func newWorkspace() {
        NotificationCenter.default.post(name: .bentoNewWorkspace, object: nil)
    }

    @objc private func closeTab() {
        NotificationCenter.default.post(name: .bentoCloseTab, object: nil)
    }

    @objc private func openProject() {
        NotificationCenter.default.post(name: .bentoOpenProject, object: nil)
    }

    @objc private func clearTerminal() {
        NotificationCenter.default.post(name: .bentoClearFocusedTerminal, object: nil)
    }
}

extension Notification.Name {
    static let bentoShowCommandPalette = Notification.Name("BentoShowCommandPalette")
    static let bentoShowSearch = Notification.Name("BentoShowSearch")
    static let bentoNewTab = Notification.Name("BentoNewTab")
    static let bentoNewWorkspace = Notification.Name("BentoNewWorkspace")
    static let bentoCloseTab = Notification.Name("BentoCloseTab")
    static let bentoCloseEditor = Notification.Name("BentoCloseEditor")
    static let bentoToggleSidebar = Notification.Name("BentoToggleSidebar")
    static let bentoOpenProject = Notification.Name("BentoOpenProject")
    static let bentoClearFocusedTerminal = Notification.Name("BentoClearFocusedTerminal")
    /// Posted when a terminal pane is clicked. CommandInputTextView
    /// listens and grabs first-responder so the user can immediately
    /// type — the command bar is the default writing surface in Bento.
    static let bentoFocusCommandBar = Notification.Name("BentoFocusCommandBar")
}

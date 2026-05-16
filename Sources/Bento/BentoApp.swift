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
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(NSMenuItem(title: "Close Tab", action: #selector(closeTab), keyEquivalent: "w"))
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let commandItem = NSMenuItem()
        let commandMenu = NSMenu(title: "Commands")
        commandMenu.addItem(NSMenuItem(title: "Command Palette", action: #selector(showCommandPalette), keyEquivalent: "k"))
        commandMenu.addItem(NSMenuItem(title: "Search Files and Scrollback", action: #selector(showSearch), keyEquivalent: "F"))
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
}

extension Notification.Name {
    static let bentoShowCommandPalette = Notification.Name("BentoShowCommandPalette")
    static let bentoShowSearch = Notification.Name("BentoShowSearch")
    static let bentoNewTab = Notification.Name("BentoNewTab")
    static let bentoNewWorkspace = Notification.Name("BentoNewWorkspace")
    static let bentoCloseTab = Notification.Name("BentoCloseTab")
    static let bentoCloseEditor = Notification.Name("BentoCloseEditor")
    static let bentoToggleSidebar = Notification.Name("BentoToggleSidebar")
}

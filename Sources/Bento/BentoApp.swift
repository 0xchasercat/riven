import AppKit
import BentoCore
import SwiftUI

@main
@MainActor
final class BentoApplication: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var rootController: BentoRootController?
    private var agentLauncher: AgentLauncher?

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
        window.title = "Bento"
        window.setContentSize(NSSize(width: 1600, height: 1000))
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
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

        // File → New Tab / New Workspace. We use Cmd+T and Cmd+N (instead
        // of Ctrl-prefixed) because Cmd is the macOS standard. Both fire
        // the same action: append a fresh workspace tab to the strip.
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(title: "New Tab", action: #selector(newTab), keyEquivalent: "t"))
        fileMenu.addItem(NSMenuItem(title: "New Workspace", action: #selector(newTab), keyEquivalent: "n"))
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

    @objc private func closeTab() {
        NotificationCenter.default.post(name: .bentoCloseTab, object: nil)
    }
}

extension Notification.Name {
    static let bentoShowCommandPalette = Notification.Name("BentoShowCommandPalette")
    static let bentoShowSearch = Notification.Name("BentoShowSearch")
    static let bentoNewTab = Notification.Name("BentoNewTab")
    static let bentoCloseTab = Notification.Name("BentoCloseTab")
    static let bentoCloseEditor = Notification.Name("BentoCloseEditor")
}

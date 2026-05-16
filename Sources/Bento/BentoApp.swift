import AppKit
import BentoCore
import SwiftUI

@main
final class BentoApplication: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var rootController: BentoRootController?

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
        let hosting = NSHostingController(rootView: BentoRootView().environmentObject(controller))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Bento"
        window.setContentSize(NSSize(width: 1200, height: 760))
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let controller = rootController else { return }
        let workspace = controller.workspace
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            try? await workspace.persistSnapshot()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + .seconds(2))
    }

    @MainActor private func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Bento", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

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
}

extension Notification.Name {
    static let bentoShowCommandPalette = Notification.Name("BentoShowCommandPalette")
    static let bentoShowSearch = Notification.Name("BentoShowSearch")
}

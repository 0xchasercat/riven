import AppKit
import GhosttyKit

// Phase-0 spike app: a single window hosting one libghostty surface
// running a shell. Proves the full embedding end-to-end — Metal
// render into our NSView, PTY spawn, keyboard/mouse IO — before
// integrating into Riven's pane system.

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var paneView: SurfacePaneView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Force the app to initialize before building any surface.
        _ = GhosttyApp.shared

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "GhosttySpike — libghostty surface"
        window.center()

        paneView = SurfacePaneView(frame: window.contentLayoutRect)
        paneView.autoresizingMask = [.width, .height]
        window.contentView = paneView

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(paneView)
        NSApp.activate(ignoringOtherApps: true)

        // Inject a command after a beat to prove the command-bar path
        // (ghostty_surface_text → PTY) works.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.paneView.injectText("echo hello from ghostty_surface_text\n")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

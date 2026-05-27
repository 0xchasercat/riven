import AppKit
import RivenCore
import SwiftUI

/// SwiftUI wrapper around `SurfacePaneView` — one in-process libghostty
/// terminal surface (PTY + Metal renderer owned by ghostty). The PTY
/// lives inside this process now, so it dies with the UI; session
/// *restore* is handled separately by workspace snapshots.
///
/// The `paneID` keys the surface in `GhosttyApp`'s registry so the
/// command bar can inject into it and search can pull its scrollback.
struct TerminalPaneView: NSViewRepresentable {
    let theme: ThemeSpec
    let paneID: PaneID
    let cwd: String
    let command: String?
    /// Forwarded to `SurfacePaneView.onCwdChanged`. SwiftUI rebuilds this
    /// struct on every parent update, so we re-bind the latest closure
    /// into the cached NSView inside `updateNSView`.
    let onCwdChanged: (String) -> Void

    init(
        theme: ThemeSpec,
        paneID: PaneID = PaneID(),
        cwd: String = NSHomeDirectory(),
        command: String? = nil,
        onCwdChanged: @escaping (String) -> Void = { _ in }
    ) {
        self.theme = theme
        self.paneID = paneID
        self.cwd = cwd
        self.command = command
        self.onCwdChanged = onCwdChanged
    }

    func makeNSView(context: Context) -> SurfacePaneView {
        // Apply the active theme to the ghostty config before the surface
        // spawns so it renders correct colors from the first frame.
        GhosttyApp.shared.applyTheme(theme)

        // Minimal spawn env. ghostty owns TERM / COLORTERM / TERM_PROGRAM
        // and injects its own shell integration (which is what emits the
        // OSC 7 / OSC 133 sequences we consume via action callbacks), so
        // we must NOT override those — doing so would downgrade the
        // terminal and suppress ghostty's integration. We only backfill
        // LANG when the launch environment (Finder / LaunchServices) has
        // none, so the shell gets a sane UTF-8 locale.
        var env: [String: String] = [:]
        if ProcessInfo.processInfo.environment["LANG"] == nil {
            env["LANG"] = "en_US.UTF-8"
        }

        // Reuse the cached surface view for this pane if one exists, so
        // the surface (and its in-process shell) survives SwiftUI
        // rebuilds — e.g. splitting the tab restructures the view tree.
        // Only a brand-new pane spawns a fresh surface.
        let view = GhosttyApp.shared.surfaceView(for: paneID, cwd: cwd, command: command, env: env)
        view.onCwdChanged = onCwdChanged
        return view
    }

    func updateNSView(_ nsView: SurfacePaneView, context: Context) {
        // Theme switches rebuild the ghostty config + re-apply to every
        // live surface; applyTheme is a no-op when the theme is unchanged.
        GhosttyApp.shared.applyTheme(theme)
        // Re-bind the cwd callback so the closure always reflects the
        // latest SwiftUI environment.
        nsView.onCwdChanged = onCwdChanged
    }
}

import AppKit
import RivenCore
import SwiftUI

/// SwiftUI wrapper around `BrokeredTerminalView`.
///
/// Each instance represents one PTY-backed shell that lives inside the
/// out-of-process `RivenAgent` broker. The view itself is just a thin
/// surface that renders the broker's pane and forwards input back.
/// Because the PTY lives in the broker, UI crashes and relaunches do
/// not kill the shell — a fresh `TerminalPaneView` constructed with the
/// same `paneID` will reattach and replay the broker's ring buffer.
///
/// The `agentClient` parameter is the connection to the broker; the
/// orchestrator is expected to obtain it from `AgentLauncher` once at
/// startup and pass it down through the pane tree.
struct TerminalPaneView: NSViewRepresentable {
    let theme: ThemeSpec
    let paneID: PaneID
    let cwd: String
    let command: String?
    let agentClient: AgentClient
    /// Forwarded to `BrokeredTerminalView.onCwdChanged` on each render.
    /// SwiftUI rebuilds this struct on every parent update, so we
    /// re-bind the latest closure into the cached `NSView` inside
    /// `updateNSView` rather than only at `makeNSView` time.
    let onCwdChanged: (String) -> Void

    init(
        theme: ThemeSpec,
        paneID: PaneID = PaneID(),
        cwd: String = NSHomeDirectory(),
        command: String? = nil,
        agentClient: AgentClient,
        onCwdChanged: @escaping (String) -> Void = { _ in }
    ) {
        self.theme = theme
        self.paneID = paneID
        self.cwd = cwd
        self.command = command
        self.agentClient = agentClient
        self.onCwdChanged = onCwdChanged
    }

    func makeNSView(context: Context) -> BrokeredTerminalView {
        // Spawn-time env. When Riven.app is launched from Finder /
        // LaunchServices, the inherited process environment has no
        // TERM, no COLORTARM, no TERM_PROGRAM — so the spawned shell
        // negotiates down to `dumb` (no colors, no cursor positioning,
        // breaks every modern prompt + vim + less + git). These four
        // overrides bring it back up to what every other GUI
        // terminal advertises:
        //   * TERM = xterm-256color — the most-supported terminfo
        //     advertising 256-color + every standard CSI/SGR we care
        //     about. (Ghostty ships its own `xterm-ghostty` terminfo
        //     with extra extensions but that's not installed by
        //     default on a stock macOS, so picking the universally-
        //     present xterm-256color is the safe call. Users who've
        //     installed xterm-ghostty's terminfo via `tic` can
        //     override via .zshrc.)
        //   * COLORTERM = truecolor — lets bat/eza/delta/etc. emit
        //     24-bit ANSI without a probing handshake.
        //   * TERM_PROGRAM / TERM_PROGRAM_VERSION = Riven — lets
        //     shells / scripts detect us specifically (Starship +
        //     Powerlevel10k both branch on this).
        //   * LANG = en_US.UTF-8 — only set when the inherited env
        //     doesn't already carry one, so user-chosen locales still
        //     win.
        var env: [String: String] = [
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "TERM_PROGRAM": "Riven",
            "TERM_PROGRAM_VERSION": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        ]
        if ProcessInfo.processInfo.environment["LANG"] == nil {
            env["LANG"] = "en_US.UTF-8"
        }

        let shell: BrokeredTerminalView.ShellSpec
        if let command {
            shell = BrokeredTerminalView.ShellSpec(
                executable: "/bin/zsh",
                arguments: ["-l", "-c", command],
                cwd: cwd,
                environment: env
            )
        } else {
            shell = BrokeredTerminalView.ShellSpec(
                executable: "/bin/zsh",
                arguments: ["-il"],
                cwd: cwd,
                environment: env
            )
        }
        let view = BrokeredTerminalView(
            paneID: paneID,
            shell: shell,
            configuration: configuration(for: theme),
            agentClient: agentClient,
            onCwdChanged: onCwdChanged
        )
        // We deliberately do NOT auto-grab first-responder here anymore.
        // The Riven model is: the command bar is the default writing
        // surface, and clicks anywhere on the terminal pane bounce focus
        // back to it. See BrokeredTerminalView.mouseDown for the bounce,
        // and CommandBarView's `rivenFocusCommandBar` listener for the
        // landing.
        return view
    }

    func updateNSView(_ nsView: BrokeredTerminalView, context: Context) {
        nsView.configure(configuration(for: theme))
        // Re-bind the cwd callback so the closure captured here always
        // reflects the latest SwiftUI environment. Without this, a stale
        // closure from `makeNSView` would persist across orchestrator
        // updates.
        nsView.onCwdChanged = onCwdChanged
    }

    private func configuration(for theme: ThemeSpec) -> BrokeredTerminalView.Configuration {
        BrokeredTerminalView.Configuration(
            foreground: NSColor(hex: theme.terminal.foreground.hex),
            background: NSColor(hex: theme.terminal.background.hex),
            cursor: NSColor(hex: theme.terminal.cursor.hex),
            fontSize: 13,
            fontName: nil,
            // Drag-to-select highlight color. `chrome.selectionBg` is
            // the 8-digit alpha-bearing hex token added in T-1 — it
            // automatically follows the active theme so Amber gets
            // amber-22%, Tokyo gets violet-15%, Paper gets ink-10%
            // on cream, etc.
            selectionBackground: NSColor(hex: theme.chrome.selectionBg.hex)
        )
    }
}

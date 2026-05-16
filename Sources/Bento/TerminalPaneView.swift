import AppKit
import BentoCore
import SwiftUI

/// SwiftUI wrapper around `BrokeredTerminalView`.
///
/// Each instance represents one PTY-backed shell that lives inside the
/// out-of-process `BentoAgent` broker. The view itself is just a thin
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
        let shell: BrokeredTerminalView.ShellSpec
        if let command {
            shell = BrokeredTerminalView.ShellSpec(
                executable: "/bin/zsh",
                arguments: ["-l", "-c", command],
                cwd: cwd
            )
        } else {
            shell = BrokeredTerminalView.ShellSpec(
                executable: "/bin/zsh",
                arguments: ["-il"],
                cwd: cwd
            )
        }
        let view = BrokeredTerminalView(
            paneID: paneID,
            shell: shell,
            configuration: configuration(for: theme),
            agentClient: agentClient,
            onCwdChanged: onCwdChanged
        )
        // Make the terminal first-responder once it actually has a window.
        DispatchQueue.main.async { [weak view] in
            view?.window?.makeFirstResponder(view)
        }
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
            fontName: nil
        )
    }
}

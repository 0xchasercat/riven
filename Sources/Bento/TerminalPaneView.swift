import AppKit
import BentoCore
import SwiftUI

/// SwiftUI wrapper around `GhosttyTerminalView`. Each instance owns one live
/// PTY-backed shell rendered through `libghostty-vt`.
struct TerminalPaneView: NSViewRepresentable {
    let theme: ThemeSpec
    let paneID: PaneID
    let cwd: String
    let command: String?

    init(
        theme: ThemeSpec,
        paneID: PaneID = PaneID(),
        cwd: String = NSHomeDirectory(),
        command: String? = nil
    ) {
        self.theme = theme
        self.paneID = paneID
        self.cwd = cwd
        self.command = command
    }

    func makeNSView(context: Context) -> GhosttyTerminalView {
        let shell: GhosttyTerminalView.ShellSpec
        if let command {
            shell = GhosttyTerminalView.ShellSpec(
                executable: "/bin/zsh",
                arguments: ["-l", "-c", command],
                cwd: cwd
            )
        } else {
            shell = GhosttyTerminalView.ShellSpec(
                executable: "/bin/zsh",
                arguments: ["-il"],
                cwd: cwd
            )
        }
        let view = GhosttyTerminalView(
            paneID: paneID,
            shell: shell,
            configuration: configuration(for: theme)
        )
        // Make the terminal first-responder once it actually has a window.
        DispatchQueue.main.async { [weak view] in
            view?.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: GhosttyTerminalView, context: Context) {
        nsView.configure(configuration(for: theme))
    }

    private func configuration(for theme: ThemeSpec) -> GhosttyTerminalView.Configuration {
        GhosttyTerminalView.Configuration(
            foreground: NSColor(hex: theme.terminal.foreground.hex),
            background: NSColor(hex: theme.terminal.background.hex),
            cursor: NSColor(hex: theme.terminal.cursor.hex),
            fontSize: 13,
            fontName: nil
        )
    }
}

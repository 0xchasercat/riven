import BentoCore
import SwiftUI

/// Scaffold pane grid. Renders a fixed 2x2 layout: live Ghostty terminals on
/// the right column, editors on the left. A follow-up slice will replace
/// this with a real `NSSplitView`-backed grid driven by `PaneGraph`.
struct PaneGridView: View {
    let theme: ThemeSpec
    let paneGraph: PaneGraph
    @Binding var openFile: URL?
    let projectRoot: String

    var body: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                PaneShell(title: openFile?.lastPathComponent ?? "scratch.swift", badge: "STTextView", theme: theme, active: true) {
                    EditorPaneView(theme: theme, openFile: $openFile)
                }
                PaneShell(title: "zsh", badge: "libghostty", theme: theme, active: false) {
                    TerminalPaneView(
                        theme: theme,
                        paneID: PaneID("grid-tl-terminal"),
                        cwd: projectRoot
                    )
                }
            }
            GridRow {
                PaneShell(title: "scratch.rs", badge: "STTextView", theme: theme, active: false) {
                    EditorPaneView(theme: theme, openFile: .constant(nil))
                }
                PaneShell(title: "zsh - swift test", badge: "libghostty", theme: theme, active: false) {
                    TerminalPaneView(
                        theme: theme,
                        paneID: PaneID("grid-br-terminal"),
                        cwd: projectRoot,
                        command: "swift test"
                    )
                }
            }
        }
        .padding(6)
        .background(Color(hex: theme.chrome.border.hex))
    }
}

struct PaneShell<Content: View>: View {
    let title: String
    let badge: String
    let theme: ThemeSpec
    let active: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                Spacer()
                Text(badge)
                    .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
            }
            .font(.system(size: 11, weight: active ? .semibold : .regular, design: .monospaced))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Color(hex: theme.chrome.background.hex))
            content
        }
        .background(Color(hex: theme.chrome.panel.hex))
        .overlay(Rectangle().stroke(Color(hex: active ? theme.chrome.activeBorder.hex : theme.chrome.border.hex), lineWidth: active ? 1 : 0))
    }
}

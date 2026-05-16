import AppKit
import BentoCore
import SwiftUI

struct BentoRootView: View {
    @EnvironmentObject private var controller: BentoRootController
    @State private var selectedThemeID: String?
    @State private var activeOverlay: Overlay?
    @State private var paletteQuery = ""
    @State private var searchQuery = ""

    private var theme: ThemeSpec {
        let id = selectedThemeID ?? controller.state.selectedThemeID
        return ThemeSpec.theme(id: id) ?? ThemeSpec.builtIns[0]
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                SidebarView(
                    theme: theme,
                    fileTree: controller.state.fileTree,
                    onOpenFile: { controller.openFile($0) }
                )
                Divider().background(Color(hex: theme.chrome.border.hex))
                VStack(spacing: 0) {
                    toolbar
                    PaneGridView(
                        theme: theme,
                        paneGraph: controller.state.paneGraph,
                        projectRoot: controller.state.projectRoot,
                        fileMap: controller.fileMap,
                        agentClient: controller.agentClient,
                        onGraphChange: { controller.recordPaneGraph($0) },
                        onOpenFile: { controller.openFile($0) },
                        onCwdChanged: { paneID, cwd in
                            controller.updateWorkspaceCwd(paneID: paneID, cwd: cwd)
                        }
                    )
                    statusBar
                }
            }
            if !controller.preference.hasExplicitSelection {
                ThemePicker(theme: theme, onSelect: { id in
                    try? controller.preference.selectTheme(id: id)
                    selectedThemeID = id
                })
            }
            if let activeOverlay {
                overlay(activeOverlay)
            }
        }
        .background(Color(hex: theme.chrome.background.hex))
        .foregroundStyle(Color(hex: theme.chrome.text.hex))
        .onReceive(NotificationCenter.default.publisher(for: .bentoShowCommandPalette)) { _ in
            activeOverlay = .palette
            paletteQuery = ""
        }
        .onReceive(NotificationCenter.default.publisher(for: .bentoShowSearch)) { _ in
            activeOverlay = .search
            searchQuery = ""
        }
    }

    private var toolbar: some View {
        HStack {
            Text(controller.state.projectRoot)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if controller.agentClient == nil {
                Text("connecting to broker…")
                    .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
            }
            if controller.state.restoredFromSnapshot {
                Text("session restored")
                    .foregroundStyle(Color(hex: theme.chrome.activeBorder.hex))
            }
            if controller.state.requiresTaskTrust {
                Button {
                    activeOverlay = .trust
                } label: {
                    Text("\(controller.state.pendingTaskCommands.count) task panes pending trust")
                        .foregroundStyle(Color(hex: theme.chrome.activeBorder.hex))
                        .underline()
                }
                .buttonStyle(.plain)
            }
            Text("cmd+k")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
        .background(Color(hex: theme.chrome.background.hex))
    }

    @ViewBuilder
    private func overlay(_ overlay: Overlay) -> some View {
        switch overlay {
        case .palette:
            CommandPaletteOverlay(
                theme: theme,
                query: $paletteQuery,
                commands: CommandPalette(commands: Command.bentoBuiltIns).search(paletteQuery),
                onSelect: { dispatch($0) },
                onClose: { activeOverlay = nil }
            )
        case .search:
            SearchOverlay(
                theme: theme,
                query: $searchQuery,
                search: { try await controller.search($0) },
                onOpenFile: { url in
                    activeOverlay = nil
                    controller.openFile(url)
                },
                onClose: { activeOverlay = nil }
            )
        case .trust:
            TrustPromptOverlay(
                theme: theme,
                projectRoot: controller.state.projectRoot,
                pendingCommands: controller.state.pendingTaskCommands,
                onTrust: {
                    controller.trustCurrentProject()
                    activeOverlay = nil
                },
                onDismiss: { activeOverlay = nil }
            )
        }
    }

    private func dispatch(_ action: CommandAction) {
        switch action {
        case .splitRight:
            let next = controller.state.paneGraph.splittingInheriting(controller.state.paneGraph.focusedPaneID, direction: .right)
            controller.recordPaneGraph(next)
        case .splitDown:
            let next = controller.state.paneGraph.splittingInheriting(controller.state.paneGraph.focusedPaneID, direction: .down)
            controller.recordPaneGraph(next)
        case .closePane:
            if let next = controller.state.paneGraph.close(controller.state.paneGraph.focusedPaneID) {
                controller.recordPaneGraph(next)
            }
        case .cycleFocus:
            controller.recordPaneGraph(controller.state.paneGraph.nextFocus())
        case .cycleTheme:
            controller.cycleTheme()
            selectedThemeID = controller.state.selectedThemeID
        case .showSearch:
            activeOverlay = .search
            searchQuery = ""
        case .openFile(let url):
            controller.openFile(url)
        case .openFilePicker:
            presentOpenFilePicker()
        case .showTrustPrompt:
            activeOverlay = .trust
        }
    }

    /// Run an `NSOpenPanel` and forward the chosen URL to the controller.
    /// Used by the palette's "Open file…" command.
    private func presentOpenFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: controller.state.projectRoot)
        if panel.runModal() == .OK, let url = panel.url {
            controller.openFile(url)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            Text(URL(fileURLWithPath: controller.state.projectRoot).lastPathComponent)
            Text("\(controller.openFilePaths.count) open")
            Text("theme: \(theme.name)")
            Spacer()
            Text("0 telemetry")
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(Color(hex: theme.chrome.background.hex))
    }
}

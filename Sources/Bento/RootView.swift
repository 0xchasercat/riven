import BentoCore
import SwiftUI

struct BentoRootView: View {
    @EnvironmentObject private var controller: BentoRootController
    @State private var selectedThemeID: String?
    @State private var activeOverlay: Overlay?
    @State private var paletteQuery = ""
    @State private var searchQuery = ""
    @State private var openFile: URL?

    private var theme: ThemeSpec {
        let id = selectedThemeID ?? controller.preference.selectedTheme.id
        return ThemeSpec.theme(id: id) ?? ThemeSpec.builtIns[0]
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                SidebarView(
                    theme: theme,
                    fileTree: controller.state.fileTree,
                    onOpenFile: { url in
                        openFile = url
                        var paths = controller.openFilePaths
                        if !paths.contains(url.path) {
                            paths.insert(url.path, at: 0)
                            controller.recordOpenFiles(paths)
                        }
                    }
                )
                Divider().background(Color(hex: theme.chrome.border.hex))
                VStack(spacing: 0) {
                    toolbar
                    PaneGridView(
                        theme: theme,
                        paneGraph: controller.state.paneGraph,
                        openFile: $openFile,
                        projectRoot: controller.state.projectRoot
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
            if controller.state.restoredFromSnapshot {
                Text("session restored")
                    .foregroundStyle(Color(hex: theme.chrome.activeBorder.hex))
            }
            if controller.state.requiresTaskTrust {
                Text("\(controller.state.pendingTaskCommands.count) task panes pending trust")
                    .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
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
                onClose: { activeOverlay = nil }
            )
        case .search:
            SearchOverlay(
                theme: theme,
                query: $searchQuery,
                onClose: { activeOverlay = nil }
            )
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

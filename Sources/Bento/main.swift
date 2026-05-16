import AppKit
import BentoCore
import STTextView
import SwiftUI

@main
final class BentoApplication: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    static func main() {
        let app = NSApplication.shared
        let delegate = BentoApplication()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        let preference = ThemePreferenceStore()
        let content = BentoRootView(preference: preference)
        let hosting = NSHostingController(rootView: content)
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

private extension Notification.Name {
    static let bentoShowCommandPalette = Notification.Name("BentoShowCommandPalette")
    static let bentoShowSearch = Notification.Name("BentoShowSearch")
}

private struct BentoRootView: View {
    let preference: ThemePreferenceStore
    @State private var selectedThemeID: String
    @State private var activeOverlay: Overlay?
    @State private var paletteQuery = ""
    @State private var searchQuery = ""
    @State private var fileTree: ProjectFileTree

    init(preference: ThemePreferenceStore) {
        self.preference = preference
        self._selectedThemeID = State(initialValue: preference.selectedTheme.id)
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let tree = (try? ProjectFileTree.scan(root: cwd, maxDepth: 3)) ?? ProjectFileTree(name: "Bento", path: cwd.path, kind: .directory)
        self._fileTree = State(initialValue: tree)
    }

    private var theme: ThemeSpec {
        ThemeSpec.theme(id: selectedThemeID) ?? ThemeSpec.builtIns[0]
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                sidebar
                Divider().background(Color(hex: theme.chrome.border.hex))
                VStack(spacing: 0) {
                    toolbar
                    paneGrid
                    statusBar
                }
            }
            if !preference.hasExplicitSelection {
                ThemePicker(theme: theme, onSelect: { id in
                    try? preference.selectTheme(id: id)
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

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(fileTree.name.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
                .padding(.top, 18)
            ForEach(fileTree.children) { node in
                FileTreeRow(node: node, theme: theme)
            }
        }
        .padding(.horizontal, 14)
        .frame(minWidth: 220, idealWidth: 220, maxWidth: 220, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(hex: theme.chrome.background.hex))
    }

    private var toolbar: some View {
        HStack {
            Text("bento - ~/code/bento - main")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
            Spacer()
            Text("Ghostty required")
                .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
            Text("STTextView native")
                .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
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

    private var paneGrid: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                PaneShell(title: "PaneView.swift", badge: "STTextView", theme: theme, active: true) {
                    STTextEditorPane(theme: theme, text: CodePreview.sample)
                }
                PaneShell(title: "zsh - cargo run", badge: "libghostty", theme: theme, active: false) {
                    TerminalPreview(theme: theme, command: "cargo run --release")
                }
            }
            GridRow {
                PaneShell(title: "registry.rs", badge: "STTextView", theme: theme, active: false) {
                    STTextEditorPane(theme: theme, text: "pub struct PaneRegistry {\\n    panes: HashMap<PaneId, Pane>\\n}")
                }
                PaneShell(title: "zsh - cargo test", badge: "libghostty", theme: theme, active: false) {
                    TerminalPreview(theme: theme, command: "swift test")
                }
            }
        }
        .padding(6)
        .background(Color(hex: theme.chrome.border.hex))
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            Text("main")
            Text("4 panes")
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

private struct FileTreeRow: View {
    let node: ProjectFileTree
    let theme: ThemeSpec
    var depth: Int = 0
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(node.kind == .directory ? (isExpanded ? "v" : ">") : " ")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
                    .frame(width: 10)
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(Color(hex: node.kind == .directory ? theme.chrome.text.hex : theme.chrome.dimText.hex))
            }
            .font(.system(size: 12, weight: node.kind == .directory ? .medium : .regular, design: .monospaced))
            .padding(.leading, CGFloat(depth * 12))
            .contentShape(Rectangle())
            .onTapGesture {
                if node.kind == .directory {
                    isExpanded.toggle()
                }
            }

            if isExpanded {
                ForEach(node.children) { child in
                    FileTreeRow(node: child, theme: theme, depth: depth + 1)
                }
            }
        }
    }
}

private enum Overlay {
    case palette
    case search
}

private struct CommandPaletteOverlay: View {
    let theme: ThemeSpec
    @Binding var query: String
    let commands: [Command]
    let onClose: () -> Void

    var body: some View {
        OverlayBackdrop(theme: theme, onClose: onClose) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text(">")
                        .foregroundStyle(Color(hex: theme.chrome.activeBorder.hex))
                    TextField("command", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, design: .monospaced))
                    Text("\(commands.count)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
                }
                .padding(.horizontal, 16)
                .frame(height: 54)
                .background(Color(hex: theme.chrome.background.hex))

                VStack(spacing: 0) {
                    ForEach(commands) { command in
                        HStack(spacing: 12) {
                            Text(command.group.uppercased())
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
                                .frame(width: 72, alignment: .leading)
                            Text(command.title)
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            if let shortcut = command.shortcut {
                                Text(shortcut)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
                            }
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                        .background(command.id == commands.first?.id ? Color(hex: theme.chrome.activeBorder.hex).opacity(0.12) : .clear)
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(width: 620)
        }
    }
}

private struct SearchOverlay: View {
    let theme: ThemeSpec
    @Binding var query: String
    let onClose: () -> Void

    var body: some View {
        OverlayBackdrop(theme: theme, onClose: onClose) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("RG")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(hex: theme.chrome.activeBorder.hex))
                    TextField("search files and scrollback", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, design: .monospaced))
                    Text("files + scrollback")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
                }
                .padding(.horizontal, 16)
                .frame(height: 54)
                .background(Color(hex: theme.chrome.background.hex))

                VStack(alignment: .leading, spacing: 10) {
                    SearchResultRow(theme: theme, source: "Sources/BentoCore", title: "WorkspaceController.swift", detail: "open project, trust task panes, search")
                    SearchResultRow(theme: theme, source: "scrollback: api", title: "cargo run", detail: "terminal history will appear here after agent integration")
                    SearchResultRow(theme: theme, source: ".bento/session.yml", title: "task panes", detail: "trusted commands start through BentoAgent")
                }
                .padding(16)
            }
            .frame(width: 780)
        }
    }
}

private struct SearchResultRow: View {
    let theme: ThemeSpec
    let source: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(source)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
                .frame(width: 170, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
            }
            Spacer()
        }
    }
}

private struct OverlayBackdrop<Content: View>: View {
    let theme: ThemeSpec
    let onClose: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
            content
                .background(Color(hex: theme.chrome.panel.hex))
                .overlay(Rectangle().stroke(Color(hex: theme.chrome.border.hex), lineWidth: 1))
                .shadow(color: .black.opacity(0.42), radius: 38, y: 24)
                .padding(.top, 76)
        }
    }
}

private struct ThemePicker: View {
    let theme: ThemeSpec
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Choose Bento's finish")
                .font(.system(size: 22, weight: .bold))
            Text("This controls app chrome, terminal colors, editor syntax, cursor, and selection styling.")
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
            HStack(spacing: 10) {
                ForEach(ThemeSpec.builtIns) { option in
                    Button {
                        onSelect(option.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(hex: option.chrome.panel.hex))
                                .frame(height: 64)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3)
                                        .stroke(Color(hex: option.chrome.activeBorder.hex), lineWidth: 1)
                                )
                            Text(option.name)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            Text(option.terminal.prompt.hex)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Color(hex: option.chrome.dimText.hex))
                        }
                        .padding(10)
                        .frame(width: 132, alignment: .leading)
                        .background(Color(hex: option.chrome.background.hex))
                        .overlay(Rectangle().stroke(Color(hex: option.chrome.border.hex), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(24)
        .background(Color(hex: theme.chrome.panel.hex))
        .overlay(Rectangle().stroke(Color(hex: theme.chrome.activeBorder.hex), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 30, y: 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.45))
    }
}

private struct PaneShell<Content: View>: View {
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

private struct STTextEditorPane: NSViewRepresentable {
    let theme: ThemeSpec
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(hex: theme.chrome.panel.hex)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true

        let textView = STTextView()
        textView.text = text
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = NSColor(hex: theme.chrome.text.hex)
        textView.insertionPointColor = NSColor(hex: theme.chrome.activeBorder.hex)
        textView.backgroundColor = NSColor(hex: theme.chrome.panel.hex)
        textView.isEditable = true
        textView.isSelectable = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        scrollView.backgroundColor = NSColor(hex: theme.chrome.panel.hex)
        guard let textView = scrollView.documentView as? STTextView else { return }
        if textView.text != text {
            textView.text = text
        }
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = NSColor(hex: theme.chrome.text.hex)
        textView.insertionPointColor = NSColor(hex: theme.chrome.activeBorder.hex)
        textView.backgroundColor = NSColor(hex: theme.chrome.panel.hex)
    }
}

private enum CodePreview {
    static let sample = """
    import SwiftUI
    import STTextView
    import GhosttyVt

    struct PaneView: View {
        var body: some View {
            Text("native panes only")
        }
    }
    """
}

private struct TerminalPreview: View {
    let theme: ThemeSpec
    let command: String

    var body: some View {
        Text("""
        ~/bento $ \(command)
           libghostty bridge: required
           BentoAgent: ready
           STTextView: ready
        """)
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(Color(hex: theme.terminal.foreground.hex))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
    }
}

private extension Color {
    init(hex: String) {
        let scanner = Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")))
        var value: UInt64 = 0
        scanner.scanHexInt64(&value)
        let red = Double((value >> 16) & 0xff) / 255
        let green = Double((value >> 8) & 0xff) / 255
        let blue = Double(value & 0xff) / 255
        self.init(red: red, green: green, blue: blue)
    }
}

private extension NSColor {
    convenience init(hex: String) {
        let scanner = Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")))
        var value: UInt64 = 0
        scanner.scanHexInt64(&value)
        self.init(
            calibratedRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }
}

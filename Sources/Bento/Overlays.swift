import AppKit
import BentoCore
import SwiftUI

enum Overlay {
    case palette
    case search
}

// MARK: - Command palette

struct CommandPaletteOverlay: View {
    let theme: ThemeSpec
    @Binding var query: String
    let commands: [Command]
    let onSelect: (CommandAction) -> Void
    let onClose: () -> Void

    @State private var highlightedIndex: Int = 0

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

                if commands.isEmpty {
                    Text("no matches")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
                        .padding(.vertical, 16)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                                    CommandPaletteRow(
                                        theme: theme,
                                        command: command,
                                        isHighlighted: index == highlightedIndex
                                    )
                                    .id(command.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        highlightedIndex = index
                                        dispatchHighlighted()
                                    }
                                    .onHover { hovering in
                                        if hovering { highlightedIndex = index }
                                    }
                                }
                            }
                            .padding(.vertical, 8)
                        }
                        .frame(maxHeight: 360)
                        .onChange(of: highlightedIndex) { _, newValue in
                            guard commands.indices.contains(newValue) else { return }
                            withAnimation(.easeInOut(duration: 0.08)) {
                                proxy.scrollTo(commands[newValue].id, anchor: .center)
                            }
                        }
                    }
                }
            }
            .frame(width: 620)
        }
        .background(KeyEventHandling(handler: handleKey))
        .onChange(of: query) { _, _ in
            highlightedIndex = 0
        }
        .onChange(of: commands.map(\.id)) { _, _ in
            highlightedIndex = min(highlightedIndex, max(commands.count - 1, 0))
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        switch event.keyCode {
        case 53: // escape
            onClose()
            return nil
        case 36, 76: // return / numpad enter
            dispatchHighlighted()
            return nil
        case 125: // down arrow
            guard !commands.isEmpty else { return nil }
            highlightedIndex = (highlightedIndex + 1) % commands.count
            return nil
        case 126: // up arrow
            guard !commands.isEmpty else { return nil }
            highlightedIndex = (highlightedIndex - 1 + commands.count) % commands.count
            return nil
        default:
            return event
        }
    }

    private func dispatchHighlighted() {
        guard commands.indices.contains(highlightedIndex) else { return }
        let command = commands[highlightedIndex]
        guard let action = CommandAction.from(command) else {
            // No-op: the orchestrator hasn't wired this command yet.
            // Closing the overlay would be confusing, so we just print and stay open.
            print("[CommandPalette] no action mapped for command: \(command.id.rawValue)")
            return
        }
        onClose()
        onSelect(action)
    }
}

private struct CommandPaletteRow: View {
    let theme: ThemeSpec
    let command: Command
    let isHighlighted: Bool

    var body: some View {
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
        .background(isHighlighted
            ? Color(hex: theme.chrome.activeBorder.hex).opacity(0.18)
            : .clear)
    }
}

// MARK: - Search overlay

struct SearchOverlay: View {
    let theme: ThemeSpec
    @Binding var query: String
    let search: (String) async throws -> [UnifiedSearchResult]
    let onOpenFile: (URL) -> Void
    let onClose: () -> Void

    @State private var results: [UnifiedSearchResult] = []
    @State private var highlightedIndex: Int = 0
    @State private var debounceTask: Task<Void, Never>?
    @State private var lastError: String?
    @State private var isSearching: Bool = false

    private var fileResults: [(offset: Int, result: UnifiedSearchResult)] {
        results.enumerated().compactMap { index, result in
            if case .file = result { return (index, result) } else { return nil }
        }
    }

    private var scrollbackResults: [(offset: Int, result: UnifiedSearchResult)] {
        results.enumerated().compactMap { index, result in
            if case .scrollback = result { return (index, result) } else { return nil }
        }
    }

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
                    Text(statusText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
                }
                .padding(.horizontal, 16)
                .frame(height: 54)
                .background(Color(hex: theme.chrome.background.hex))

                resultsBody
            }
            .frame(width: 780)
        }
        .background(KeyEventHandling(handler: handleKey))
        .onChange(of: query) { _, newValue in
            scheduleSearch(for: newValue)
        }
        .onAppear {
            // Reset transient state every time the overlay reappears.
            results = []
            highlightedIndex = 0
            lastError = nil
            isSearching = false
            scheduleSearch(for: query)
        }
        .onDisappear {
            debounceTask?.cancel()
            debounceTask = nil
        }
    }

    private var statusText: String {
        if let lastError { return "error: \(lastError)" }
        if isSearching { return "searching..." }
        if query.isEmpty { return "files + scrollback" }
        return "\(results.count) results"
    }

    @ViewBuilder
    private var resultsBody: some View {
        if query.isEmpty {
            VStack(spacing: 6) {
                Text("type to search project files and pane scrollback")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
            }
            .frame(maxWidth: .infinity)
            .padding(24)
        } else if results.isEmpty {
            Text(isSearching ? "searching..." : "no matches")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
                .frame(maxWidth: .infinity)
                .padding(24)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !fileResults.isEmpty {
                            sectionHeader("files (\(fileResults.count))")
                            ForEach(fileResults, id: \.offset) { entry in
                                rowView(for: entry.result, index: entry.offset)
                            }
                        }
                        if !scrollbackResults.isEmpty {
                            sectionHeader("scrollback (\(scrollbackResults.count))")
                            ForEach(scrollbackResults, id: \.offset) { entry in
                                rowView(for: entry.result, index: entry.offset)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 420)
                .onChange(of: highlightedIndex) { _, newValue in
                    guard results.indices.contains(newValue) else { return }
                    withAnimation(.easeInOut(duration: 0.08)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    @ViewBuilder
    private func rowView(for result: UnifiedSearchResult, index: Int) -> some View {
        SearchResultRow(
            theme: theme,
            result: result,
            isHighlighted: index == highlightedIndex
        )
        .id(index)
        .contentShape(Rectangle())
        .onTapGesture {
            highlightedIndex = index
            dispatchHighlighted()
        }
        .onHover { hovering in
            if hovering { highlightedIndex = index }
        }
    }

    private func scheduleSearch(for query: String) {
        debounceTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            highlightedIndex = 0
            lastError = nil
            isSearching = false
            return
        }
        isSearching = true
        let runQuery = trimmed
        debounceTask = Task { @MainActor in
            // Debounce ~100ms so we don't kick off a search per keystroke.
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return
            }
            if Task.isCancelled { return }
            do {
                let next = try await search(runQuery)
                if Task.isCancelled { return }
                results = next
                highlightedIndex = 0
                lastError = nil
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                results = []
                lastError = String(describing: error)
            }
            isSearching = false
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        switch event.keyCode {
        case 53: // escape
            onClose()
            return nil
        case 36, 76: // return / numpad enter
            dispatchHighlighted()
            return nil
        case 125: // down arrow
            guard !results.isEmpty else { return nil }
            highlightedIndex = (highlightedIndex + 1) % results.count
            return nil
        case 126: // up arrow
            guard !results.isEmpty else { return nil }
            highlightedIndex = (highlightedIndex - 1 + results.count) % results.count
            return nil
        default:
            return event
        }
    }

    private func dispatchHighlighted() {
        guard results.indices.contains(highlightedIndex) else { return }
        switch results[highlightedIndex] {
        case .file(let path, _, _):
            let url = URL(fileURLWithPath: path)
            onClose()
            onOpenFile(url)
        case .scrollback:
            // Scrollback navigation is a follow-up; do nothing for now.
            break
        }
    }
}

private struct SearchResultRow: View {
    let theme: ThemeSpec
    let result: UnifiedSearchResult
    let isHighlighted: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(sourceText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
                .frame(width: 220, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
            VStack(alignment: .leading, spacing: 3) {
                Text(titleText)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                Text(detailText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(isHighlighted
            ? Color(hex: theme.chrome.activeBorder.hex).opacity(0.18)
            : .clear)
    }

    private var sourceText: String {
        switch result {
        case .file(let path, _, _):
            return path
        case .scrollback(let match):
            return "scrollback: \(match.paneID.rawValue)"
        }
    }

    private var titleText: String {
        switch result {
        case .file(let path, let lineNumber, _):
            return "\(URL(fileURLWithPath: path).lastPathComponent):\(lineNumber)"
        case .scrollback(let match):
            return "\(match.paneID.rawValue):\(match.lineNumber)"
        }
    }

    private var detailText: String {
        switch result {
        case .file(_, _, let line):
            return line
        case .scrollback(let match):
            return match.line
        }
    }
}

// MARK: - Backdrop

struct OverlayBackdrop<Content: View>: View {
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

// MARK: - Key event bridge

/// Installs a local `NSEvent` monitor so the overlay can intercept arrow keys,
/// return, and escape even while the embedded `TextField` is the first
/// responder. The handler returns `nil` to swallow the event or the event
/// itself to let it propagate (e.g. to keep regular text input working).
private struct KeyEventHandling: NSViewRepresentable {
    let handler: (NSEvent) -> NSEvent?

    func makeNSView(context: Context) -> KeyEventMonitorView {
        KeyEventMonitorView(handler: handler)
    }

    func updateNSView(_ nsView: KeyEventMonitorView, context: Context) {
        nsView.handler = handler
    }

    static func dismantleNSView(_ nsView: KeyEventMonitorView, coordinator: ()) {
        nsView.tearDown()
    }
}

private final class KeyEventMonitorView: NSView {
    var handler: (NSEvent) -> NSEvent?
    nonisolated(unsafe) private var monitor: Any?

    init(handler: @escaping (NSEvent) -> NSEvent?) {
        self.handler = handler
        super.init(frame: .zero)
        self.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handler(event)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func tearDown() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

import AppKit
import BentoCore
import SwiftUI

enum Overlay {
    case palette
    case search
    case trust
}

// MARK: - Shared overlay chrome

/// Width tokens for overlays. The picker is wider because its preview
/// tiles need horizontal room; everything else uses the standard width.
enum OverlayWidth {
    static let standard: CGFloat = 640
    static let picker: CGFloat = 760
}

/// Top margin from the window top. Keeps overlays anchored at a
/// consistent vertical position regardless of content.
enum OverlayLayout {
    static let topMargin: CGFloat = 88
    static let headerHeight: CGFloat = 56
    static let rowHeight: CGFloat = 36
    static let footerHeight: CGFloat = 34
}

/// Header bar used at the top of every overlay (title row with optional
/// trailing hint, separated from the body by a hairline).
struct OverlayHeader<Trailing: View>: View {
    let theme: ThemeSpec
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: BentoSpacing.s) {
                Text(title)
                    .font(BentoType.chrome(15, weight: .semibold))
                    .foregroundStyle(Color(hex: theme.chrome.text.hex))
                    .lineLimit(1)
                Spacer(minLength: BentoSpacing.s)
                trailing
                    .font(BentoType.mono(11))
                    .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
            }
            .padding(.horizontal, BentoSpacing.l)
            .frame(height: OverlayLayout.headerHeight)
            Hairline(theme: theme)
        }
    }
}

extension OverlayHeader where Trailing == EmptyView {
    init(theme: ThemeSpec, title: String) {
        self.init(theme: theme, title: title, trailing: { EmptyView() })
    }
}

/// Header variant that hosts an inline text field (palette, search). The
/// title slot is replaced by the field; the trailing slot carries the
/// hint/count.
struct OverlayInputHeader<Trailing: View>: View {
    let theme: ThemeSpec
    let leading: String
    @Binding var text: String
    let placeholder: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: BentoSpacing.s) {
                Text(leading)
                    .font(BentoType.mono(13, weight: .semibold))
                    .foregroundStyle(Color(hex: theme.chrome.accent.hex))
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(BentoType.mono(15))
                    .foregroundStyle(Color(hex: theme.chrome.text.hex))
                Spacer(minLength: BentoSpacing.s)
                trailing
                    .font(BentoType.mono(11))
                    .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
            }
            .padding(.horizontal, BentoSpacing.l)
            .frame(height: OverlayLayout.headerHeight)
            Hairline(theme: theme)
        }
    }
}

/// Footer hint bar shown at the bottom of every overlay. Free-form text
/// in the monospaced micro size; rendered above a top hairline.
struct OverlayFooter<Content: View>: View {
    let theme: ThemeSpec
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Hairline(theme: theme)
            HStack(spacing: BentoSpacing.s) {
                content
                    .font(BentoType.mono(10))
                    .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, BentoSpacing.l)
            .padding(.vertical, BentoSpacing.s)
            .frame(minHeight: OverlayLayout.footerHeight)
        }
    }
}

/// Selectable list row used by palette + search. Owns the highlight
/// background, hover animation, and horizontal padding so children only
/// supply content.
struct OverlayRow<Content: View>: View {
    let theme: ThemeSpec
    let isHighlighted: Bool
    let height: CGFloat
    @ViewBuilder var content: Content

    init(
        theme: ThemeSpec,
        isHighlighted: Bool,
        height: CGFloat = OverlayLayout.rowHeight,
        @ViewBuilder content: () -> Content
    ) {
        self.theme = theme
        self.isHighlighted = isHighlighted
        self.height = height
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, BentoSpacing.l)
            .frame(minHeight: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(hex: theme.chrome.accentSoft.hex)
                    .opacity(isHighlighted ? 1 : 0)
            )
            .animation(BentoMotion.hover, value: isHighlighted)
            .contentShape(Rectangle())
    }
}

// MARK: - Shared overlay buttons

/// Primary filled button used by overlays (e.g. trust prompt's "Trust").
struct OverlayPrimaryButton: View {
    let theme: ThemeSpec
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(BentoType.chrome(12, weight: .semibold))
                .foregroundStyle(Color(hex: theme.chrome.invertedText.hex))
                .padding(.horizontal, BentoSpacing.m)
                .padding(.vertical, BentoSpacing.s)
                .background(
                    RoundedRectangle(cornerRadius: BentoRadius.small, style: .continuous)
                        .fill(Color(hex: theme.chrome.accent.hex))
                )
        }
        .buttonStyle(.plain)
    }
}

/// Secondary outline button used by overlays (e.g. trust prompt's "Not yet").
struct OverlaySecondaryButton: View {
    let theme: ThemeSpec
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(BentoType.chrome(12, weight: .medium))
                .foregroundStyle(Color(hex: theme.chrome.text.hex))
                .padding(.horizontal, BentoSpacing.m)
                .padding(.vertical, BentoSpacing.s)
                .background(
                    RoundedRectangle(cornerRadius: BentoRadius.small, style: .continuous)
                        .strokeBorder(Color(hex: theme.chrome.border.hex), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Command palette

struct CommandPaletteOverlay: View {
    let theme: ThemeSpec
    @Binding var query: String
    let commands: [Command]
    let onSelect: (CommandAction) -> Void
    let onClose: () -> Void

    /// The keyboard-selected row. Up / down arrow + Enter operate on
    /// this one. Auto-scroll fires when this changes so the
    /// selection stays in view.
    @State private var highlightedIndex: Int = 0
    /// The row the mouse is hovering, separate from the keyboard
    /// selection. Renders the same hover-highlight styling but does
    /// NOT trigger an auto-scroll — previously the hover handler set
    /// highlightedIndex, which caused the scroll-to-center on every
    /// mouse move and fought the user's manual scroll.
    @State private var hoveredIndex: Int? = nil

    /// Flat list of rows we render: section headers + commands. Built from
    /// the input list by collapsing consecutive commands sharing a group.
    private enum PaletteRow {
        case header(String)
        case command(index: Int, command: Command)
    }

    private var rows: [PaletteRow] {
        var out: [PaletteRow] = []
        var lastGroup: String?
        for (index, command) in commands.enumerated() {
            if command.group != lastGroup {
                out.append(.header(command.group))
                lastGroup = command.group
            }
            out.append(.command(index: index, command: command))
        }
        return out
    }

    var body: some View {
        OverlayBackdrop(theme: theme, width: OverlayWidth.standard, onClose: onClose) {
            VStack(spacing: 0) {
                OverlayInputHeader(
                    theme: theme,
                    leading: ">",
                    text: $query,
                    placeholder: "command",
                    trailing: { Text("\(commands.count)") }
                )

                if commands.isEmpty {
                    emptyState
                } else {
                    body(for: rows)
                }

                OverlayFooter(theme: theme) {
                    Text("↑↓ navigate · ⏎ select · esc dismiss · \(commands.count) commands")
                }
            }
        }
        .background(KeyEventHandling(handler: handleKey))
        .onChange(of: query) { _, _ in
            highlightedIndex = 0
        }
        .onChange(of: commands.map(\.id)) { _, _ in
            highlightedIndex = min(highlightedIndex, max(commands.count - 1, 0))
        }
    }

    private var emptyState: some View {
        VStack(spacing: BentoSpacing.xs) {
            Text("No matching commands")
                .font(BentoType.chrome(13, weight: .medium))
                .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
            Text("try a different query")
                .font(BentoType.mono(11))
                .foregroundStyle(Color(hex: theme.chrome.tertiaryText.hex))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, BentoSpacing.xl)
    }

    private func body(for rows: [PaletteRow]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        switch row {
                        case .header(let group):
                            SectionLabel(theme: theme, group)
                                .padding(.horizontal, BentoSpacing.l)
                                .padding(.top, BentoSpacing.m)
                                .padding(.bottom, BentoSpacing.xs)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        case .command(let index, let command):
                            CommandPaletteRow(
                                theme: theme,
                                command: command,
                                isHighlighted: index == highlightedIndex || index == hoveredIndex
                            )
                            .id(command.id)
                            .onTapGesture {
                                highlightedIndex = index
                                dispatchHighlighted()
                            }
                            .onHover { hovering in
                                // Visual hover only — do NOT mutate
                                // highlightedIndex. The auto-scroll
                                // is tied to highlightedIndex; if we
                                // wrote here, hovering rows would
                                // scroll the palette to center on
                                // each row the mouse passed over,
                                // making manual scroll impossible.
                                hoveredIndex = hovering ? index : nil
                            }
                        }
                    }
                }
                .padding(.vertical, BentoSpacing.s)
            }
            .frame(maxHeight: 360)
            .onChange(of: highlightedIndex) { _, newValue in
                guard commands.indices.contains(newValue) else { return }
                withAnimation(BentoMotion.hover) {
                    proxy.scrollTo(commands[newValue].id, anchor: .center)
                }
            }
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
        OverlayRow(theme: theme, isHighlighted: isHighlighted) {
            HStack(spacing: BentoSpacing.m) {
                Text(command.title)
                    .font(BentoType.chrome(13, weight: .medium))
                    .foregroundStyle(Color(hex: theme.chrome.text.hex))
                Spacer(minLength: BentoSpacing.s)
                if let shortcut = command.shortcut {
                    Text(shortcut)
                        .font(BentoType.mono(10))
                        .foregroundStyle(
                            Color(hex: isHighlighted
                                ? theme.chrome.dimText.hex
                                : theme.chrome.tertiaryText.hex)
                        )
                }
            }
        }
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
        OverlayBackdrop(theme: theme, width: OverlayWidth.standard, onClose: onClose) {
            VStack(spacing: 0) {
                OverlayInputHeader(
                    theme: theme,
                    leading: "/",
                    text: $query,
                    placeholder: "search files and scrollback",
                    trailing: { Text(statusText) }
                )

                resultsBody

                OverlayFooter(theme: theme) {
                    Text("↑↓ navigate · ⏎ open · esc dismiss")
                }
            }
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
        if isSearching { return "searching…" }
        if query.isEmpty { return "files + scrollback" }
        return "\(results.count) results"
    }

    @ViewBuilder
    private var resultsBody: some View {
        if query.isEmpty {
            emptyHint("Type to search project files and pane scrollback")
        } else if results.isEmpty {
            emptyHint(isSearching ? "Searching…" : "No matches")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !fileResults.isEmpty {
                            sectionHeader("FILES", count: fileResults.count)
                            ForEach(fileResults, id: \.offset) { entry in
                                rowView(for: entry.result, index: entry.offset)
                            }
                        }
                        if !scrollbackResults.isEmpty {
                            sectionHeader("SCROLLBACK", count: scrollbackResults.count)
                            ForEach(scrollbackResults, id: \.offset) { entry in
                                rowView(for: entry.result, index: entry.offset)
                            }
                        }
                    }
                    .padding(.vertical, BentoSpacing.s)
                }
                .frame(maxHeight: 420)
                .onChange(of: highlightedIndex) { _, newValue in
                    guard results.indices.contains(newValue) else { return }
                    withAnimation(BentoMotion.hover) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(BentoType.chrome(12))
            .foregroundStyle(Color(hex: theme.chrome.tertiaryText.hex))
            .frame(maxWidth: .infinity)
            .padding(.vertical, BentoSpacing.xxl)
    }

    private func sectionHeader(_ text: String, count: Int) -> some View {
        HStack(spacing: BentoSpacing.s) {
            SectionLabel(theme: theme, text)
            Text("\(count)")
                .font(BentoType.mono(10))
                .foregroundStyle(Color(hex: theme.chrome.tertiaryText.hex))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, BentoSpacing.l)
        .padding(.top, BentoSpacing.m)
        .padding(.bottom, BentoSpacing.xs)
    }

    @ViewBuilder
    private func rowView(for result: UnifiedSearchResult, index: Int) -> some View {
        SearchResultRow(
            theme: theme,
            result: result,
            isHighlighted: index == highlightedIndex
        )
        .id(index)
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
        case .file(let hit):
            let url = URL(fileURLWithPath: hit.path)
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
        OverlayRow(theme: theme, isHighlighted: isHighlighted, height: 44) {
            HStack(alignment: .firstTextBaseline, spacing: BentoSpacing.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(titleText)
                        .font(BentoType.mono(12, weight: .semibold))
                        .foregroundStyle(Color(hex: theme.chrome.text.hex))
                        .lineLimit(1)
                    Text(detailText)
                        .font(BentoType.mono(11))
                        .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: BentoSpacing.s)
                Text(sourceText)
                    .font(BentoType.mono(10))
                    .foregroundStyle(Color(hex: theme.chrome.tertiaryText.hex))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220, alignment: .trailing)
            }
            .padding(.vertical, BentoSpacing.xs)
        }
    }

    private var sourceText: String {
        switch result {
        case .file(let hit):
            return hit.path
        case .scrollback(let match, _):
            return "pane \(match.paneID.rawValue)"
        }
    }

    private var titleText: String {
        switch result {
        case .file(let hit):
            return "\(URL(fileURLWithPath: hit.path).lastPathComponent):\(hit.lineNumber)"
        case .scrollback(let match, _):
            return "\(match.paneID.rawValue):\(match.lineNumber)"
        }
    }

    private var detailText: String {
        switch result {
        case .file(let hit):
            return hit.line
        case .scrollback(let match, _):
            return match.line
        }
    }
}

// MARK: - Backdrop

/// Modal-level backdrop + container. Provides the dim scrim, the elevated
/// surface, and consistent placement; the caller fills the inner content
/// with header / body / footer slots.
struct OverlayBackdrop<Content: View>: View {
    let theme: ThemeSpec
    let width: CGFloat
    let onClose: () -> Void
    @ViewBuilder var content: Content

    init(
        theme: ThemeSpec,
        width: CGFloat = OverlayWidth.standard,
        onClose: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.theme = theme
        self.width = width
        self.onClose = onClose
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color(hex: theme.chrome.overlay.hex)
                .opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
            content
                .frame(width: width)
                .background(
                    RoundedRectangle(cornerRadius: BentoRadius.large, style: .continuous)
                        .fill(Color(hex: theme.chrome.elevated.hex))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: BentoRadius.large, style: .continuous)
                        .strokeBorder(Color(hex: theme.chrome.border.hex), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: BentoRadius.large, style: .continuous))
                .shadow(
                    color: BentoElevation.modal.color,
                    radius: BentoElevation.modal.radius,
                    x: BentoElevation.modal.x,
                    y: BentoElevation.modal.y
                )
                .padding(.top, OverlayLayout.topMargin)
        }
    }
}

// MARK: - Key event bridge

/// Installs a local `NSEvent` monitor so the overlay can intercept arrow keys,
/// return, and escape even while the embedded `TextField` is the first
/// responder. The handler returns `nil` to swallow the event or the event
/// itself to let it propagate (e.g. to keep regular text input working).
struct KeyEventHandling: NSViewRepresentable {
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

final class KeyEventMonitorView: NSView {
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

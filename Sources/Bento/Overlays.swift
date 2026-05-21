import AppKit
import BentoCore
import SwiftUI

enum Overlay {
    case palette
    case search
    case trust
    case shortcuts
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
//
// S-5: rebuild to match the ripgrep mockup. The overlay now groups
// file hits by `projectRoot+path` under per-file headers with a 44 pt
// line-number gutter, calls out the matched substring on the
// `activeBorder` background, and renders scrollback hits in a separate
// section with workspace/pane/time provenance. The query box gains a
// "this project / all projects" scope toggle (re-runs the search on
// change), a `hits · files · ms` counter, and a recent-searches panel
// when the query is empty.

/// Search hits flattened to a linear list with stable indices so the
/// keyboard cursor + scroll target can refer to them by index. Headers
/// (file-group titles, section labels) are interspersed with selectable
/// items; the index used for `highlightedIndex` is the offset into
/// `selectableRows`, not the offset into the flat list.
private enum SearchPanelRow {
    case fileGroupHeader(projectRoot: String, path: String, count: Int)
    case fileHit(index: Int, hit: FileSearchHit)
    case scrollbackSectionHeader(count: Int)
    case scrollbackHit(index: Int, match: ScrollbackMatch, context: ScrollbackMatchContext?)
}

struct SearchOverlay: View {
    let theme: ThemeSpec
    @Binding var query: String
    /// Run the unified search. `scope` selects "this project" vs.
    /// "all projects". Returns ripgrep+scrollback hits in document
    /// order (file hits first, then scrollback hits) — the overlay
    /// re-groups them by file for display.
    let search: (String, SearchScope) async throws -> [UnifiedSearchResult]
    /// Open the file hit's path in the editor (the existing flow).
    let onOpenFile: (URL) -> Void
    /// Open an inline peek surface for a scrollback hit. Implemented
    /// by the parent (BentoRootController) which creates a new
    /// `.scrollbackPeek` inner tab. The overlay closes itself before
    /// invoking so focus lands cleanly on the new tab.
    let onPeekScrollback: (ScrollbackMatch, ScrollbackMatchContext?) -> Void
    let onClose: () -> Void

    @State private var results: [UnifiedSearchResult] = []
    /// The current keyboard selection. Indexes into `selectableRows`
    /// (not `results`) — headers occupy slots in the panel layout but
    /// are skipped by the cursor.
    @State private var highlightedIndex: Int = 0
    @State private var debounceTask: Task<Void, Never>?
    @State private var lastError: String?
    @State private var isSearching: Bool = false
    @State private var scope: SearchScope = .thisProject
    /// Elapsed time of the most recent `search` call, in milliseconds.
    /// Shown in the input row's counter.
    @State private var elapsedMs: Int = 0
    /// Snapshot of the recent-searches ring loaded when the overlay
    /// appears. Refreshed whenever a query is recorded so the empty-
    /// state list reflects the latest activity.
    @State private var recent: [String] = []
    /// Row the mouse is hovering. Separate from `highlightedIndex` so
    /// hover doesn't drag the auto-scroll cursor around (same bug we
    /// fixed in the command palette).
    @State private var hoveredIndex: Int? = nil

    /// Shared store for recent queries. Constructed inline (cheap —
    /// it's a thin UserDefaults wrapper) so callers don't have to
    /// thread one through.
    private let recentStore = RecentSearchesStore()

    // MARK: - Derived models

    /// File hits regrouped by their (projectRoot, path) pair while
    /// preserving the original ordering. The first hit's projectRoot
    /// + path wins for the group header label.
    private var fileGroups: [(projectRoot: String, path: String, hits: [FileSearchHit])] {
        var keys: [String] = []
        var groups: [String: (projectRoot: String, path: String, hits: [FileSearchHit])] = [:]
        for result in results {
            if case .file(let hit) = result {
                let key = "\(hit.projectRoot)|\(hit.path)"
                if groups[key] == nil {
                    groups[key] = (hit.projectRoot, hit.path, [])
                    keys.append(key)
                }
                groups[key]?.hits.append(hit)
            }
        }
        return keys.compactMap { groups[$0] }
    }

    private var scrollbackEntries: [(match: ScrollbackMatch, context: ScrollbackMatchContext?)] {
        results.compactMap { result in
            if case .scrollback(let match, let context) = result {
                return (match, context)
            }
            return nil
        }
    }

    private var fileHitCount: Int {
        results.reduce(0) { acc, r in if case .file = r { return acc + 1 } else { return acc } }
    }

    private var uniqueFileCount: Int { fileGroups.count }

    /// Render plan: headers + selectable rows in order. The cursor
    /// only stops on `.fileHit` / `.scrollbackHit` entries.
    private var panelRows: [SearchPanelRow] {
        var rows: [SearchPanelRow] = []
        var index = 0
        for group in fileGroups {
            rows.append(.fileGroupHeader(projectRoot: group.projectRoot, path: group.path, count: group.hits.count))
            for hit in group.hits {
                rows.append(.fileHit(index: index, hit: hit))
                index += 1
            }
        }
        let scrollback = scrollbackEntries
        if !scrollback.isEmpty {
            rows.append(.scrollbackSectionHeader(count: scrollback.count))
            for entry in scrollback {
                rows.append(.scrollbackHit(index: index, match: entry.match, context: entry.context))
                index += 1
            }
        }
        return rows
    }

    /// Flat array of selectable rows in the same order the cursor
    /// traverses them. Indexed by `highlightedIndex`.
    private var selectableRows: [SearchPanelRow] {
        panelRows.filter { row in
            switch row {
            case .fileHit, .scrollbackHit: return true
            default: return false
            }
        }
    }

    // MARK: - Body

    var body: some View {
        OverlayBackdrop(theme: theme, width: OverlayWidth.picker, onClose: onClose) {
            VStack(spacing: 0) {
                OverlayInputHeader(
                    theme: theme,
                    leading: "rg",
                    text: $query,
                    placeholder: "ripgrep files + scrollback",
                    trailing: { counterView }
                )

                scopeBar

                resultsBody

                OverlayFooter(theme: theme) {
                    // TODO: re-add "⌘⏎ open in new pane" once the menu
                    // path for opening a file in a fresh inner tab is
                    // wired through CommandActions.
                    Text("↑↓ navigate · ⏎ open · ⌥⏎ peek · esc dismiss")
                }
            }
        }
        .background(KeyEventHandling(handler: handleKey))
        .onChange(of: query) { _, newValue in
            scheduleSearch(for: newValue)
        }
        .onChange(of: scope) { _, _ in
            scheduleSearch(for: query)
        }
        .onAppear {
            results = []
            highlightedIndex = 0
            lastError = nil
            isSearching = false
            elapsedMs = 0
            recent = recentStore.recent()
            scheduleSearch(for: query)
        }
        .onDisappear {
            debounceTask?.cancel()
            debounceTask = nil
        }
    }

    // MARK: - Input row trailing counter

    @ViewBuilder
    private var counterView: some View {
        if let lastError {
            Text("error: \(lastError)")
                .foregroundStyle(Color(hex: theme.chrome.warning.hex))
        } else if isSearching {
            Text("searching…")
        } else if query.isEmpty {
            Text("type to search")
        } else {
            HStack(spacing: 4) {
                Text("\(fileHitCount)")
                    .foregroundStyle(Color(hex: theme.chrome.activeBorder.hex))
                    .fontWeight(.semibold)
                Text("hits ·")
                Text("\(uniqueFileCount)")
                    .foregroundStyle(Color(hex: theme.chrome.activeBorder.hex))
                    .fontWeight(.semibold)
                Text("files · \(elapsedMs) ms")
            }
        }
    }

    // MARK: - Scope toggle

    private var scopeBar: some View {
        HStack(spacing: BentoSpacing.xs) {
            scopePill(label: "this project", value: .thisProject)
            scopePill(label: "all projects", value: .allProjects)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, BentoSpacing.l)
        .padding(.vertical, BentoSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: theme.chrome.panel.hex).opacity(0.5))
        .overlay(alignment: .bottom) { Hairline(theme: theme) }
    }

    @ViewBuilder
    private func scopePill(label: String, value: SearchScope) -> some View {
        let isActive = scope == value
        Button {
            if scope != value { scope = value }
        } label: {
            Text(label)
                .font(BentoType.mono(11, weight: isActive ? .semibold : .regular))
                .foregroundStyle(Color(hex: isActive
                    ? theme.chrome.activeBorder.hex
                    : theme.chrome.dimText.hex))
                .padding(.horizontal, BentoSpacing.s)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: BentoRadius.small, style: .continuous)
                        .fill(Color(hex: theme.chrome.accentSoft.hex)
                            .opacity(isActive ? 1 : 0))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: BentoRadius.small, style: .continuous)
                        .strokeBorder(
                            Color(hex: isActive
                                ? theme.chrome.activeBorder.hex
                                : theme.chrome.border.hex),
                            lineWidth: 1
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .animation(BentoMotion.hover, value: isActive)
    }

    // MARK: - Results body

    @ViewBuilder
    private var resultsBody: some View {
        if query.isEmpty {
            recentSearchesBody
        } else if results.isEmpty {
            // H-9: surface the search scope in the empty-state copy.
            // `query` is the only context this view has — the
            // project root lives on the controller, so we keep the
            // hint scope-agnostic ("in this project") rather than
            // re-threading the cwd through this view.
            emptyHint(isSearching
                ? "Searching\u{2026}"
                : "No matches in this project \u{2014} try a broader query")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(panelRows.enumerated()), id: \.offset) { _, row in
                            panelRowView(row)
                        }
                    }
                    .padding(.vertical, BentoSpacing.s)
                }
                .frame(maxHeight: 480)
                .onChange(of: highlightedIndex) { _, newValue in
                    let rows = selectableRows
                    guard rows.indices.contains(newValue) else { return }
                    withAnimation(BentoMotion.hover) {
                        proxy.scrollTo("row-\(newValue)", anchor: .center)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func panelRowView(_ row: SearchPanelRow) -> some View {
        switch row {
        case let .fileGroupHeader(projectRoot, path, count):
            FileGroupHeaderRow(
                theme: theme,
                projectRoot: projectRoot,
                path: path,
                count: count
            )
        case let .fileHit(index, hit):
            FileHitRow(
                theme: theme,
                hit: hit,
                query: query,
                isHighlighted: index == highlightedIndex || index == hoveredIndex
            )
            .id("row-\(index)")
            .onTapGesture {
                highlightedIndex = index
                dispatchHighlighted()
            }
            .onHover { hoveredIndex = $0 ? index : nil }
        case let .scrollbackSectionHeader(count):
            HStack(spacing: BentoSpacing.s) {
                SectionLabel(theme: theme, "SCROLLBACK")
                Text("\(count)")
                    .font(BentoType.mono(10))
                    .foregroundStyle(Color(hex: theme.chrome.tertiaryText.hex))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, BentoSpacing.l)
            .padding(.top, BentoSpacing.m)
            .padding(.bottom, BentoSpacing.xs)
        case let .scrollbackHit(index, match, context):
            ScrollbackHitRow(
                theme: theme,
                match: match,
                context: context,
                query: query,
                isHighlighted: index == highlightedIndex || index == hoveredIndex
            )
            .id("row-\(index)")
            .onTapGesture {
                highlightedIndex = index
                dispatchHighlighted()
            }
            .onHover { hoveredIndex = $0 ? index : nil }
        }
    }

    @ViewBuilder
    private var recentSearchesBody: some View {
        if recent.isEmpty {
            emptyHint("Type to search project files and pane scrollback")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: BentoSpacing.s) {
                    SectionLabel(theme: theme, "RECENT SEARCHES")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, BentoSpacing.l)
                .padding(.top, BentoSpacing.m)
                .padding(.bottom, BentoSpacing.xs)

                ForEach(Array(recent.enumerated()), id: \.offset) { _, entry in
                    RecentSearchRow(
                        theme: theme,
                        query: entry,
                        onSelect: {
                            query = entry
                            scheduleSearch(for: entry)
                        },
                        onRemove: {
                            removeRecent(entry)
                        }
                    )
                }
            }
            .padding(.bottom, BentoSpacing.s)
        }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(BentoType.chrome(12))
            .foregroundStyle(Color(hex: theme.chrome.tertiaryText.hex))
            .frame(maxWidth: .infinity)
            .padding(.vertical, BentoSpacing.xxl)
    }

    // MARK: - Search scheduling

    private func scheduleSearch(for query: String) {
        debounceTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            highlightedIndex = 0
            lastError = nil
            isSearching = false
            elapsedMs = 0
            return
        }
        isSearching = true
        let runQuery = trimmed
        let runScope = scope
        debounceTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return
            }
            if Task.isCancelled { return }
            let start = Date()
            do {
                let next = try await search(runQuery, runScope)
                if Task.isCancelled { return }
                results = next
                highlightedIndex = 0
                hoveredIndex = nil
                lastError = nil
                elapsedMs = Int((Date().timeIntervalSince(start) * 1000).rounded())
                // Record only queries that produced at least one hit
                // so the recent-searches list stays useful (and noisy
                // typos don't outnumber real queries).
                if !next.isEmpty {
                    recentStore.record(runQuery)
                    recent = recentStore.recent()
                }
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                results = []
                lastError = String(describing: error)
                elapsedMs = Int((Date().timeIntervalSince(start) * 1000).rounded())
            }
            isSearching = false
        }
    }

    private func removeRecent(_ entry: String) {
        // RecentSearchesStore exposes record() + clear() but not a
        // single-entry remove. Rebuild the list ourselves: filter the
        // entry out, clear, then re-record in reverse so the head ends
        // up matching the original head order.
        var entries = recentStore.recent()
        entries.removeAll(where: { $0 == entry })
        recentStore.clear()
        for q in entries.reversed() {
            recentStore.record(q)
        }
        recent = recentStore.recent()
    }

    // MARK: - Keyboard

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        switch event.keyCode {
        case 53: // escape
            onClose()
            return nil
        case 36, 76: // return / numpad enter
            // ⌥⏎ → peek; plain ⏎ → open in editor.
            if event.modifierFlags.contains(.option) {
                dispatchPeek()
            } else {
                dispatchHighlighted()
            }
            return nil
        case 125: // down arrow
            let rows = selectableRows
            guard !rows.isEmpty else { return nil }
            highlightedIndex = (highlightedIndex + 1) % rows.count
            return nil
        case 126: // up arrow
            let rows = selectableRows
            guard !rows.isEmpty else { return nil }
            highlightedIndex = (highlightedIndex - 1 + rows.count) % rows.count
            return nil
        default:
            return event
        }
    }

    private func dispatchHighlighted() {
        let rows = selectableRows
        guard rows.indices.contains(highlightedIndex) else { return }
        switch rows[highlightedIndex] {
        case .fileHit(_, let hit):
            let url = URL(fileURLWithPath: hit.path)
            onClose()
            onOpenFile(url)
        case .scrollbackHit(_, let match, let context):
            // S-6: plain ⏎ on a scrollback hit jumps to peek too —
            // there's no "open in editor" meaning for a log line, so
            // the only useful action is the inline peek.
            onClose()
            onPeekScrollback(match, context)
        default:
            break
        }
    }

    private func dispatchPeek() {
        let rows = selectableRows
        guard rows.indices.contains(highlightedIndex) else { return }
        switch rows[highlightedIndex] {
        case .scrollbackHit(_, let match, let context):
            onClose()
            onPeekScrollback(match, context)
        case .fileHit(_, let hit):
            // No peek view for files yet — fall back to opening them.
            let url = URL(fileURLWithPath: hit.path)
            onClose()
            onOpenFile(url)
        default:
            break
        }
    }
}

// MARK: - Search overlay rows

/// File group header: `path/to/dir/` + bold filename + match count
/// pill. Mirrors the mockup's `FILE > path/file.swift · N matches`
/// rule. Not selectable.
private struct FileGroupHeaderRow: View {
    let theme: ThemeSpec
    let projectRoot: String
    let path: String
    let count: Int

    var body: some View {
        HStack(spacing: BentoSpacing.s) {
            Text("▸")
                .font(BentoType.mono(11))
                .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
            Text(directoryComponent)
                .font(BentoType.mono(12))
                .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(filenameComponent)
                .font(BentoType.mono(12, weight: .semibold))
                .foregroundStyle(Color(hex: theme.chrome.text.hex))
                .lineLimit(1)
            Spacer(minLength: BentoSpacing.s)
            Text("\(count) match\(count == 1 ? "" : "es")")
                .font(BentoType.mono(10))
                .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
                .padding(.horizontal, BentoSpacing.s)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: BentoRadius.small, style: .continuous)
                        .fill(Color(hex: theme.chrome.accentSoft.hex))
                )
        }
        .padding(.horizontal, BentoSpacing.l)
        .padding(.top, BentoSpacing.m)
        .padding(.bottom, BentoSpacing.xs)
    }

    /// Project-relative display path, leaving the directory chunk
    /// dim and the filename bold. Falls back to the absolute path
    /// when the hit's path doesn't live under `projectRoot`.
    private var relative: String {
        let root = (projectRoot as NSString).standardizingPath
        let p = (path as NSString).standardizingPath
        if p == root { return URL(fileURLWithPath: p).lastPathComponent }
        if p.hasPrefix(root + "/") { return String(p.dropFirst(root.count + 1)) }
        // Not under root — last 3 path components keep the header
        // tidy when ripgrep returns absolute paths from elsewhere.
        let parts = p.split(separator: "/").suffix(3)
        return parts.joined(separator: "/")
    }

    private var filenameComponent: String {
        URL(fileURLWithPath: relative).lastPathComponent
    }

    private var directoryComponent: String {
        let dir = (relative as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir + "/"
    }
}

/// Selectable row for one file hit. Shows the line-number gutter on
/// the left, the matched line (with the matched substring on the
/// `activeBorder` highlight), and a single line of leading/trailing
/// context above and below in dimmed text.
private struct FileHitRow: View {
    let theme: ThemeSpec
    let hit: FileSearchHit
    let query: String
    let isHighlighted: Bool

    var body: some View {
        OverlayRow(theme: theme, isHighlighted: isHighlighted, height: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if let before = hit.contextBefore, !before.isEmpty {
                    contextLine(line: before, number: hit.lineNumber - 1)
                }
                hitLine
                if let after = hit.contextAfter, !after.isEmpty {
                    contextLine(line: after, number: hit.lineNumber + 1)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var hitLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            lineNumberGutter(hit.lineNumber, isHit: true)
            highlightedLine(hit.line, query: query)
                .font(BentoType.mono(12))
                .foregroundStyle(Color(hex: theme.chrome.text.hex))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private func contextLine(line: String, number: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            lineNumberGutter(number, isHit: false)
            Text(line)
                .font(BentoType.mono(11))
                .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func lineNumberGutter(_ number: Int, isHit: Bool) -> some View {
        Text("\(number)")
            .font(BentoType.mono(10, weight: isHit ? .semibold : .regular))
            .foregroundStyle(Color(hex: isHit
                ? theme.chrome.dimText.hex
                : theme.chrome.tertiaryText.hex))
            .frame(width: 44, alignment: .trailing)
            .padding(.trailing, BentoSpacing.m)
    }

    /// Render `line` with the matched substring on the
    /// `activeBorder` background + `invertedText` foreground.
    @ViewBuilder
    private func highlightedLine(_ line: String, query: String) -> some View {
        SearchHighlightedText(
            theme: theme,
            line: line,
            query: query
        )
    }
}

/// Selectable row for one scrollback hit. Left half is the
/// `<project> · <pane> · <relative time>` provenance strip in dim
/// text; right half is the matched line.
private struct ScrollbackHitRow: View {
    let theme: ThemeSpec
    let match: ScrollbackMatch
    let context: ScrollbackMatchContext?
    let query: String
    let isHighlighted: Bool

    var body: some View {
        OverlayRow(theme: theme, isHighlighted: isHighlighted, height: 44) {
            HStack(alignment: .firstTextBaseline, spacing: BentoSpacing.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(metaLine)
                        .font(BentoType.mono(10))
                        .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    SearchHighlightedText(
                        theme: theme,
                        line: match.line,
                        query: query
                    )
                    .font(BentoType.mono(12))
                    .foregroundStyle(Color(hex: theme.chrome.text.hex))
                    .lineLimit(1)
                    .truncationMode(.tail)
                }
                Spacer(minLength: BentoSpacing.s)
                Text("L\(match.lineNumber)")
                    .font(BentoType.mono(10))
                    .foregroundStyle(Color(hex: theme.chrome.tertiaryText.hex))
            }
            .padding(.vertical, BentoSpacing.xs)
        }
    }

    private var metaLine: String {
        let project = context?.projectRoot
            .flatMap { URL(fileURLWithPath: $0).lastPathComponent } ?? "—"
        let pane = context?.paneLabel ?? truncatedPaneID
        let when = context.map { SearchRelativeTime.format($0.lastWriteAt) } ?? ""
        if when.isEmpty {
            return "\(project) · \(pane)"
        }
        return "\(project) · \(pane) · \(when)"
    }

    /// Show the first 8 chars of the pane's uuid when no metadata
    /// sidecar is available — full UUIDs are 36 chars and dominate
    /// the row.
    private var truncatedPaneID: String {
        let raw = match.paneID.rawValue
        if raw.count <= 12 { return raw }
        return String(raw.prefix(8)) + "…"
    }
}

/// Recent-search row in the empty-state list. Mono row with the
/// query text + a small × on hover for one-off removal.
private struct RecentSearchRow: View {
    let theme: ThemeSpec
    let query: String
    let onSelect: () -> Void
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        OverlayRow(theme: theme, isHighlighted: isHovered) {
            HStack(spacing: BentoSpacing.s) {
                Text("⏱")
                    .font(BentoType.mono(11))
                    .foregroundStyle(Color(hex: theme.chrome.tertiaryText.hex))
                Text(query)
                    .font(BentoType.mono(12))
                    .foregroundStyle(Color(hex: theme.chrome.text.hex))
                    .lineLimit(1)
                Spacer(minLength: BentoSpacing.s)
                if isHovered {
                    Button(action: onRemove) {
                        Text("×")
                            .font(BentoType.mono(12, weight: .medium))
                            .foregroundStyle(Color(hex: theme.chrome.tertiaryText.hex))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help("Remove from recent")
                }
            }
        }
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Highlighted line renderer + relative time

/// Render `line` as a single mono `Text` with the matched substring
/// styled on the `activeBorder` background + `invertedText` foreground.
/// Matching is case-insensitive and respects the first occurrence
/// (good enough for ripgrep-style line previews — overlapping repeats
/// happen too rarely to bother building a full multi-segment renderer).
///
/// Implementation note: SwiftUI's `Text + Text` operator preserves
/// concatenation, but `Text.background(_:)` returns a `View`, not a
/// `Text`, so we can't simply concat a highlighted `Text` between two
/// neighbours. We render in an `HStack(spacing: 0)` instead and put
/// the highlight on the middle Text via a `.background` layer.
struct SearchHighlightedText: View {
    let theme: ThemeSpec
    let line: String
    let query: String

    var body: some View {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty,
           let range = line.range(of: trimmedQuery, options: .caseInsensitive) {
            let prefix = String(line[..<range.lowerBound])
            let match = String(line[range])
            let suffix = String(line[range.upperBound...])
            HStack(spacing: 0) {
                Text(prefix)
                Text(match)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color(hex: theme.chrome.invertedText.hex))
                    .padding(.horizontal, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color(hex: theme.chrome.activeBorder.hex))
                    )
                Text(suffix)
            }
        } else {
            Text(line)
        }
    }
}

/// Compact "5m ago" / "yesterday" formatter. Pure helper so it's
/// testable without instantiating any SwiftUI view.
enum SearchRelativeTime {
    static func format(_ date: Date, now: Date = Date()) -> String {
        let delta = now.timeIntervalSince(date)
        if delta < 5 { return "just now" }
        if delta < 60 { return "\(Int(delta))s ago" }
        if delta < 3600 { return "\(Int(delta / 60))m ago" }
        if delta < 86_400 { return "\(Int(delta / 3600))h ago" }
        let days = Int(delta / 86_400)
        if days == 1 { return "yesterday" }
        if days < 7 { return "\(days)d ago" }
        let weeks = days / 7
        if weeks < 5 { return "\(weeks)w ago" }
        let months = days / 30
        if months < 12 { return "\(months)mo ago" }
        return "\(days / 365)y ago"
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
        // The backdrop tint uses the theme's `overlay` swatch (Paper
        // ships a translucent ink so the cream chrome behind it stays
        // visible; dark themes ship a deeper near-black). The 0.55
        // multiplier on top is a global modal-scrim density we want
        // independent of the theme, since the backdrop's primary job
        // is to mute the workspace behind the modal regardless of
        // light/dark mode.
        let overlayRadius = theme.geometry.windowRadius
        return ZStack(alignment: .top) {
            Color(hex: theme.chrome.overlay.hex)
                .opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
            content
                .frame(width: width)
                .background(
                    RoundedRectangle(cornerRadius: overlayRadius, style: .continuous)
                        .fill(Color(hex: theme.chrome.elevated.hex))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: overlayRadius, style: .continuous)
                        .strokeBorder(Color(hex: theme.chrome.border.hex), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: overlayRadius, style: .continuous))
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

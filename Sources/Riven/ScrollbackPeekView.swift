import AppKit
import RivenCore
import SwiftUI

/// S-6: read-only inline view of a pane's scrollback log centered
/// on `focusLine`. Opened from the search overlay's `⌥⏎ peek` action;
/// renders ±20 lines of context around the hit so the user can verify
/// it without committing to a "Replay in new pane" action.
///
/// The view loads bytes lazily (in `task(id:)`) from `ScrollbackStore`
/// because the file can be large. It stays read-only — there is no
/// PTY attached. The "Replay in new pane" toolbar button creates a
/// fresh terminal inner tab so the user can re-run the work that
/// produced the log line. (TODO: the replay path currently just opens
/// a blank shell in the workspace's cwd — feeding the log contents
/// back through the PTY for true replay is non-trivial and deferred.)
struct ScrollbackPeekView: View {
    let theme: ThemeSpec
    let paneID: PaneID
    let focusLine: Int
    /// The on-disk store the view reads bytes from. Injected so tests
    /// (and future previews) can substitute a fixture root.
    let scrollback: ScrollbackStore
    /// Metadata sidecar for `paneID` if one exists. Drives the header
    /// label (`<paneLabel> · <project> · <when>`).
    let metadata: ScrollbackMetadata?
    /// Open a fresh terminal inner tab. Wired up by the parent
    /// (RivenRootController) — the peek view itself doesn't know how
    /// to spawn tabs. Called by the toolbar's "Replay in new pane"
    /// button.
    let onReplayInNewPane: () -> Void

    /// How many lines of context to load on each side of `focusLine`.
    /// 20 fits a typical command's output without overflowing the
    /// surface; the user can scroll within the view if more is
    /// needed. `nonisolated` so the detached task that reads the log
    /// off the main actor can reach the constant without warnings.
    nonisolated static let contextLines: Int = 20

    @State private var lines: [(number: Int, text: String)] = []
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline(theme: theme)
            scrollback_body
        }
        .background(Color(hex: theme.chrome.panel.hex))
        .task(id: taskKey) {
            await loadLines()
        }
    }

    private var taskKey: String {
        "\(paneID.rawValue)|\(focusLine)"
    }

    // MARK: - Header / toolbar

    private var header: some View {
        HStack(spacing: RivenSpacing.s) {
            Image(systemName: "scroll")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(hex: theme.chrome.accent.hex))
            Text(headerTitle)
                .font(RivenType.mono(RivenType.small, weight: .semibold))
                .foregroundStyle(Color(hex: theme.chrome.text.hex))
                .lineLimit(1)
                .truncationMode(.middle)
            if let project = metadata?.projectRoot
                .flatMap({ URL(fileURLWithPath: $0).lastPathComponent }) {
                Text("· \(project)")
                    .font(RivenType.mono(RivenType.small))
                    .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
                    .lineLimit(1)
            }
            if let metadata {
                Text("· \(SearchRelativeTime.format(metadata.lastWriteAt))")
                    .font(RivenType.mono(RivenType.small))
                    .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
                    .lineLimit(1)
            }
            Spacer(minLength: RivenSpacing.s)
            Button(action: onReplayInNewPane) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Replay in new pane")
                        .font(RivenType.mono(RivenType.small, weight: .medium))
                }
                .foregroundStyle(Color(hex: theme.chrome.text.hex))
                .padding(.horizontal, RivenSpacing.s)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: RivenRadius.small, style: .continuous)
                        .fill(Color(hex: theme.chrome.accentSoft.hex))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: RivenRadius.small, style: .continuous)
                        .strokeBorder(Color(hex: theme.chrome.border.hex), lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Open a fresh terminal seeded from this pane's cwd")
        }
        .padding(.horizontal, RivenSpacing.m)
        .frame(height: 36)
        .background(Color(hex: theme.chrome.elevated.hex))
    }

    private var headerTitle: String {
        let label = metadata?.paneLabel ?? truncatedPaneID
        return "\(label):\(focusLine)"
    }

    private var truncatedPaneID: String {
        let raw = paneID.rawValue
        if raw.count <= 12 { return raw }
        return String(raw.prefix(8)) + "…"
    }

    // MARK: - Scrollback body

    @ViewBuilder
    private var scrollback_body: some View {
        if let loadError {
            VStack(spacing: RivenSpacing.s) {
                Text("Couldn't load scrollback")
                    .font(RivenType.chrome(13, weight: .medium))
                    .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
                Text(loadError)
                    .font(RivenType.mono(11))
                    .foregroundStyle(Color(hex: theme.chrome.tertiaryText.hex))
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if lines.isEmpty {
            Text("Loading…")
                .font(RivenType.mono(11))
                .foregroundStyle(Color(hex: theme.chrome.tertiaryText.hex))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines, id: \.number) { line in
                            row(for: line)
                                .id("peek-\(line.number)")
                        }
                    }
                    .padding(.vertical, RivenSpacing.s)
                }
                .onAppear {
                    // Center the highlighted hit on first paint so
                    // the user lands on the line they came for.
                    DispatchQueue.main.async {
                        withAnimation(RivenMotion.standard) {
                            proxy.scrollTo("peek-\(focusLine)", anchor: .center)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(for line: (number: Int, text: String)) -> some View {
        let isFocus = line.number == focusLine
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("\(line.number)")
                .font(RivenType.mono(10, weight: isFocus ? .semibold : .regular))
                .foregroundStyle(Color(hex: isFocus
                    ? theme.chrome.dimText.hex
                    : theme.chrome.tertiaryText.hex))
                .frame(width: 44, alignment: .trailing)
                .padding(.trailing, RivenSpacing.m)
            Text(stripAnsi(line.text))
                .font(RivenType.mono(12, weight: isFocus ? .semibold : .regular))
                .foregroundStyle(Color(hex: theme.chrome.text.hex))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(hex: theme.chrome.selectionBg.hex)
                .opacity(isFocus ? 1 : 0)
        )
        .padding(.horizontal, RivenSpacing.s)
    }

    // MARK: - Loading

    private func loadLines() async {
        // Hop off the main actor for the file read — scrollback logs
        // can be megabytes, and we don't want a hitch in the SwiftUI
        // render pass.
        let paneID = self.paneID
        let focus = self.focusLine
        let store = self.scrollback
        let result: Result<[(Int, String)], Error> = await Task.detached(priority: .userInitiated) {
            do {
                let data = try store.read(paneID)
                let content = String(data: data, encoding: .utf8) ?? ""
                let allLines = content.split(
                    separator: "\n",
                    omittingEmptySubsequences: false
                ).map(String.init)
                // Compute a ±N window around focus (clamped to bounds).
                let lower = max(1, focus - ScrollbackPeekView.contextLines)
                let upper = min(allLines.count, focus + ScrollbackPeekView.contextLines)
                guard lower <= upper else { return .success([]) }
                var out: [(Int, String)] = []
                for n in lower...upper {
                    let idx = n - 1
                    guard idx >= 0, idx < allLines.count else { continue }
                    out.append((n, allLines[idx]))
                }
                return .success(out)
            } catch {
                return .failure(error)
            }
        }.value

        await MainActor.run {
            switch result {
            case .success(let next):
                self.lines = next
                self.loadError = nil
            case .failure(let error):
                self.lines = []
                self.loadError = error.localizedDescription
            }
        }
    }

    /// Lightweight ANSI escape stripper. Scrollback logs include raw
    /// PTY output with colour codes; the peek view doesn't try to
    /// re-render them — we just elide CSI sequences so the text is
    /// readable. (A future polish pass could colour the output via
    /// the terminal palette.)
    private func stripAnsi(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "\u{001B}" {
                // Skip ESC + [ <params> <final>
                let next = s.index(after: i)
                if next < s.endIndex, s[next] == "[" {
                    var j = s.index(after: next)
                    while j < s.endIndex {
                        let ch = s[j]
                        if (ch >= "@" && ch <= "~") {
                            j = s.index(after: j)
                            break
                        }
                        j = s.index(after: j)
                    }
                    i = j
                    continue
                } else {
                    i = next
                    continue
                }
            }
            // Skip carriage returns inside log lines — they show up
            // as spurious gaps with a monospaced font.
            if c == "\r" {
                i = s.index(after: i)
                continue
            }
            out.append(c)
            i = s.index(after: i)
        }
        return out
    }
}

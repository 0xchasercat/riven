import BentoCore
import SwiftUI

enum Overlay {
    case palette
    case search
}

struct CommandPaletteOverlay: View {
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

struct SearchOverlay: View {
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

struct SearchResultRow: View {
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

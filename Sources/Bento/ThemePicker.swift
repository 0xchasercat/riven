import BentoCore
import SwiftUI

/// First-run theme selection. Wears the shared overlay chrome so it feels
/// like a sibling of the command palette / search / trust prompt, even
/// though it's modal-blocking (no esc-to-dismiss).
struct ThemePicker: View {
    let theme: ThemeSpec
    let onSelect: (String) -> Void

    @State private var hoveredID: String?

    var body: some View {
        OverlayBackdrop(theme: theme, width: OverlayWidth.picker, onClose: {}) {
            VStack(spacing: 0) {
                header
                swatches
                OverlayFooter(theme: theme) {
                    Text("press 1, 2, 3 to pick (or click)")
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: BentoSpacing.xs) {
                Text("Choose a theme")
                    .font(BentoType.chrome(15, weight: .semibold))
                    .foregroundStyle(Color(hex: theme.chrome.text.hex))
                Text("Affects window chrome, terminal colors, editor syntax, cursor styling")
                    .font(BentoType.mono(11))
                    .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, BentoSpacing.l)
            .padding(.vertical, BentoSpacing.m)
            Hairline(theme: theme)
        }
    }

    private var swatches: some View {
        HStack(spacing: BentoSpacing.m) {
            ForEach(Array(ThemeSpec.builtIns.enumerated()), id: \.element.id) { index, option in
                Button {
                    onSelect(option.id)
                } label: {
                    ThemeSwatch(
                        theme: theme,
                        option: option,
                        index: index + 1,
                        isHovered: hoveredID == option.id,
                        isSelected: option.id == theme.id
                    )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    hoveredID = hovering ? option.id : (hoveredID == option.id ? nil : hoveredID)
                }
            }
        }
        .padding(BentoSpacing.l)
    }
}

/// Single theme tile. Renders a tiny mock window with a code sample so
/// users can see chrome + syntax colors at a glance, instead of an
/// abstract hex code.
private struct ThemeSwatch: View {
    let theme: ThemeSpec
    let option: ThemeSpec
    let index: Int
    let isHovered: Bool
    let isSelected: Bool

    private static let tileWidth: CGFloat = 200
    private static let tileHeight: CGFloat = 140

    var body: some View {
        VStack(alignment: .leading, spacing: BentoSpacing.s) {
            preview
            HStack(alignment: .firstTextBaseline, spacing: BentoSpacing.xs) {
                Text(option.name)
                    .font(BentoType.chrome(13, weight: .semibold))
                    .foregroundStyle(Color(hex: theme.chrome.text.hex))
                Spacer(minLength: BentoSpacing.xs)
                Text("\(index)")
                    .font(BentoType.mono(10, weight: .semibold))
                    .foregroundStyle(Color(hex: theme.chrome.tertiaryText.hex))
                    .padding(.horizontal, BentoSpacing.xs)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: BentoRadius.small, style: .continuous)
                            .strokeBorder(Color(hex: theme.chrome.hairline.hex), lineWidth: 1)
                    )
            }
        }
        .padding(BentoSpacing.s)
        .frame(width: Self.tileWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: BentoRadius.medium, style: .continuous)
                .fill(Color(hex: theme.chrome.panel.hex))
        )
        .overlay(
            RoundedRectangle(cornerRadius: BentoRadius.medium, style: .continuous)
                .strokeBorder(borderColor, lineWidth: borderWidth)
        )
        .animation(BentoMotion.hover, value: isHovered)
        .animation(BentoMotion.hover, value: isSelected)
    }

    private var borderColor: Color {
        if isSelected || isHovered {
            return Color(hex: theme.chrome.accent.hex)
        }
        return Color(hex: theme.chrome.border.hex)
    }

    private var borderWidth: CGFloat {
        (isSelected || isHovered) ? 1.5 : 1
    }

    /// Tiny mock terminal/editor preview using the option's own colors —
    /// chrome bar with traffic-light dots, then a few lines of "code"
    /// using the option's syntax palette.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Faux titlebar with dots.
            HStack(spacing: 4) {
                Circle().fill(Color(hex: option.chrome.danger.hex)).frame(width: 6, height: 6)
                Circle().fill(Color(hex: option.chrome.warning.hex)).frame(width: 6, height: 6)
                Circle().fill(Color(hex: option.chrome.success.hex)).frame(width: 6, height: 6)
                Spacer(minLength: 0)
                Text("~")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Color(hex: option.chrome.dimText.hex))
            }
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Color(hex: option.chrome.elevated.hex))

            // Code body.
            VStack(alignment: .leading, spacing: 3) {
                codeLine([
                    (text: "func", color: option.syntax.keyword.hex),
                    (text: " ", color: option.terminal.foreground.hex),
                    (text: "bento", color: option.syntax.function.hex),
                    (text: "() {", color: option.terminal.foreground.hex)
                ])
                codeLine([
                    (text: "  let ", color: option.syntax.keyword.hex),
                    (text: "msg ", color: option.terminal.foreground.hex),
                    (text: "= ", color: option.terminal.foreground.hex),
                    (text: "\"hi\"", color: option.syntax.string.hex)
                ])
                codeLine([
                    (text: "  // a comment", color: option.syntax.comment.hex)
                ])
                HStack(spacing: 2) {
                    Text("$")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color(hex: option.terminal.prompt.hex))
                    Rectangle()
                        .fill(Color(hex: option.terminal.cursor.hex))
                        .frame(width: 5, height: 9)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(hex: option.terminal.background.hex))
        }
        .frame(height: Self.tileHeight)
        .clipShape(RoundedRectangle(cornerRadius: BentoRadius.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: BentoRadius.small, style: .continuous)
                .strokeBorder(Color(hex: option.chrome.border.hex), lineWidth: 1)
        )
    }

    private func codeLine(_ runs: [(text: String, color: String)]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                Text(run.text)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color(hex: run.color))
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }
}

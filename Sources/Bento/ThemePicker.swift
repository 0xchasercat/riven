import AppKit
import BentoCore
import SwiftUI

/// Theme selection overlay. Used both as the first-run picker (where
/// it's modal-blocking) and as the regular "Preferences → Theme…"
/// entry (where esc + outside-click dismiss it). Wears the shared
/// overlay chrome so it feels like a sibling of the command palette
/// and search.
struct ThemePicker: View {
    let theme: ThemeSpec
    let onSelect: (String) -> Void
    /// `true` for first-run (modal): esc and backdrop tap are no-ops.
    /// `false` for the menu/palette entry: esc + backdrop dismiss.
    var dismissible: Bool = false
    var onClose: () -> Void = {}

    @State private var hoveredID: String?

    private var options: [ThemeSpec] {
        ThemeSpec.all()
    }

    var body: some View {
        OverlayBackdrop(
            theme: theme,
            width: OverlayWidth.picker,
            onClose: { if dismissible { onClose() } }
        ) {
            VStack(spacing: 0) {
                header
                swatches
                OverlayFooter(theme: theme) {
                    Text(footerHint)
                }
            }
        }
        .background(KeyEventHandling { event in
            // Esc dismisses when the picker isn't modal (first-run is
            // modal and intentionally swallows esc).
            if event.keyCode == 53 && dismissible {
                onClose()
                return nil
            }
            // Number-row 1…9 picks the corresponding theme. Lets
            // keyboard-first users avoid the mouse, matches the
            // footer's "press 1, 2, 3…" hint.
            if let chars = event.charactersIgnoringModifiers,
               let digit = Int(chars), digit >= 1, digit <= options.count {
                let id = options[digit - 1].id
                onSelect(id)
                if dismissible { onClose() }
                return nil
            }
            return event
        })
    }

    private var footerHint: String {
        let max = min(options.count, 9)
        let nums = (1...max).map(String.init).joined(separator: ", ")
        if dismissible {
            return "press \(nums) to pick · esc to dismiss · click to select"
        }
        return "press \(nums) to pick (or click)"
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: BentoSpacing.m) {
                VStack(alignment: .leading, spacing: BentoSpacing.xs) {
                    Text("Choose a theme")
                        .font(BentoType.chrome(15, weight: .semibold))
                        .foregroundStyle(Color(hex: theme.chrome.text.hex))
                    Text("Affects window chrome, terminal colors, editor syntax, cursor styling")
                        .font(BentoType.mono(11))
                        .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if dismissible {
                    OverlaySecondaryButton(theme: theme, title: "Done", action: onClose)
                }
            }
            .padding(.horizontal, BentoSpacing.l)
            .padding(.vertical, BentoSpacing.m)
            Hairline(theme: theme)
        }
    }

    private var swatches: some View {
        // Wrap into rows so custom-theme users with >4 themes don't push
        // the overlay off the right edge. 4 per row matches the builtin
        // count so the first-run layout is unchanged.
        let columns = 4
        let rows = stride(from: 0, to: options.count, by: columns).map {
            Array(options[$0..<min($0 + columns, options.count)])
        }
        return VStack(spacing: BentoSpacing.m) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, rowThemes in
                HStack(spacing: BentoSpacing.m) {
                    ForEach(Array(rowThemes.enumerated()), id: \.element.id) { colIdx, option in
                        let absoluteIndex = rowIdx * columns + colIdx
                        Button {
                            onSelect(option.id)
                            if dismissible { onClose() }
                        } label: {
                            ThemeSwatch(
                                theme: theme,
                                option: option,
                                index: absoluteIndex + 1,
                                isHovered: hoveredID == option.id,
                                isSelected: option.id == theme.id,
                                isCustom: !ThemeSpec.builtIns.contains(where: { $0.id == option.id })
                            )
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            hoveredID = hovering ? option.id : (hoveredID == option.id ? nil : hoveredID)
                        }
                    }
                    if rowThemes.count < columns {
                        // Keep last row left-aligned by padding with
                        // invisible spacers sized like a swatch slot.
                        Spacer(minLength: 0)
                    }
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
    let isCustom: Bool

    private static let tileWidth: CGFloat = 200
    private static let tileHeight: CGFloat = 140

    var body: some View {
        VStack(alignment: .leading, spacing: BentoSpacing.s) {
            preview
            HStack(alignment: .firstTextBaseline, spacing: BentoSpacing.xs) {
                Text(option.name)
                    .font(BentoType.chrome(13, weight: .semibold))
                    .foregroundStyle(Color(hex: theme.chrome.text.hex))
                if isCustom {
                    Text("custom")
                        .font(BentoType.mono(9, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(Color(hex: theme.chrome.tertiaryText.hex))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: BentoRadius.small, style: .continuous)
                                .fill(Color(hex: theme.chrome.accentSoft.hex))
                        )
                }
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

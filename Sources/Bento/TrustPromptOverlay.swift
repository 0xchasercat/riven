import AppKit
import BentoCore
import SwiftUI

/// Overlay that asks the user to trust a project before its declared task
/// panes auto-start. Shares the overlay chrome (header / body / footer)
/// with `CommandPaletteOverlay`, `SearchOverlay`, and `ThemePicker` so
/// the four feel like one product, not four prototypes.
struct TrustPromptOverlay: View {
    let theme: ThemeSpec
    let projectRoot: String
    let pendingCommands: [String]
    let onTrust: () -> Void
    let onDismiss: () -> Void

    init(
        theme: ThemeSpec,
        projectRoot: String,
        pendingCommands: [String],
        onTrust: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.theme = theme
        self.projectRoot = projectRoot
        self.pendingCommands = pendingCommands
        self.onTrust = onTrust
        self.onDismiss = onDismiss
    }

    var body: some View {
        OverlayBackdrop(theme: theme, width: OverlayWidth.standard, onClose: onDismiss) {
            VStack(spacing: 0) {
                header
                bodySection
                footer
            }
        }
        .background(KeyEventHandling(handler: handleKey))
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: BentoSpacing.xs) {
                Text("Trust this project")
                    .font(BentoType.chrome(15, weight: .semibold))
                    .foregroundStyle(Color(hex: theme.chrome.text.hex))
                Text(projectRoot)
                    .font(BentoType.mono(11))
                    .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, BentoSpacing.l)
            .padding(.vertical, BentoSpacing.m)
            Hairline(theme: theme)
        }
    }

    private var bodySection: some View {
        VStack(alignment: .leading, spacing: BentoSpacing.s) {
            SectionLabel(theme: theme, "WILL AUTO-START")
            if pendingCommands.isEmpty {
                Text("No commands declared")
                    .font(BentoType.mono(12))
                    .foregroundStyle(Color(hex: theme.chrome.tertiaryText.hex))
            } else {
                VStack(alignment: .leading, spacing: BentoSpacing.xs) {
                    ForEach(Array(pendingCommands.enumerated()), id: \.offset) { _, command in
                        commandPill(command)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, BentoSpacing.l)
        .padding(.vertical, BentoSpacing.l)
    }

    private func commandPill(_ command: String) -> some View {
        Text(command)
            .font(BentoType.mono(12))
            .foregroundStyle(Color(hex: theme.chrome.accent.hex))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, BentoSpacing.s)
            .padding(.vertical, BentoSpacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: BentoRadius.small, style: .continuous)
                    .fill(Color(hex: theme.chrome.panel.hex))
            )
            .overlay(
                RoundedRectangle(cornerRadius: BentoRadius.small, style: .continuous)
                    .strokeBorder(Color(hex: theme.chrome.hairline.hex), lineWidth: 1)
            )
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Hairline(theme: theme)
            HStack(spacing: BentoSpacing.s) {
                Text("⏎ trust · esc dismiss")
                    .font(BentoType.mono(10))
                    .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
                Spacer(minLength: BentoSpacing.m)
                OverlaySecondaryButton(theme: theme, title: "Not yet", action: onDismiss)
                OverlayPrimaryButton(theme: theme, title: "Trust this project", action: onTrust)
            }
            .padding(.horizontal, BentoSpacing.l)
            .padding(.vertical, BentoSpacing.s)
        }
    }

    // MARK: - Keyboard

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        switch event.keyCode {
        case 53: // escape
            onDismiss()
            return nil
        case 36, 76: // return / numpad enter
            onTrust()
            return nil
        default:
            return event
        }
    }
}

import AppKit
import RivenCore
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
            VStack(alignment: .leading, spacing: RivenSpacing.xs) {
                Text("Trust this project")
                    .font(RivenType.chrome(15, weight: .semibold))
                    .foregroundStyle(Color(hex: theme.chrome.text.hex))
                Text(projectRoot)
                    .font(RivenType.mono(11))
                    .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, RivenSpacing.l)
            .padding(.vertical, RivenSpacing.m)
            Hairline(theme: theme)
        }
    }

    private var bodySection: some View {
        VStack(alignment: .leading, spacing: RivenSpacing.s) {
            SectionLabel(theme: theme, "WILL AUTO-START")
            if pendingCommands.isEmpty {
                Text("No commands declared")
                    .font(RivenType.mono(12))
                    .foregroundStyle(Color(hex: theme.chrome.tertiaryText.hex))
            } else {
                VStack(alignment: .leading, spacing: RivenSpacing.xs) {
                    ForEach(Array(pendingCommands.enumerated()), id: \.offset) { _, command in
                        commandPill(command)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, RivenSpacing.l)
        .padding(.vertical, RivenSpacing.l)
    }

    private func commandPill(_ command: String) -> some View {
        Text(command)
            .font(RivenType.mono(12))
            .foregroundStyle(Color(hex: theme.chrome.accent.hex))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, RivenSpacing.s)
            .padding(.vertical, RivenSpacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: RivenRadius.small, style: .continuous)
                    .fill(Color(hex: theme.chrome.panel.hex))
            )
            .overlay(
                RoundedRectangle(cornerRadius: RivenRadius.small, style: .continuous)
                    .strokeBorder(Color(hex: theme.chrome.hairline.hex), lineWidth: 1)
            )
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Hairline(theme: theme)
            HStack(spacing: RivenSpacing.s) {
                Text("⏎ trust · esc dismiss")
                    .font(RivenType.mono(10))
                    .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
                Spacer(minLength: RivenSpacing.m)
                OverlaySecondaryButton(theme: theme, title: "Not yet", action: onDismiss)
                OverlayPrimaryButton(theme: theme, title: "Trust this project", action: onTrust)
            }
            .padding(.horizontal, RivenSpacing.l)
            .padding(.vertical, RivenSpacing.s)
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

import AppKit
import BentoCore
import SwiftUI

/// Overlay that asks the user to trust a project before its declared task panes
/// auto-start. Mirrors the visual treatment of `CommandPaletteOverlay` and
/// `SearchOverlay`: dim backdrop, panel-colored body, monospaced rows for any
/// shell-flavored content, theme-driven colors throughout.
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
        OverlayBackdrop(theme: theme, onClose: onDismiss) {
            VStack(alignment: .leading, spacing: 18) {
                header
                pendingCommandsSection
                footer
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 22)
            .frame(width: 620, alignment: .leading)
        }
        .background(TrustPromptKeyEventHandling(handler: handleKey))
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Trust this project to auto-start its task panes")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color(hex: theme.chrome.text.hex))
                .fixedSize(horizontal: false, vertical: true)

            Text(projectRoot)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var pendingCommandsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PENDING COMMANDS")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(hex: theme.chrome.dimText.hex))

            if pendingCommands.isEmpty {
                Text("no commands declared")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(pendingCommands.enumerated()), id: \.offset) { _, entry in
                        Text("$ \(entry)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color(hex: theme.chrome.text.hex))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(hex: theme.chrome.background.hex))
                .overlay(Rectangle().stroke(Color(hex: theme.chrome.border.hex), lineWidth: 1))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            secondaryButton(title: "Not yet", action: onDismiss)
            primaryButton(title: "Trust this project", action: onTrust)
        }
    }

    // MARK: - Buttons

    private func secondaryButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .overlay(Rectangle().stroke(Color(hex: theme.chrome.border.hex), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func primaryButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(hex: theme.chrome.background.hex))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(hex: theme.chrome.activeBorder.hex))
        }
        .buttonStyle(.plain)
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

// MARK: - Key event bridge (local copy)

/// Local copy of the `KeyEventHandling` pattern used by the other overlays.
/// Installs a local `NSEvent` monitor so Escape and Return reach the overlay
/// even though no `TextField` is the first responder here. We keep this as a
/// private type to avoid editing `Overlays.swift`.
private struct TrustPromptKeyEventHandling: NSViewRepresentable {
    let handler: (NSEvent) -> NSEvent?

    func makeNSView(context: Context) -> TrustPromptKeyEventMonitorView {
        TrustPromptKeyEventMonitorView(handler: handler)
    }

    func updateNSView(_ nsView: TrustPromptKeyEventMonitorView, context: Context) {
        nsView.handler = handler
    }

    static func dismantleNSView(_ nsView: TrustPromptKeyEventMonitorView, coordinator: ()) {
        nsView.tearDown()
    }
}

private final class TrustPromptKeyEventMonitorView: NSView {
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

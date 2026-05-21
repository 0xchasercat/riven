import AppKit
import BentoCore
import SwiftUI

/// H-6: app-wide non-modal toast band shown above the focused
/// workspace. Replaces ad-hoc one-off banners (the H-3 project-
/// fallback strip, the editor pane's per-pane save-error overlay,
/// the search overlay's silent error swallow) with a single
/// theme-aware affordance. NSAlert is still used for *destructive*
/// prompts (close-dirty, quit-dirty) where blocking the user is the
/// correct affordance; everything else flows through here.
///
/// Semantics:
///   * One banner at a time. Calling `showBanner(...)` while a
///     banner is on screen *replaces* it — no queue. This matches
///     how a real toast tray would behave: the most recent thing
///     the system has to tell you wins, and stacked toasts make
///     dismissal patterns ambiguous (do I dismiss the top one or
///     the bottom one?). If we need a queue later, the public API
///     doesn't need to change.
///   * `autoDismissAfter` defaults to 5s. Pass nil to keep the
///     banner up until the user closes it (used for sticky
///     warnings — e.g. project-fallback notices).
///   * The view slides down from the top edge + fades in, mirroring
///     the existing `.transition(.move(edge: .top).combined(with:
///     .opacity))` used by the project-fallback strip so the chrome
///     reads as one consistent toast layer.
enum BannerKind: Equatable {
    case info
    case success
    case warning
    case error
}

/// Snapshot of a banner the controller wants on-screen. Each
/// invocation of `showBanner` produces a fresh value with a unique
/// `id`, so the SwiftUI auto-dismiss `.task(id:)` restarts its
/// countdown on every re-show rather than inheriting the previous
/// banner's remaining time.
struct BentoBannerState: Equatable, Identifiable {
    let id: UUID
    let message: String
    let kind: BannerKind
    let autoDismissAfter: TimeInterval?

    init(
        id: UUID = UUID(),
        message: String,
        kind: BannerKind,
        autoDismissAfter: TimeInterval?
    ) {
        self.id = id
        self.message = message
        self.kind = kind
        self.autoDismissAfter = autoDismissAfter
    }
}

/// The actual chrome strip. Sibling of the workspace tab bar in
/// `BentoRootView.mainColumn`. Themed via `theme.chrome` so each
/// banner kind picks up the matching semantic slot:
///   * `.error`   → `chrome.danger`   (red)
///   * `.warning` → `chrome.warning`  (amber)
///   * `.success` → `chrome.success`  (green)
///   * `.info`    → `chrome.accent`   (theme accent)
///
/// All four use a 0.18-alpha tinted background so the strip reads
/// as an advisory band rather than a solid colored block, matching
/// the H-3 ProjectFallbackBanner pattern that originally inspired
/// this component.
struct BentoBanner: View {
    let theme: ThemeSpec
    let state: BentoBannerState
    let onDismiss: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: BentoSpacing.s) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(hex: tintHex))
                .accessibilityHidden(true)
            Text(state.message)
                .font(BentoType.mono(BentoType.small))
                .foregroundStyle(Color(hex: theme.chrome.text.hex))
                .lineLimit(2)
                .truncationMode(.tail)
                .accessibilityLabel(state.message)
            Spacer(minLength: BentoSpacing.s)
            Button(action: onDismiss) {
                Text("\u{00D7}") // multiplication sign — matches the rest of the chrome's × glyphs
                    .font(BentoType.chrome(13, weight: .medium))
                    .foregroundStyle(Color(hex: isHovered
                        ? theme.chrome.text.hex
                        : theme.chrome.tertiaryText.hex))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .onHover { isHovered = $0 }
            .help("Dismiss")
        }
        .padding(.horizontal, BentoSpacing.m)
        .frame(minHeight: 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: tintHex).opacity(0.18))
        .overlay(alignment: .bottom) { Hairline(theme: theme) }
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }

    private var iconName: String {
        switch state.kind {
        case .info:    return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.octagon.fill"
        }
    }

    /// Pick the theme's semantic slot per banner kind. `info` borrows
    /// the accent slot rather than `dimText` so it still reads as a
    /// foreground tint against the 0.18-alpha wash; every theme ships
    /// an accent designed to pop, which is the right read for "the
    /// system wants you to notice this."
    private var tintHex: String {
        switch state.kind {
        case .info:    return theme.chrome.accent.hex
        case .success: return theme.chrome.success.hex
        case .warning: return theme.chrome.warning.hex
        case .error:   return theme.chrome.danger.hex
        }
    }
}

/// Host view used by `BentoRootView` to wrap the banner in its
/// auto-dismiss `.task(id:)` so the chrome strip can be rebuilt
/// per-banner without the parent view managing a Task handle.
struct BentoBannerHost: View {
    let theme: ThemeSpec
    let state: BentoBannerState
    let onDismiss: () -> Void

    var body: some View {
        BentoBanner(theme: theme, state: state, onDismiss: onDismiss)
            .task(id: state.id) {
                // Auto-dismiss after the configured interval. We
                // capture `state.id` in the task id so a fresh
                // banner (different id) cancels the previous task
                // and restarts its own countdown — exactly the
                // behavior we want when a second `showBanner` call
                // replaces the first.
                guard let delay = state.autoDismissAfter, delay > 0 else { return }
                let nanos = UInt64(delay * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                if !Task.isCancelled {
                    onDismiss()
                }
            }
    }
}

import AppKit
import BentoCore
import SwiftUI

/// Warp-style command bar pinned at the bottom of a terminal pane.
///
/// Visually, the bar reads as the "input zone": a prompt glyph anchors the
/// left edge, a real `NSTextView` carries the buffer (full Cocoa key
/// bindings, undo, multi-line composition, paste-as-text, history walk),
/// and a return-key affordance on the right confirms that pressing Enter
/// will actually do something. The whole bar lifts above the pane with
/// the `elevated` chrome and gets a subtle accent underline when focused.
///
/// Today every keystroke goes straight to the PTY, which means the
/// shell's own line editor is the only editing model the user gets. This
/// view replaces that experience with a real macOS text input. Pressing
/// Enter (no modifier) submits the buffer to the orchestrator via
/// `onSubmit`, which forwards it to the PTY.
///
/// The view manages its own buffer state. After a submit it clears.
/// History is opt-in: callers wire `onHistoryRequest` to whatever store
/// they prefer (typically `CommandHistory` from BentoCore).
struct CommandBarView: View {
    enum HistoryDirection { case previous, next }

    private let theme: ThemeSpec
    private let onSubmit: (String) -> Void
    private let onHistoryRequest: (HistoryDirection) -> String?

    @State private var text: String = ""
    /// Measured intrinsic content height of the text view, in points.
    /// Driven from the AppKit layer via the coordinator and clamped into
    /// the [singleLineHeight, maxHeight] range below before we use it as
    /// the SwiftUI frame height. Keeping the raw value in `@State` lets
    /// transitions be smooth — we only animate the clamped output.
    @State private var contentHeight: CGFloat = CommandBarMetrics.singleLineHeight
    /// `true` when the embedded `NSTextView` is the window's first
    /// responder. Driven from the AppKit layer; powers the focus underline
    /// and the bolder prompt glyph.
    @State private var isFocused: Bool = false

    init(
        theme: ThemeSpec,
        onSubmit: @escaping (String) -> Void,
        onHistoryRequest: @escaping (HistoryDirection) -> String? = { _ in nil }
    ) {
        self.theme = theme
        self.onSubmit = onSubmit
        self.onHistoryRequest = onHistoryRequest
    }

    var body: some View {
        let clampedHeight = clampHeight(contentHeight)
        // The full bar height = the text input's clamped height plus the
        // vertical padding we add around the text container. Used by the
        // backgrounds + borders so they animate in lockstep with growth.
        let barHeight = clampedHeight + BentoSpacing.s * 2
        let hasText = !text.isEmpty

        HStack(alignment: .top, spacing: BentoSpacing.s) {
            promptGlyph

            CommandBarTextView(
                theme: theme,
                text: $text,
                contentHeight: $contentHeight,
                isFocused: $isFocused,
                onSubmit: handleSubmit,
                onHistoryRequest: handleHistoryRequest,
                onCancel: handleCancel
            )
            .frame(height: clampedHeight)

            submitAffordance(hasText: hasText)
        }
        .padding(.leading, BentoSpacing.s)
        .padding(.trailing, BentoSpacing.s)
        .padding(.vertical, BentoSpacing.s)
        .frame(height: barHeight)
        .background(
            Color(hex: theme.chrome.elevated.hex)
        )
        .overlay(alignment: .top) {
            // Hairline divider separating the bar from the terminal grid
            // above. The Hairline helper uses theme.chrome.hairline.
            Hairline(theme: theme, axis: .horizontal)
        }
        .overlay(alignment: .bottom) {
            // Focus underline. We always render a 1pt rectangle so the
            // animation can smoothly cross-fade between the resting
            // (clear) and focused (accent) states.
            Rectangle()
                .fill(Color(hex: theme.chrome.accent.hex))
                .frame(height: 1)
                .opacity(isFocused ? 1 : 0)
                .animation(BentoMotion.hover, value: isFocused)
        }
        .animation(.easeOut(duration: 0.12), value: clampedHeight)
    }

    // MARK: - Decorations

    /// Prompt glyph on the left. Subtly bolder when the input is focused
    /// so the eye follows the bar's active state without screaming.
    private var promptGlyph: some View {
        // U+276F (HEAVY RIGHT-POINTING ANGLE QUOTATION MARK ORNAMENT) is
        // the canonical chevron glyph. SF Mono ships it on every modern
        // macOS so the fallback path is purely defensive.
        Text("\u{276F}")
            .font(BentoType.mono(BentoType.body, weight: isFocused ? .bold : .semibold))
            .foregroundStyle(Color(hex: theme.chrome.accent.hex))
            .frame(width: 14, height: CommandBarMetrics.singleLineHeight, alignment: .center)
            .animation(BentoMotion.hover, value: isFocused)
    }

    /// Return-key affordance on the right edge. Dim by default; when
    /// there's text in the buffer it brightens to accent — a visual
    /// confirmation that pressing Enter will do something.
    private func submitAffordance(hasText: Bool) -> some View {
        Text("\u{21A9}")
            .font(BentoType.mono(BentoType.caption))
            .foregroundStyle(
                Color(hex: hasText ? theme.chrome.accent.hex : theme.chrome.tertiaryText.hex)
            )
            .frame(width: 24, height: CommandBarMetrics.singleLineHeight, alignment: .center)
            .animation(BentoMotion.hover, value: hasText)
            .accessibilityLabel(hasText ? "Run command" : "Return")
    }

    private func clampHeight(_ raw: CGFloat) -> CGFloat {
        let minH = CommandBarMetrics.singleLineHeight
        let maxH = CommandBarMetrics.maxHeight
        if raw.isNaN || raw <= 0 { return minH }
        return min(max(raw, minH), maxH)
    }

    // MARK: - Callbacks from the AppKit text view

    private func handleSubmit(_ value: String) {
        // Snapshot then clear so the SwiftUI text reset doesn't race the
        // delegate that's still mid-event.
        let payload = value
        text = ""
        contentHeight = CommandBarMetrics.singleLineHeight
        onSubmit(payload)
    }

    private func handleHistoryRequest(_ direction: HistoryDirection) -> String? {
        onHistoryRequest(direction)
    }

    private func handleCancel() {
        text = ""
        contentHeight = CommandBarMetrics.singleLineHeight
    }
}

/// Layout constants. Centralized so the AppKit text view, the SwiftUI
/// frame, and the prompt glyph stay aligned.
private enum CommandBarMetrics {
    /// Resting height of the text container at a single line of text.
    /// Tuned to fit `BentoType.mono`-sized text comfortably with the
    /// `textInsetY` padding inside the scroll view.
    static let singleLineHeight: CGFloat = 24
    /// Approximate per-line growth used for the cap calculation.
    static let lineHeight: CGFloat = 17
    /// Cap so the bar can't swallow the terminal grid: starting at the
    /// resting height plus seven extra lines = roughly eight rows tall.
    static let maxHeight: CGFloat = singleLineHeight + 7 * lineHeight
    /// Font size for the input + placeholder. Matches `BentoType.body`
    /// so the input feels related to the rest of the chrome typography.
    static let fontSize: CGFloat = BentoType.body
    /// Horizontal inset inside the scroll view. The HStack already pads
    /// the bar; we don't want the text to drift further off the prompt.
    static let textInsetX: CGFloat = 0
    /// Vertical inset inside the scroll view. Centers single-line text
    /// in the resting height and keeps the cursor off the top/bottom edge.
    static let textInsetY: CGFloat = BentoSpacing.xs
}

// MARK: - AppKit bridge

/// Thin `NSViewRepresentable` wrapping an `NSTextView` inside an
/// `NSScrollView`. The coordinator owns key interception (Enter,
/// Shift+Enter, Up/Down, Escape) and reports content height + focus
/// changes back to SwiftUI via bindings so the bar can grow, shrink,
/// and light up with the buffer.
private struct CommandBarTextView: NSViewRepresentable {
    let theme: ThemeSpec
    @Binding var text: String
    @Binding var contentHeight: CGFloat
    @Binding var isFocused: Bool
    let onSubmit: (String) -> Void
    let onHistoryRequest: (CommandBarView.HistoryDirection) -> String?
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            contentHeight: $contentHeight,
            isFocused: $isFocused,
            onSubmit: onSubmit,
            onHistoryRequest: onHistoryRequest,
            onCancel: onCancel
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none

        let textView = CommandInputTextView()
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.smartInsertDeleteEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isFieldEditor = false
        textView.usesFindBar = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(
            width: CommandBarMetrics.textInsetX,
            height: CommandBarMetrics.textInsetY
        )
        textView.font = monospacedFont
        textView.textColor = NSColor(hex: theme.chrome.text.hex)
        textView.insertionPointColor = NSColor(hex: theme.chrome.accent.hex)
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(hex: theme.chrome.accent.hex).withAlphaComponent(0.28)
        ]
        textView.placeholderString = "Type a command — \u{23CE} run, \u{21E7}\u{23CE} newline, \u{2191}\u{2193} history, esc clear"
        textView.placeholderColor = NSColor(hex: theme.chrome.tertiaryText.hex)

        // A horizontally-resizing container with line wrapping is what
        // gives us multi-line behavior without a manual line-break pass.
        if let container = textView.textContainer {
            container.widthTracksTextView = true
            container.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            container.lineFragmentPadding = 0
        }
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        context.coordinator.attach(textView: textView, scrollView: scrollView)
        // Prime measured height so the SwiftUI frame is correct on the
        // very first layout pass (otherwise we briefly render at 0pt).
        DispatchQueue.main.async { [weak coordinator = context.coordinator] in
            coordinator?.recomputeContentHeight()
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(
            onSubmit: onSubmit,
            onHistoryRequest: onHistoryRequest,
            onCancel: onCancel
        )
        guard let textView = scrollView.documentView as? CommandInputTextView else { return }
        textView.font = monospacedFont
        textView.textColor = NSColor(hex: theme.chrome.text.hex)
        textView.insertionPointColor = NSColor(hex: theme.chrome.accent.hex)
        textView.placeholderColor = NSColor(hex: theme.chrome.tertiaryText.hex)
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(hex: theme.chrome.accent.hex).withAlphaComponent(0.28)
        ]

        // Sync the AppKit buffer with the SwiftUI state when SwiftUI is
        // the source of truth (e.g. after a submit clears `text`). Avoid
        // touching the view if it already matches — otherwise we lose
        // selection and undo each render pass.
        if textView.string != text {
            textView.applyExternalText(text)
            context.coordinator.recomputeContentHeight()
        }
    }

    private var monospacedFont: NSFont {
        // Prefer SF Mono with a Menlo fallback. NSFont.monospaced…(…)
        // already does the right thing on modern macOS, but the explicit
        // chain keeps the intent obvious in code reviews.
        if let sf = NSFont(name: "SFMono-Regular", size: CommandBarMetrics.fontSize) {
            return sf
        }
        if let menlo = NSFont(name: "Menlo", size: CommandBarMetrics.fontSize) {
            return menlo
        }
        return NSFont.monospacedSystemFont(ofSize: CommandBarMetrics.fontSize, weight: .regular)
    }

    @MainActor
    final class Coordinator: NSObject, @MainActor NSTextViewDelegate {
        private let textBinding: Binding<String>
        private let contentHeightBinding: Binding<CGFloat>
        private let isFocusedBinding: Binding<Bool>
        private var onSubmit: (String) -> Void
        private var onHistoryRequest: (CommandBarView.HistoryDirection) -> String?
        private var onCancel: () -> Void

        weak var textView: CommandInputTextView?
        weak var scrollView: NSScrollView?

        /// Suppresses the "any user edit invalidates the history cursor"
        /// hook while we're programmatically replacing the buffer with a
        /// history entry. Without this, walking history would
        /// immediately reset the cursor after the first up-arrow.
        var isApplyingHistory: Bool = false

        init(
            text: Binding<String>,
            contentHeight: Binding<CGFloat>,
            isFocused: Binding<Bool>,
            onSubmit: @escaping (String) -> Void,
            onHistoryRequest: @escaping (CommandBarView.HistoryDirection) -> String?,
            onCancel: @escaping () -> Void
        ) {
            self.textBinding = text
            self.contentHeightBinding = contentHeight
            self.isFocusedBinding = isFocused
            self.onSubmit = onSubmit
            self.onHistoryRequest = onHistoryRequest
            self.onCancel = onCancel
        }

        func attach(textView: CommandInputTextView, scrollView: NSScrollView) {
            self.textView = textView
            self.scrollView = scrollView
        }

        func update(
            onSubmit: @escaping (String) -> Void,
            onHistoryRequest: @escaping (CommandBarView.HistoryDirection) -> String?,
            onCancel: @escaping () -> Void
        ) {
            self.onSubmit = onSubmit
            self.onHistoryRequest = onHistoryRequest
            self.onCancel = onCancel
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            let value = textView.string
            // Push to SwiftUI on the next runloop tick; mutating bindings
            // mid-delegate can confuse SwiftUI's update cycle.
            let binding = textBinding
            DispatchQueue.main.async {
                if binding.wrappedValue != value {
                    binding.wrappedValue = value
                }
            }
            recomputeContentHeight()
        }

        // MARK: Focus reporting

        /// Pushes a focus state change up to SwiftUI on the next tick.
        /// Called by `CommandInputTextView` on first-responder transitions
        /// so the bar's focus underline + prompt weight can react.
        func reportFocus(_ focused: Bool) {
            let binding = isFocusedBinding
            DispatchQueue.main.async {
                if binding.wrappedValue != focused {
                    binding.wrappedValue = focused
                }
            }
        }

        // MARK: Key intercept entry points (called from NSTextView subclass)

        /// Returns `true` if the event was handled (i.e. NSTextView
        /// should not run its default behavior).
        func handleKeyDown(_ event: NSEvent) -> Bool {
            guard let textView else { return false }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isShift = mods.contains(.shift)
            let isCommand = mods.contains(.command)
            let isOption = mods.contains(.option)
            let isControl = mods.contains(.control)

            switch event.keyCode {
            case 36, 76: // return / numpad enter
                if isCommand || isOption || isControl {
                    // Let upstream key handlers (e.g. Cmd+Return for
                    // pane flip) get a shot at the event.
                    return false
                }
                if isShift {
                    // Shift+Enter inserts a literal newline.
                    textView.insertText("\n", replacementRange: textView.selectedRange())
                    return true
                }
                submitCurrentBuffer()
                return true

            case 53: // escape
                guard mods.isEmpty else { return false }
                clearBuffer()
                return true

            case 126: // up arrow
                guard !isShift, !isCommand, !isOption, !isControl else { return false }
                if cursorIsAtBufferStart() {
                    return applyHistory(.previous)
                }
                return false

            case 125: // down arrow
                guard !isShift, !isCommand, !isOption, !isControl else { return false }
                if cursorIsAtBufferEnd() {
                    return applyHistory(.next)
                }
                return false

            default:
                return false
            }
        }

        // MARK: Helpers

        private func submitCurrentBuffer() {
            guard let textView else { return }
            let value = textView.string
            // Empty submissions are dropped by the history layer, but we
            // still call onSubmit so the orchestrator can decide what to
            // do (e.g. send a bare newline to the PTY). Most callers
            // will just no-op on empty input.
            onSubmit(value)
            // Clear the AppKit buffer immediately so the user sees the
            // bar reset before SwiftUI re-renders. Use the undo manager
            // path so the user can't undo across a submit boundary.
            textView.applyExternalText("")
            textView.undoManager?.removeAllActions()
            // Push the cleared state to SwiftUI on the next tick to
            // avoid mutating bindings mid-event.
            let binding = textBinding
            DispatchQueue.main.async {
                if binding.wrappedValue != "" {
                    binding.wrappedValue = ""
                }
            }
            recomputeContentHeight()
        }

        private func clearBuffer() {
            guard let textView else { return }
            textView.applyExternalText("")
            textView.undoManager?.removeAllActions()
            let binding = textBinding
            DispatchQueue.main.async {
                if binding.wrappedValue != "" {
                    binding.wrappedValue = ""
                }
            }
            onCancel()
            recomputeContentHeight()
        }

        private func cursorIsAtBufferStart() -> Bool {
            guard let textView else { return false }
            let range = textView.selectedRange()
            // Collapsed selection at offset 0 — or empty buffer — counts
            // as "at the start". A non-empty selection means the user is
            // doing something else; let the arrow do its native thing.
            return range.length == 0 && range.location == 0
        }

        private func cursorIsAtBufferEnd() -> Bool {
            guard let textView else { return false }
            let range = textView.selectedRange()
            let length = (textView.string as NSString).length
            return range.length == 0 && range.location == length
        }

        private func applyHistory(_ direction: CommandBarView.HistoryDirection) -> Bool {
            guard let textView else { return false }
            guard let entry = onHistoryRequest(direction) else {
                // No further history in that direction — swallow the
                // event so the cursor doesn't move within the buffer.
                return true
            }
            isApplyingHistory = true
            textView.applyExternalText(entry)
            // Park the caret at the end so the user can immediately edit
            // the recalled command.
            let length = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: length, length: 0))
            isApplyingHistory = false

            let binding = textBinding
            DispatchQueue.main.async {
                if binding.wrappedValue != entry {
                    binding.wrappedValue = entry
                }
            }
            recomputeContentHeight()
            return true
        }

        // MARK: Height measurement

        func recomputeContentHeight() {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            // Force a layout pass so usedRect reflects the current text.
            layoutManager.ensureLayout(for: textContainer)
            let used = layoutManager.usedRect(for: textContainer)
            let measured = ceil(used.height) + CommandBarMetrics.textInsetY * 2
            let target = max(measured, CommandBarMetrics.singleLineHeight)
            let binding = contentHeightBinding
            // Only republish on a meaningful change to avoid thrash.
            if abs(binding.wrappedValue - target) > 0.5 {
                DispatchQueue.main.async {
                    binding.wrappedValue = target
                }
            }
        }
    }
}

/// `NSTextView` subclass that delegates key handling to our coordinator.
/// We override `keyDown` (rather than `performKeyEquivalent`) because
/// plain Return/Up/Down are not key equivalents — Cocoa routes them
/// through `keyDown` and then `doCommand(by:)`. Intercepting in
/// `keyDown` lets us short-circuit *before* Cocoa interprets Return as
/// `insertNewline:`.
fileprivate final class CommandInputTextView: NSTextView {
    weak var coordinator: CommandBarTextView.Coordinator?

    /// Visible-when-empty placeholder. We draw it ourselves because
    /// `NSTextView` doesn't expose a built-in placeholder API the way
    /// `NSTextField` does.
    var placeholderString: String?
    var placeholderColor: NSColor = .secondaryLabelColor

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        // Repaint to clear the placeholder if we just got focus.
        needsDisplay = true
        // Tell SwiftUI the focus state changed so the bar can light up.
        if result {
            coordinator?.reportFocus(true)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        needsDisplay = true
        if result {
            coordinator?.reportFocus(false)
        }
        return result
    }

    override func keyDown(with event: NSEvent) {
        if let coordinator, coordinator.handleKeyDown(event) {
            return
        }
        super.keyDown(with: event)
    }

    /// Notifies the coordinator after Cocoa applied a built-in command
    /// (e.g. arrow movement, delete, paste). Any user-initiated edit
    /// resets the history cursor so the next up-arrow starts fresh.
    override func didChangeText() {
        super.didChangeText()
        if let coordinator, !coordinator.isApplyingHistory {
            // We don't have a direct hook into "the user just edited
            // text", but didChangeText fires on every applied edit. The
            // history reset is encoded in the orchestrator's
            // `onHistoryRequest` closure (typically by calling
            // `CommandHistory.reset()` from `textDidChange` via the
            // SwiftUI binding observer). Nothing to do here in the view.
        }
    }

    /// Replaces the buffer programmatically (history walk, submit
    /// clear, external state sync) without firing the user-edit hooks
    /// that would otherwise reset the history cursor or pollute undo.
    func applyExternalText(_ value: String) {
        let storage = textStorage
        storage?.beginEditing()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: textColor ?? NSColor.textColor
        ]
        storage?.setAttributedString(NSAttributedString(string: value, attributes: attrs))
        storage?.endEditing()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty,
              let placeholderString,
              !placeholderString.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: placeholderColor
        ]
        let attributed = NSAttributedString(string: placeholderString, attributes: attrs)
        // Match the text container insets so the placeholder aligns
        // exactly with where typed characters will appear.
        let origin = NSPoint(
            x: textContainerInset.width,
            y: textContainerInset.height
        )
        attributed.draw(at: origin)
    }

    /// Disable the focus ring entirely; the bar's bottom accent underline
    /// is the only visual focus affordance we want.
    override var focusRingType: NSFocusRingType {
        get { .none }
        set { _ = newValue }
    }
}

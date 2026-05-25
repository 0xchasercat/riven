import AppKit
import RivenCore
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
/// they prefer (typically `CommandHistory` from RivenCore).
struct CommandBarView: View {
    enum HistoryDirection { case previous, next }

    /// Which key submits the buffer and which one inserts a newline.
    /// User-toggleable preference, default `.enterSubmits` (closest to
    /// a real shell prompt — Enter runs the command, Cmd+Enter inserts
    /// a literal newline for multi-line composition).
    enum SubmitMode: Equatable {
        /// Enter inserts "\n", Cmd+Enter submits.
        case enterIsNewline
        /// Enter submits, Cmd+Enter inserts "\n". Closer to a real
        /// shell prompt.
        case enterSubmits
    }

    private let theme: ThemeSpec
    private let submitMode: SubmitMode
    private let onSubmit: (String) -> Void
    /// Called when the user presses up / down arrow at a position
    /// that should walk command history. Receives the direction AND
    /// the user's current buffer (so a later .next can restore the
    /// in-progress draft). Returns the new text to display, or nil
    /// to leave the buffer untouched (typically: already at the
    /// oldest / newest entry).
    private let onHistoryRequest: (HistoryDirection, String) -> String?
    /// Returns the most recent command from history whose text
    /// starts with the given prefix, or nil. Drives the zsh-
    /// autosuggestions-style ghost text. Default no-suggestion
    /// closure keeps the bar usable in tests / preview without
    /// wiring history in.
    private let onSuggest: (String) -> String?

    @State private var text: String = ""
    /// Measured intrinsic content height of the text view, in points.
    /// Driven from the AppKit layer via the coordinator and clamped into
    /// the [singleLineHeight, maxHeight] range below before we use it as
    /// the SwiftUI frame height. Keeping the raw value in `@State` lets
    /// transitions be smooth — we only animate the clamped output.
    @State private var contentHeight: CGFloat = CommandBarMetrics.singleLineInputHeight
    /// `true` when the embedded `NSTextView` is the window's first
    /// responder. Driven from the AppKit layer; powers the focus underline
    /// and the bolder prompt glyph.
    @State private var isFocused: Bool = false

    init(
        theme: ThemeSpec,
        submitMode: SubmitMode = .enterSubmits,
        onSubmit: @escaping (String) -> Void,
        onHistoryRequest: @escaping (HistoryDirection, String) -> String? = { _, _ in nil },
        onSuggest: @escaping (String) -> String? = { _ in nil }
    ) {
        self.theme = theme
        self.submitMode = submitMode
        self.onSubmit = onSubmit
        self.onHistoryRequest = onHistoryRequest
        self.onSuggest = onSuggest
    }

    var body: some View {
        // Clamped input height — what we actually allocate to the
        // NSTextView. Includes the text container's own vertical insets,
        // so a "single line" already has breathing room top and bottom.
        let inputHeight = clampHeight(contentHeight)
        // The bar's full height tracks the input directly; padding lives
        // inside the text container (textInsetY) rather than on the
        // HStack, so the prompt + submit glyphs sit perfectly centered on
        // the same baseline as a single line of typed text.
        let barHeight = inputHeight
        let hasText = !text.isEmpty

        HStack(alignment: .center, spacing: RivenSpacing.s) {
            promptGlyph

            CommandBarTextView(
                theme: theme,
                submitMode: submitMode,
                text: $text,
                contentHeight: $contentHeight,
                isFocused: $isFocused,
                onSubmit: handleSubmit,
                onHistoryRequest: handleHistoryRequest,
                onSuggest: onSuggest,
                onCancel: handleCancel
            )
            .frame(height: inputHeight)

            submitAffordance(hasText: hasText)
        }
        .padding(.leading, RivenSpacing.s)
        .padding(.trailing, RivenSpacing.s)
        .frame(height: barHeight)
        .background(
            // One notch above the panel so the bar visually pops as the
            // input zone instead of melting into the terminal grid.
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
            // (clear) and focused (accent) states. No bottom border in
            // the resting state — the bar sits flush against the pane
            // bottom so an idle line would only add visual noise.
            Rectangle()
                .fill(Color(hex: theme.chrome.accent.hex))
                .frame(height: 1)
                .opacity(isFocused ? 1 : 0)
                .animation(RivenMotion.hover, value: isFocused)
        }
        .animation(.easeOut(duration: 0.12), value: inputHeight)
    }

    // MARK: - Decorations

    /// Prompt glyph on the left. Subtly bolder when the input is focused
    /// so the eye follows the bar's active state without screaming.
    private var promptGlyph: some View {
        // U+276F (HEAVY RIGHT-POINTING ANGLE QUOTATION MARK ORNAMENT) is
        // the canonical chevron glyph. SF Mono ships it on every modern
        // macOS, so this renders consistently across themes.
        Text("\u{276F}")
            .font(RivenType.mono(RivenType.body, weight: isFocused ? .bold : .semibold))
            .foregroundStyle(Color(hex: theme.chrome.accent.hex))
            .frame(width: CommandBarMetrics.promptWidth, alignment: .center)
            .animation(RivenMotion.hover, value: isFocused)
            .accessibilityHidden(true)
    }

    /// Return-key affordance on the right edge. Dim by default; when
    /// there's text in the buffer it brightens to accent — a visual
    /// confirmation that pressing Enter will do something.
    private func submitAffordance(hasText: Bool) -> some View {
        Text("\u{21A9}")
            .font(RivenType.mono(RivenType.caption))
            .foregroundStyle(
                Color(hex: hasText ? theme.chrome.accent.hex : theme.chrome.tertiaryText.hex)
            )
            .frame(width: CommandBarMetrics.submitWidth, alignment: .center)
            .animation(RivenMotion.hover, value: hasText)
            .accessibilityLabel(hasText ? "Run command" : "Return")
    }

    private func clampHeight(_ raw: CGFloat) -> CGFloat {
        let minH = CommandBarMetrics.singleLineInputHeight
        let maxH = CommandBarMetrics.maxInputHeight
        if raw.isNaN || raw <= 0 { return minH }
        return min(max(raw, minH), maxH)
    }

    // MARK: - Callbacks from the AppKit text view

    private func handleSubmit(_ value: String) {
        // Snapshot then clear so the SwiftUI text reset doesn't race the
        // delegate that's still mid-event.
        let payload = value
        text = ""
        contentHeight = CommandBarMetrics.singleLineInputHeight
        onSubmit(payload)
    }

    private func handleHistoryRequest(_ direction: HistoryDirection, currentBuffer: String) -> String? {
        onHistoryRequest(direction, currentBuffer)
    }

    private func handleCancel() {
        text = ""
        contentHeight = CommandBarMetrics.singleLineInputHeight
    }
}

/// Layout constants. Centralized so the AppKit text view, the SwiftUI
/// frame, and the prompt glyph stay aligned.
///
/// All sizes derive from `RivenSpacing` / `RivenType` tokens so the bar
/// stays in lockstep with the rest of the design system if those scales
/// shift. The only "magic" left is the per-line growth estimate, which
/// is intentionally a measurement of the SF Mono cap height at the body
/// type size — there is no token for that.
private enum CommandBarMetrics {
    /// Horizontal inset inside the scroll view. The HStack already pads
    /// the bar; we don't want the text to drift further off the prompt.
    static let textInsetX: CGFloat = 0
    /// Vertical inset inside the scroll view. Bumped to `xxl` so the bar
    /// reads as the workspace's primary input surface — Warp's bottom
    /// block has a similar vertical weight. At ~24 pt above + below a
    /// single line, the bar is impossible to miss as the next thing the
    /// user should type into.
    static let textInsetY: CGFloat = RivenSpacing.xxl

    /// Per-line growth used for the cap calculation. SF Mono at the bar's
    /// font size measures ~22 pt of advance per line.
    static let lineHeight: CGFloat = 22

    /// Resting input height at a single line of text. ~70 pt: line
    /// height plus ~48 pt of vertical inset. Aesthetically substantial
    /// and a generous click target — a user can flick the cursor down
    /// without aiming.
    static let singleLineInputHeight: CGFloat = lineHeight + textInsetY * 2

    /// Cap so the bar can't swallow the terminal grid, but generous —
    /// ~8 wrapped lines of multi-line composition before scrolling.
    static let maxInputHeight: CGFloat = 280

    /// Font size for the input + placeholder. One notch above subhead
    /// (14) so the surface reads as substantial; matches the bumped
    /// vertical padding above.
    static let fontSize: CGFloat = 15

    /// Width reserved for the leading prompt glyph. Bumped slightly so
    /// the chevron breathes at the new font size.
    static let promptWidth: CGFloat = 18

    /// Width reserved for the trailing return-key affordance, including
    /// its right-side breathing room.
    static let submitWidth: CGFloat = 30

    /// Horizontal padding inside the bar (between bar edge and prompt /
    /// submit affordance). Spacious.
    static let horizontalPadding: CGFloat = RivenSpacing.l
}

// MARK: - AppKit bridge

/// Thin `NSViewRepresentable` wrapping an `NSTextView` inside an
/// `NSScrollView`. The coordinator owns key interception (Enter,
/// Shift+Enter, Up/Down, Escape) and reports content height + focus
/// changes back to SwiftUI via bindings so the bar can grow, shrink,
/// and light up with the buffer.
private struct CommandBarTextView: NSViewRepresentable {
    let theme: ThemeSpec
    let submitMode: CommandBarView.SubmitMode
    @Binding var text: String
    @Binding var contentHeight: CGFloat
    @Binding var isFocused: Bool
    let onSubmit: (String) -> Void
    let onHistoryRequest: (CommandBarView.HistoryDirection, String) -> String?
    let onSuggest: (String) -> String?
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            submitMode: submitMode,
            text: $text,
            contentHeight: $contentHeight,
            isFocused: $isFocused,
            theme: theme,
            onSubmit: onSubmit,
            onHistoryRequest: onHistoryRequest,
            onSuggest: onSuggest,
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
        // `selectionBg` carries a per-theme translucent accent (Paper
        // ships an ink-on-cream wash; dark themes ship low-alpha
        // accent tints). Cleaner than the prior accent-at-0.28 hack
        // and matches the editor's selection fill so the two inputs
        // read as siblings.
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(hex: theme.chrome.selectionBg.hex)
        ]
        textView.placeholderString = Self.placeholderText(for: submitMode)
        textView.placeholderFont = monospacedFont
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
            submitMode: submitMode,
            theme: theme,
            onSubmit: onSubmit,
            onHistoryRequest: onHistoryRequest,
            onSuggest: onSuggest,
            onCancel: onCancel
        )
        guard let textView = scrollView.documentView as? CommandInputTextView else { return }
        textView.font = monospacedFont
        textView.textColor = NSColor(hex: theme.chrome.text.hex)
        textView.insertionPointColor = NSColor(hex: theme.chrome.accent.hex)
        textView.placeholderColor = NSColor(hex: theme.chrome.tertiaryText.hex)
        textView.placeholderFont = monospacedFont
        textView.placeholderString = Self.placeholderText(for: submitMode)
        // `selectionBg` carries a per-theme translucent accent (Paper
        // ships an ink-on-cream wash; dark themes ship low-alpha
        // accent tints). Cleaner than the prior accent-at-0.28 hack
        // and matches the editor's selection fill so the two inputs
        // read as siblings.
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(hex: theme.chrome.selectionBg.hex)
        ]

        // Sync the AppKit buffer with the SwiftUI state when SwiftUI is
        // the source of truth (e.g. after a submit clears `text`). Avoid
        // touching the view if it already matches — otherwise we lose
        // selection and undo each render pass.
        //
        // Compare against the TYPED-only string, not `textView.string`.
        // When autosuggestion ghost text is present, `textView.string`
        // is "typed + ghost" while the binding `text` is just "typed"
        // (textDidChange pushes only the typed portion). Comparing the
        // full string would mismatch on every keystroke and call
        // applyExternalText(text) — which wipes the ghost we just
        // inserted, making the suggestion flash for one frame and
        // vanish before the user can press → to accept. Comparing the
        // typed portion means a genuine external change (submit clear,
        // history recall) still overwrites, but the ghost survives a
        // routine binding sync.
        if context.coordinator.currentTypedString() != text {
            textView.applyExternalText(text)
            context.coordinator.recomputeContentHeight()
        }
    }

    /// Placeholder hint that mirrors the live submit mode so a user can
    /// see at a glance which key actually submits. Switches between
    /// "⏎ newline, ⌘⏎ run" (default) and "⏎ run, ⌘⏎ newline" (toggle on).
    static func placeholderText(for mode: CommandBarView.SubmitMode) -> String {
        switch mode {
        case .enterIsNewline:
            return "Type a command — \u{23CE} newline, \u{2318}\u{23CE} run, \u{2191}\u{2193} history, esc clear"
        case .enterSubmits:
            return "Type a command — \u{23CE} run, \u{2318}\u{23CE} newline, \u{2191}\u{2193} history, esc clear"
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
        private var submitMode: CommandBarView.SubmitMode
        private let textBinding: Binding<String>
        private let contentHeightBinding: Binding<CGFloat>
        private let isFocusedBinding: Binding<Bool>
        private var theme: ThemeSpec
        private var onSubmit: (String) -> Void
        private var onHistoryRequest: (CommandBarView.HistoryDirection, String) -> String?
        private var onSuggest: (String) -> String?
        private var onCancel: () -> Void

        weak var textView: CommandInputTextView?
        weak var scrollView: NSScrollView?

        /// Suppresses the "any user edit invalidates the history cursor"
        /// hook while we're programmatically replacing the buffer with a
        /// history entry. Without this, walking history would
        /// immediately reset the cursor after the first up-arrow.
        var isApplyingHistory: Bool = false
        /// Recursion guard for ghost-text refresh. textDidChange
        /// triggers a storage mutation (insert / remove ghost
        /// runs) which fires textDidChange again — without this
        /// we'd loop forever.
        private var isAdjustingGhostText: Bool = false

        /// Marker attribute that flags a range of the text storage
        /// as ghost suggestion text. The bar's buffer-read paths
        /// (submit, history, focus check) strip these ranges
        /// before doing anything, so the SwiftUI binding only ever
        /// sees the user's typed prefix.
        static let ghostKey = NSAttributedString.Key("riven.ghostText")

        init(
            submitMode: CommandBarView.SubmitMode,
            text: Binding<String>,
            contentHeight: Binding<CGFloat>,
            isFocused: Binding<Bool>,
            theme: ThemeSpec,
            onSubmit: @escaping (String) -> Void,
            onHistoryRequest: @escaping (CommandBarView.HistoryDirection, String) -> String?,
            onSuggest: @escaping (String) -> String?,
            onCancel: @escaping () -> Void
        ) {
            self.submitMode = submitMode
            self.textBinding = text
            self.contentHeightBinding = contentHeight
            self.isFocusedBinding = isFocused
            self.theme = theme
            self.onSubmit = onSubmit
            self.onHistoryRequest = onHistoryRequest
            self.onSuggest = onSuggest
            self.onCancel = onCancel
        }

        func attach(textView: CommandInputTextView, scrollView: NSScrollView) {
            self.textView = textView
            self.scrollView = scrollView
        }

        func update(
            submitMode: CommandBarView.SubmitMode,
            theme: ThemeSpec,
            onSubmit: @escaping (String) -> Void,
            onHistoryRequest: @escaping (CommandBarView.HistoryDirection, String) -> String?,
            onSuggest: @escaping (String) -> String?,
            onCancel: @escaping () -> Void
        ) {
            self.submitMode = submitMode
            self.theme = theme
            self.onSubmit = onSubmit
            self.onHistoryRequest = onHistoryRequest
            self.onSuggest = onSuggest
            self.onCancel = onCancel
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            // Guard against the recursive call triggered by our own
            // ghost-text storage mutation a few lines below.
            if isAdjustingGhostText {
                recomputeContentHeight()
                return
            }

            // Strip any in-storage ghost text + recompute a new one
            // based on the (now clean) typed prefix.
            isAdjustingGhostText = true
            stripGhostText()
            let typed = textView.string
            if !isApplyingHistory {
                refreshGhostText(typed: typed)
            }
            isAdjustingGhostText = false

            // Push the user's typed text (without the ghost suffix)
            // to SwiftUI on the next runloop tick; mutating bindings
            // mid-delegate can confuse SwiftUI's update cycle.
            let binding = textBinding
            DispatchQueue.main.async {
                if binding.wrappedValue != typed {
                    binding.wrappedValue = typed
                }
            }
            recomputeContentHeight()
        }

        // MARK: Ghost text

        /// Remove any storage ranges flagged with `ghostKey` so the
        /// The user-typed portion of the buffer, excluding any
        /// trailing autosuggestion ghost text. Ghost text is always a
        /// contiguous trailing run flagged with `ghostKey`, so the
        /// typed portion is everything before the first ghost-flagged
        /// character. Used by `updateNSView` to decide whether the
        /// SwiftUI binding genuinely diverged from what the user typed
        /// (vs. just differing by the ghost suffix we inserted).
        fileprivate func currentTypedString() -> String {
            guard let textView, let storage = textView.textStorage else {
                return textView?.string ?? ""
            }
            var ghostStart = storage.length
            storage.enumerateAttribute(
                Coordinator.ghostKey,
                in: NSRange(location: 0, length: storage.length),
                options: []
            ) { value, range, stop in
                if value != nil {
                    ghostStart = range.location
                    stop.pointee = true
                }
            }
            return (storage.string as NSString).substring(to: ghostStart)
        }

        /// visible text is exactly what the user has typed. Safe to
        /// call when there's no ghost text — it's a no-op.
        fileprivate func stripGhostText() {
            guard let textView,
                  let storage = textView.textStorage else { return }
            // Walk ranges back-to-front so removing earlier ones
            // doesn't shift the indices of the later ones.
            var rangesToDelete: [NSRange] = []
            storage.enumerateAttribute(
                Coordinator.ghostKey,
                in: NSRange(location: 0, length: storage.length),
                options: []
            ) { value, range, _ in
                if value != nil { rangesToDelete.append(range) }
            }
            guard !rangesToDelete.isEmpty else { return }
            storage.beginEditing()
            for range in rangesToDelete.reversed() {
                storage.deleteCharacters(in: range)
            }
            storage.endEditing()
        }

        /// Ask the orchestrator for a suggestion matching `typed`,
        /// and insert the unmatched suffix at the end of the
        /// storage with a dim color + the ghost marker attribute.
        /// The insertion cursor stays where it was (typically the
        /// end of `typed`) so the user keeps typing into clean
        /// territory, with the suggestion floating dimmed beside
        /// the caret.
        fileprivate func refreshGhostText(typed: String) {
            guard let textView,
                  let storage = textView.textStorage,
                  !typed.isEmpty else { return }
            // Only suggest when the cursor is at the end of the
            // typed text with no selection — mid-buffer editing is
            // a hard UX problem and zsh-autosuggestions doesn't
            // handle it either.
            let selection = textView.selectedRange()
            let typedLen = (typed as NSString).length
            guard selection.length == 0, selection.location == typedLen else { return }
            guard let suggestion = onSuggest(typed),
                  suggestion.hasPrefix(typed),
                  suggestion.count > typed.count else { return }
            let suffix = String(suggestion.dropFirst(typed.count))
            let ghost = NSAttributedString(
                string: suffix,
                attributes: [
                    .font: textView.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                    .foregroundColor: NSColor(hex: theme.chrome.tertiaryText.hex),
                    Coordinator.ghostKey: true,
                ]
            )
            storage.beginEditing()
            storage.append(ghost)
            storage.endEditing()
            // The insertion point shouldn't have moved (textStorage.append
            // tacks bytes onto the end without disturbing the cursor),
            // but be defensive: reset it to the typed-end boundary so
            // the user types into clean territory, not into the ghost.
            textView.setSelectedRange(NSRange(location: typedLen, length: 0))
        }

        /// True when there's a ghost-text suffix in storage and the
        /// cursor is parked at the typed/ghost boundary — i.e. the
        /// user can accept by pressing Right Arrow.
        fileprivate func hasAcceptableGhost() -> Bool {
            guard let textView,
                  let storage = textView.textStorage else { return false }
            let typed = textView.string
            let typedNS = typed as NSString
            // Ghost text is always at the end of storage. If the
            // string length matches typed length, there's no ghost.
            if storage.length == typedNS.length { return false }
            // Cursor must be at the typed end (no selection).
            let sel = textView.selectedRange()
            return sel.length == 0 && sel.location == typedNS.length
        }

        /// Accept the current ghost text: strip the `ghostKey`
        /// attribute from the trailing range (turning it into real
        /// text), re-tint that range as standard text, move the
        /// caret to the end, and push the new full text to the
        /// SwiftUI binding. Returns true if anything was accepted.
        fileprivate func acceptGhostText() -> Bool {
            guard let textView,
                  let storage = textView.textStorage else { return false }
            let typed = textView.string
            let typedLen = (typed as NSString).length
            guard storage.length > typedLen else { return false }
            isAdjustingGhostText = true
            let ghostRange = NSRange(location: typedLen, length: storage.length - typedLen)
            storage.beginEditing()
            storage.removeAttribute(Coordinator.ghostKey, range: ghostRange)
            storage.addAttribute(
                .foregroundColor,
                value: NSColor(hex: theme.chrome.text.hex),
                range: ghostRange
            )
            storage.endEditing()
            isAdjustingGhostText = false
            textView.setSelectedRange(NSRange(location: storage.length, length: 0))
            let full = textView.string
            let binding = textBinding
            DispatchQueue.main.async {
                if binding.wrappedValue != full {
                    binding.wrappedValue = full
                }
            }
            recomputeContentHeight()
            return true
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
                if isOption || isControl {
                    // Let upstream key handlers (e.g. Ctrl+Return for
                    // pane flip) get a shot at the event.
                    return false
                }
                if isShift {
                    // Shift+Enter always inserts a literal newline.
                    // Standard chat convention — works the same way
                    // regardless of submitMode.
                    textView.insertText("\n", replacementRange: textView.selectedRange())
                    return true
                }
                // Decide submit vs newline from the active mode:
                //   .enterSubmits (default): Enter = submit,
                //     Cmd+Enter = newline. Matches a real shell prompt.
                //   .enterIsNewline:         Enter = newline,
                //     Cmd+Enter = submit. Slack / Discord / Claude.
                switch (submitMode, isCommand) {
                case (.enterIsNewline, false), (.enterSubmits, true):
                    textView.insertText("\n", replacementRange: textView.selectedRange())
                case (.enterIsNewline, true), (.enterSubmits, false):
                    submitCurrentBuffer()
                }
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

            case 124: // right arrow
                // Accept the ghost-text autosuggestion when the
                // caret is parked at the typed/ghost boundary.
                // Bare Right Arrow only — modifier combos fall
                // through to native NSTextView word/line nav.
                guard !isShift, !isCommand, !isOption, !isControl else { return false }
                if hasAcceptableGhost() {
                    _ = acceptGhostText()
                    return true
                }
                return false

            default:
                return false
            }
        }

        // MARK: Helpers

        private func submitCurrentBuffer() {
            guard let textView else { return }
            // Strip ghost text before reading so submitting "git st"
            // with a "atus" ghost doesn't send "git status" — only
            // the user's explicit acceptance (Right Arrow) is
            // allowed to promote ghost into real input.
            isAdjustingGhostText = true
            stripGhostText()
            isAdjustingGhostText = false
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
            guard let entry = onHistoryRequest(direction, textView.string) else {
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
            let target = max(measured, CommandBarMetrics.singleLineInputHeight)
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
/// Internal (was fileprivate) so the global Tab-snap monitor in
/// `RivenApp` can distinguish "first responder is the command bar"
/// from "first responder is anywhere else" — the former lets Tab
/// insert a literal `\t`, the latter snaps focus into the bar.
final class CommandInputTextView: NSTextView {
    // `fileprivate` because `CommandBarTextView.Coordinator` is itself
    // fileprivate (its containing struct is `private`). The class's
    // own visibility is internal so the RivenApp Tab-snap monitor can
    // `is`-check against it; the coordinator pointer stays scoped to
    // this file.
    fileprivate weak var coordinator: CommandBarTextView.Coordinator?

    /// Visible-when-empty placeholder. We draw it ourselves because
    /// `NSTextView` doesn't expose a built-in placeholder API the way
    /// `NSTextField` does.
    var placeholderString: String?
    var placeholderColor: NSColor = .secondaryLabelColor
    /// Font used to draw the placeholder. Defaults to the text view's
    /// own font, but we let callers override so we can guarantee the
    /// placeholder uses the same monospaced face as typed input even
    /// before any text has been set.
    var placeholderFont: NSFont?

    /// Token for the `.rivenFocusCommandBar` notification observer so
    /// `deinit` can remove it. Stored as `Any?` because that's what
    /// `NotificationCenter.addObserver(forName:...)` hands back.
    /// `nonisolated(unsafe)` so the nonisolated deinit can read it.
    private nonisolated(unsafe) var focusObserver: Any?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Riven's focus model bounces any terminal-pane click to the
        // command bar. Listen for `.rivenFocusCommandBar` while attached
        // to a window — when fired, grab first-responder unless the
        // event source was ourselves (avoid recursive loops if a future
        // path ever posts from inside the bar).
        if let focusObserver {
            NotificationCenter.default.removeObserver(focusObserver)
            self.focusObserver = nil
        }
        guard window != nil else { return }
        focusObserver = NotificationCenter.default.addObserver(
            forName: .rivenFocusCommandBar,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.grabFocusIfAppropriate()
            }
        }
        // Also auto-grab on first mount. The tab-area subtree is `.id`'d
        // by tab + brokerEpoch, so a fresh CommandInputTextView lands
        // every time the user switches tabs — making us first-responder
        // on attach means the user can type immediately without
        // clicking.
        DispatchQueue.main.async { [weak self] in
            self?.grabFocusIfAppropriate()
        }
    }

    /// Take first-responder, but ONLY if no other text-input view is
    /// already focused. Without this guard, every SwiftUI re-render
    /// that detaches + reattaches the workspace subtree (which
    /// happens on every keystroke into the toolbar's editable path
    /// field) would trigger `viewDidMoveToWindow` on a fresh
    /// CommandInputTextView and yank focus back here — making the
    /// path field accept only one keystroke before losing focus.
    /// The `is NSText` check catches both the path field (which uses
    /// NSTextField's shared field editor, an NSText) AND the editor
    /// pane's STTextView (also an NSText subclass); both are
    /// surfaces the user deliberately chose to type into, so we
    /// respect them.
    private func grabFocusIfAppropriate() {
        guard let window, window.isKeyWindow else { return }
        if window.firstResponder is NSText {
            // Either us already, the toolbar path field's editor, or
            // the editor pane — in all three cases the right behavior
            // is "don't change focus".
            return
        }
        window.makeFirstResponder(self)
    }

    deinit {
        if let focusObserver {
            NotificationCenter.default.removeObserver(focusObserver)
        }
    }

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
            .font: font ?? NSFont.monospacedSystemFont(ofSize: CommandBarMetrics.fontSize, weight: .regular),
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
            .font: placeholderFont
                ?? font
                ?? NSFont.monospacedSystemFont(ofSize: CommandBarMetrics.fontSize, weight: .regular),
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

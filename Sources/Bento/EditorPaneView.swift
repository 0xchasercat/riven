import AppKit
import BentoCore
import STTextView
import SwiftUI

/// SwiftUI shell for the editor pane. Thin wrapper around an STTextView
/// that loads the file currently associated with `paneID` in `fileMap`,
/// reports dirty state back through the optional `isDirty` binding, and
/// writes the buffer to disk on Cmd+S.
///
/// All non-AppKit state transitions live in `EditorBuffer`. Per-pane
/// open-file state lives in `PaneFileMap` so each editor leaf can hold
/// its own URL — earlier alpha builds shared one binding across all
/// panes, which made opening a file mirror it across the entire grid.
///
/// Save failures surface as a small banner overlaid on top of the text
/// view. The banner auto-dismisses after 6 seconds, on user dismiss, or
/// when the next save succeeds.
struct EditorPaneView: View {
    let theme: ThemeSpec
    let paneID: PaneID
    /// Tab-surface identity. When non-nil, the underlying coordinator
    /// listens for `.bentoSaveSurface` / `.bentoUndoSurface`
    /// notifications carrying this id and dispatches the save / undo
    /// internally. Legacy callers (PaneGridView's `.editor` leaf in
    /// the old single-tab-per-pane model) pass nil and rely solely on
    /// Cmd+S via the responder chain.
    let surfaceID: SurfaceID?
    @ObservedObject var fileMap: PaneFileMap
    @Binding var isDirty: Bool

    @State private var saveError: String?
    @State private var saveErrorToken: Int = 0

    init(
        theme: ThemeSpec,
        paneID: PaneID,
        surfaceID: SurfaceID? = nil,
        fileMap: PaneFileMap,
        isDirty: Binding<Bool> = .constant(false)
    ) {
        self.theme = theme
        self.paneID = paneID
        self.surfaceID = surfaceID
        self.fileMap = fileMap
        self._isDirty = isDirty
    }

    var body: some View {
        STTextEditorRepresentable(
            theme: theme,
            openFile: fileMap.binding(for: paneID),
            isDirty: $isDirty,
            surfaceID: surfaceID,
            onSaveResult: handleSaveResult
        )
        .overlay(alignment: .top) {
            if let saveError {
                SaveErrorBanner(
                    message: saveError,
                    theme: theme,
                    onDismiss: dismissSaveError
                )
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: saveErrorToken) {
                    // Auto-dismiss after 6 seconds. The token is bumped on
                    // every new error so a fresh failure restarts the timer
                    // rather than inheriting the previous one's countdown.
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    if self.saveErrorToken == saveErrorToken {
                        dismissSaveError()
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: saveError)
    }

    private func handleSaveResult(_ result: Result<Void, Error>) {
        switch result {
        case .success:
            // Successful save clears any lingering banner.
            if saveError != nil {
                saveError = nil
            }
        case .failure(let error):
            saveError = "Could not save: \(error.localizedDescription)"
            saveErrorToken &+= 1
        }
    }

    private func dismissSaveError() {
        saveError = nil
    }
}

/// Small banner shown at the top of an editor pane when a save fails.
/// Themed via `theme.chrome` so it matches the surrounding chrome and
/// doesn't introduce a new top-level overlay system.
private struct SaveErrorBanner: View {
    let message: String
    let theme: ThemeSpec
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Rectangle()
                .fill(Color(hex: theme.chrome.activeBorder.hex))
                .frame(width: 2)
                .frame(maxHeight: .infinity)

            Text(message)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundColor(Color(hex: theme.chrome.text.hex))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDismiss) {
                Text("Dismiss")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(hex: theme.chrome.text.hex))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: BentoRadius.small)
                            .stroke(Color(hex: theme.chrome.activeBorder.hex), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: theme.geometry.paneRadius)
                .fill(Color(hex: theme.chrome.panel.hex))
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.geometry.paneRadius)
                .stroke(Color(hex: theme.chrome.activeBorder.hex).opacity(0.6), lineWidth: 1)
        )
        // BentoElevation.card mirrors the card shadow used by other
        // raised surfaces (overlay rows, palette rows) so the banner's
        // depth matches the rest of the modal chrome.
        .shadow(
            color: BentoElevation.card.color,
            radius: BentoElevation.card.radius,
            x: BentoElevation.card.x,
            y: BentoElevation.card.y
        )
    }
}

/// Bridges an `STTextView` (wrapped in an `NSScrollView`) into SwiftUI.
/// The `Coordinator` owns the `EditorBuffer` model, acts as the
/// `STTextViewDelegate`, and intercepts Cmd+S via a `keyDown` monitor on
/// the document view.
struct STTextEditorRepresentable: NSViewRepresentable {
    let theme: ThemeSpec
    @Binding var openFile: URL?
    @Binding var isDirty: Bool
    let surfaceID: SurfaceID?
    let onSaveResult: (Result<Void, Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isDirty: $isDirty,
            onSaveResult: onSaveResult,
            surfaceID: surfaceID
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = EditorChrome.editorBackground(theme)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        // Use manual insets so the editor body breathes vertically and the
        // STTextView gutter (which only auto-offsets when this flag is on)
        // stays flush with the text rather than floating mid-scroller.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(
            top: EditorChrome.verticalPadding,
            left: 0,
            bottom: EditorChrome.verticalPadding,
            right: 0
        )
        scrollView.scrollerInsets = NSEdgeInsets(
            top: -EditorChrome.verticalPadding,
            left: 0,
            bottom: -EditorChrome.verticalPadding,
            right: 0
        )

        let textView = EditorTextView()
        textView.font = EditorChrome.editorFont
        textView.textColor = NSColor(hex: theme.chrome.text.hex)
        textView.insertionPointColor = NSColor(hex: theme.chrome.activeBorder.hex)
        textView.backgroundColor = EditorChrome.editorBackground(theme)
        textView.isEditable = true
        textView.isSelectable = true
        // Horizontal breathing room inside the text container so glyphs
        // don't crowd the gutter or the right edge.
        textView.textContainer.lineFragmentPadding = EditorChrome.horizontalPadding
        textView.highlightSelectedLine = true
        textView.selectedLineHighlightColor = EditorChrome.currentLineColor(theme)
        // (STTextView exposes its own selection highlight via its
        // internal NSTextLayoutManager — there's no public
        // `selectedTextAttributes` setter; the system selection
        // colour ships from the appearance, which we pin via
        // VibrancyBackground's `appearance` knob so Paper's selection
        // reads as a warm tint rather than the dark-mode blue.)
        textView.showsLineNumbers = true
        EditorChrome.styleGutter(textView.gutterView, theme: theme)
        textView.textDelegate = context.coordinator
        textView.onSaveRequested = { [weak coordinator = context.coordinator] in
            coordinator?.save()
        }
        scrollView.documentView = textView

        context.coordinator.attach(textView: textView)
        // Prime the view with whatever URL was set before the view was
        // mounted (typical first render path).
        context.coordinator.reconcile(targetURL: openFile)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Refresh the save-result callback so SwiftUI state captures stay
        // current across view re-evaluations.
        context.coordinator.updateSaveResultHandler(onSaveResult)

        scrollView.backgroundColor = EditorChrome.editorBackground(theme)
        guard let textView = scrollView.documentView as? EditorTextView else { return }
        textView.font = EditorChrome.editorFont
        textView.textColor = NSColor(hex: theme.chrome.text.hex)
        textView.insertionPointColor = NSColor(hex: theme.chrome.activeBorder.hex)
        textView.backgroundColor = EditorChrome.editorBackground(theme)
        textView.textContainer.lineFragmentPadding = EditorChrome.horizontalPadding
        textView.highlightSelectedLine = true
        textView.selectedLineHighlightColor = EditorChrome.currentLineColor(theme)
        // Idempotent: setter no-ops when already true, otherwise creates
        // the gutter so theme switches mid-session still pick up styling.
        textView.showsLineNumbers = true
        EditorChrome.styleGutter(textView.gutterView, theme: theme)

        // Reconcile URL transitions. Re-asserting the same URL preserves
        // any unsaved edits (alpha policy); switching to a different URL
        // discards the dirty buffer in favor of fresh disk contents.
        context.coordinator.reconcile(targetURL: openFile)
    }

    @MainActor
    final class Coordinator: NSObject, @MainActor STTextViewDelegate {
        private var buffer = EditorBuffer()
        private weak var textView: EditorTextView?
        private var isApplyingProgrammaticChange = false
        private let isDirtyBinding: Binding<Bool>
        private var onSaveResult: (Result<Void, Error>) -> Void
        private var loadFailureMessage: String?
        /// When non-nil, this coordinator listens for
        /// `.bentoSaveSurface` / `.bentoUndoSurface` notifications
        /// whose payload matches and dispatches the corresponding
        /// action. Lets the editor toolbar's Save / Undo buttons + the
        /// controller's close-prompt fire save without holding a
        /// reference to the coordinator.
        private let surfaceID: SurfaceID?
        /// `nonisolated(unsafe)` so the nonisolated deinit can remove
        /// them without a MainActor hop. NotificationCenter's
        /// `removeObserver` is documented to be thread-safe.
        private nonisolated(unsafe) var saveObserver: Any?
        private nonisolated(unsafe) var undoObserver: Any?

        init(
            isDirty: Binding<Bool>,
            onSaveResult: @escaping (Result<Void, Error>) -> Void,
            surfaceID: SurfaceID? = nil
        ) {
            self.isDirtyBinding = isDirty
            self.onSaveResult = onSaveResult
            self.surfaceID = surfaceID
            super.init()
            attachSurfaceObserversIfNeeded()
        }

        deinit {
            if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
            if let undoObserver { NotificationCenter.default.removeObserver(undoObserver) }
        }

        private func attachSurfaceObserversIfNeeded() {
            guard let surfaceID else { return }
            saveObserver = NotificationCenter.default.addObserver(
                forName: .bentoSaveSurface,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self,
                      let id = note.object as? SurfaceID,
                      id == surfaceID else { return }
                MainActor.assumeIsolated {
                    self.save()
                }
            }
            undoObserver = NotificationCenter.default.addObserver(
                forName: .bentoUndoSurface,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self,
                      let id = note.object as? SurfaceID,
                      id == surfaceID else { return }
                MainActor.assumeIsolated {
                    self.textView?.undoManager?.undo()
                }
            }
        }

        func attach(textView: EditorTextView) {
            self.textView = textView
        }

        func updateSaveResultHandler(_ handler: @escaping (Result<Void, Error>) -> Void) {
            self.onSaveResult = handler
        }

        // MARK: URL reconciliation

        func reconcile(targetURL: URL?) {
            let outcome = buffer.reconcile(targetURL: targetURL)
            switch outcome {
            case .noChange:
                // Preserve in-memory buffer (including unsaved edits).
                break
            case .needsLoad(let url):
                loadFromDisk(url: url)
            case .clearedToScratch:
                loadFailureMessage = nil
                applyTextToView("")
            }
            publishDirty()
        }

        private func loadFromDisk(url: URL) {
            do {
                let data = try Data(contentsOf: url)
                guard let string = String(data: data, encoding: .utf8) else {
                    loadFailureMessage = "Could not decode file as UTF-8"
                    buffer.load(url: url, text: "")
                    applyTextToView("⚠︎ Could not decode \(url.lastPathComponent) as UTF-8")
                    return
                }
                loadFailureMessage = nil
                buffer.load(url: url, text: string)
                applyTextToView(string)
            } catch {
                loadFailureMessage = "Could not read file: \(error.localizedDescription)"
                buffer.load(url: url, text: "")
                applyTextToView("⚠︎ Could not read \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        private func applyTextToView(_ text: String) {
            guard let textView else { return }
            // STTextView.text setter fires delegate notifications; suppress
            // them so a programmatic load doesn't mark us dirty.
            isApplyingProgrammaticChange = true
            textView.text = text
            isApplyingProgrammaticChange = false
        }

        // MARK: Save

        func save() {
            guard let url = buffer.url else { return }
            // Pull the freshest text from the view in case a change
            // notification hasn't flushed yet.
            if let textView, (textView.text ?? "") != buffer.text {
                buffer.recordEdit(text: textView.text ?? "")
            }
            guard let data = buffer.text.data(using: .utf8) else {
                onSaveResult(.failure(SaveError.encodingFailed))
                return
            }
            do {
                try data.write(to: url, options: .atomic)
                buffer.markSaved()
                publishDirty()
                onSaveResult(.success(()))
            } catch {
                // Keep the buffer dirty so the user can retry. The view
                // surfaces the failure via the banner overlay.
                onSaveResult(.failure(error))
            }
        }

        // MARK: STTextViewDelegate

        func textViewDidChangeText(_ notification: Notification) {
            guard !isApplyingProgrammaticChange else { return }
            guard let textView else { return }
            buffer.recordEdit(text: textView.text ?? "")
            publishDirty()
        }

        private func publishDirty() {
            let newValue = buffer.isDirty
            if isDirtyBinding.wrappedValue != newValue {
                // Defer to avoid mutating SwiftUI state mid-update cycle.
                DispatchQueue.main.async { [isDirtyBinding] in
                    if isDirtyBinding.wrappedValue != newValue {
                        isDirtyBinding.wrappedValue = newValue
                    }
                }
            }
        }
    }

    /// Errors raised by the editor coordinator itself (as opposed to
    /// `Foundation.Data.write` errors, which are forwarded as-is).
    enum SaveError: LocalizedError {
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .encodingFailed:
                return "Could not encode buffer as UTF-8"
            }
        }
    }
}

/// `STTextView` subclass that calls `onSaveRequested` when the user
/// presses Cmd+S while the pane has key focus.
final class EditorTextView: STTextView {
    var onSaveRequested: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "s" {
            onSaveRequested?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

enum CodePreview {
    static let sample = """
    import SwiftUI
    import STTextView
    import GhosttyVt

    struct PaneView: View {
        var body: some View {
            Text("native panes only")
        }
    }
    """
}

/// Visual constants and small color derivations that make the editor pane
/// read as a distinct surface from the terminal. Centralised here so the
/// `makeNSView` / `updateNSView` paths stay in lock-step and theme switches
/// re-derive the same shades.
enum EditorChrome {
    /// 13 pt monospaced. Bento favors SF Mono when available, otherwise
    /// falls back to Menlo. Avoids `monospacedSystemFont`'s slightly
    /// rounded glyphs to better signal "code editor" vs. terminal output
    /// (which already uses the same size — distinction comes from gutter,
    /// current-line highlight, and insets, not type size).
    static var editorFont: NSFont {
        if let sfMono = NSFont(name: "SF Mono", size: 13) {
            return sfMono
        }
        if let menlo = NSFont(name: "Menlo", size: 13) {
            return menlo
        }
        return NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    }

    /// Horizontal text-container padding. Applied via
    /// `NSTextContainer.lineFragmentPadding` so the cursor & glyphs sit
    /// ~12 pt off both edges without disturbing layout-manager metrics.
    static let horizontalPadding: CGFloat = 12

    /// Vertical breathing room. Lives on the enclosing `NSScrollView` as
    /// `contentInsets` because the STTextView gutter is a floating
    /// subview and stays glued to the document view's top edge.
    static let verticalPadding: CGFloat = 8

    /// Editor body background. Blends `panel` (80%) with `background`
    /// (20%) so the editor reads as a different surface than the terminal
    /// at a glance, without introducing a new theme key. The blend lands
    /// slightly darker on `bento`/`carbon`/`tokyo` (all dark themes) and
    /// slightly lighter on `paper`, which is the natural read in both
    /// directions.
    static func editorBackground(_ theme: ThemeSpec) -> NSColor {
        blend(
            NSColor(hex: theme.chrome.panel.hex),
            with: NSColor(hex: theme.chrome.background.hex),
            ratio: 0.20
        )
    }

    /// Gutter background. Pushes one extra step toward `background` so
    /// the gutter reads as a recessed strip relative to the editor body.
    static func gutterBackground(_ theme: ThemeSpec) -> NSColor {
        blend(
            editorBackground(theme),
            with: NSColor(hex: theme.chrome.background.hex),
            ratio: 0.45
        )
    }

    /// Current-line highlight. `activeBorder` at ~8% alpha — present
    /// enough to find the caret on a row scan, never loud enough to
    /// distract while typing.
    static func currentLineColor(_ theme: ThemeSpec) -> NSColor {
        NSColor(hex: theme.chrome.activeBorder.hex).withAlphaComponent(0.08)
    }

    /// Configures the STTextView-owned gutter. Safe to call repeatedly:
    /// every property assignment is idempotent. Called once after the
    /// gutter is auto-created and again on every `updateNSView` so theme
    /// changes propagate without rebuilding the text view.
    ///
    /// `@MainActor` because several STGutterView properties (notably
    /// `highlightSelectedLine`) are themselves actor-isolated; the call
    /// sites in `makeNSView`/`updateNSView` already run on the main
    /// actor under SwiftUI's `NSViewRepresentable` contract.
    @MainActor
    static func styleGutter(_ gutter: STGutterView?, theme: ThemeSpec) {
        guard let gutter else { return }
        // ~40 pt minimum reads as a deliberate strip even on short files;
        // STTextView will still grow it for 4+ digit line numbers.
        gutter.minimumThickness = 40
        // Right-align numbers with ~6 pt of breathing room from the body
        // edge. STGutterLineNumberCell honors `trailing` as right padding.
        gutter.insets = STRulerInsets(leading: 8, trailing: 6)
        gutter.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        gutter.textColor = NSColor(hex: theme.chrome.dimText.hex)
        gutter.selectedLineTextColor = NSColor(hex: theme.chrome.text.hex)
        gutter.highlightSelectedLine = false
        gutter.selectedLineHighlightColor = currentLineColor(theme)
        // STGutterView.backgroundColor is internal, but the only thing it
        // drives (besides toggling a fallback NSVisualEffectView when nil)
        // is `layer?.backgroundColor`. STTextView seeds gutter with a
        // non-nil background from `textView.backgroundColor` before this
        // runs, so the visual-effect fallback path isn't active and we
        // can safely tint the layer directly to recess the strip a step
        // below the editor body.
        gutter.wantsLayer = true
        gutter.layer?.backgroundColor = gutterBackground(theme).cgColor
        gutter.drawSeparator = true
        gutter.separatorColor = NSColor(hex: theme.chrome.border.hex)
    }

    /// Linear blend in the device RGB space. `ratio` is the contribution
    /// of `other`; `0.0` returns `base`, `1.0` returns `other`. Falls back
    /// to `base` if either color can't bridge to `deviceRGB` (defensive —
    /// the hex initializer above always produces a calibratedRGB color so
    /// the fallback is mostly belt-and-suspenders).
    private static func blend(_ base: NSColor, with other: NSColor, ratio: CGFloat) -> NSColor {
        guard
            let a = base.usingColorSpace(.deviceRGB),
            let b = other.usingColorSpace(.deviceRGB)
        else { return base }
        let r = a.redComponent * (1 - ratio) + b.redComponent * ratio
        let g = a.greenComponent * (1 - ratio) + b.greenComponent * ratio
        let bl = a.blueComponent * (1 - ratio) + b.blueComponent * ratio
        return NSColor(deviceRed: r, green: g, blue: bl, alpha: 1)
    }
}

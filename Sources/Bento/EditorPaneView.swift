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
    @ObservedObject var fileMap: PaneFileMap
    @Binding var isDirty: Bool

    @State private var saveError: String?
    @State private var saveErrorToken: Int = 0

    init(
        theme: ThemeSpec,
        paneID: PaneID,
        fileMap: PaneFileMap,
        isDirty: Binding<Bool> = .constant(false)
    ) {
        self.theme = theme
        self.paneID = paneID
        self.fileMap = fileMap
        self._isDirty = isDirty
    }

    var body: some View {
        STTextEditorRepresentable(
            theme: theme,
            openFile: fileMap.binding(for: paneID),
            isDirty: $isDirty,
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
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color(hex: theme.chrome.activeBorder.hex), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(hex: theme.chrome.panel.hex))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color(hex: theme.chrome.activeBorder.hex).opacity(0.6), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
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
    let onSaveResult: (Result<Void, Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isDirty: $isDirty, onSaveResult: onSaveResult)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(hex: theme.chrome.panel.hex)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true

        let textView = EditorTextView()
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = NSColor(hex: theme.chrome.text.hex)
        textView.insertionPointColor = NSColor(hex: theme.chrome.activeBorder.hex)
        textView.backgroundColor = NSColor(hex: theme.chrome.panel.hex)
        textView.isEditable = true
        textView.isSelectable = true
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

        scrollView.backgroundColor = NSColor(hex: theme.chrome.panel.hex)
        guard let textView = scrollView.documentView as? EditorTextView else { return }
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = NSColor(hex: theme.chrome.text.hex)
        textView.insertionPointColor = NSColor(hex: theme.chrome.activeBorder.hex)
        textView.backgroundColor = NSColor(hex: theme.chrome.panel.hex)

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

        init(isDirty: Binding<Bool>, onSaveResult: @escaping (Result<Void, Error>) -> Void) {
            self.isDirtyBinding = isDirty
            self.onSaveResult = onSaveResult
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

import AppKit
import BentoCore
import STTextView
import SwiftUI

/// SwiftUI shell for the editor pane. Thin wrapper around an STTextView
/// that loads the file at `openFile`, reports dirty state back through
/// the optional `isDirty` binding, and writes the buffer to disk on
/// Cmd+S. All non-AppKit state transitions live in `EditorBuffer`.
struct EditorPaneView: View {
    let theme: ThemeSpec
    @Binding var openFile: URL?
    @Binding var isDirty: Bool

    init(
        theme: ThemeSpec,
        openFile: Binding<URL?>,
        isDirty: Binding<Bool> = .constant(false)
    ) {
        self.theme = theme
        self._openFile = openFile
        self._isDirty = isDirty
    }

    var body: some View {
        STTextEditorRepresentable(
            theme: theme,
            openFile: $openFile,
            isDirty: $isDirty
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

    func makeCoordinator() -> Coordinator {
        Coordinator(isDirty: $isDirty)
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
        private var loadFailureMessage: String?

        init(isDirty: Binding<Bool>) {
            self.isDirtyBinding = isDirty
        }

        func attach(textView: EditorTextView) {
            self.textView = textView
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
            guard let data = buffer.text.data(using: .utf8) else { return }
            do {
                try data.write(to: url, options: .atomic)
                buffer.markSaved()
                publishDirty()
            } catch {
                // Surface failures via the loadFailureMessage channel — we
                // don't have a richer error UI yet. The buffer stays dirty
                // so the user can retry.
                loadFailureMessage = "Could not save: \(error.localizedDescription)"
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

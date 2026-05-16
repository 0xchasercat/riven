import AppKit
import BentoCore
import STTextView
import SwiftUI

/// Scaffold for the editor pane. Today this just renders an `STTextView`
/// with a fixed sample buffer; a follow-up slice will wire it to a real
/// file URL with open/save behavior.
struct EditorPaneView: View {
    let theme: ThemeSpec
    @Binding var openFile: URL?

    var body: some View {
        STTextEditorRepresentable(theme: theme, openFile: $openFile)
    }
}

struct STTextEditorRepresentable: NSViewRepresentable {
    let theme: ThemeSpec
    @Binding var openFile: URL?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(hex: theme.chrome.panel.hex)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true

        let textView = STTextView()
        textView.text = openFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? CodePreview.sample
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = NSColor(hex: theme.chrome.text.hex)
        textView.insertionPointColor = NSColor(hex: theme.chrome.activeBorder.hex)
        textView.backgroundColor = NSColor(hex: theme.chrome.panel.hex)
        textView.isEditable = true
        textView.isSelectable = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        scrollView.backgroundColor = NSColor(hex: theme.chrome.panel.hex)
        guard let textView = scrollView.documentView as? STTextView else { return }
        if let url = openFile {
            let onDisk = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if textView.text != onDisk {
                textView.text = onDisk
            }
        }
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = NSColor(hex: theme.chrome.text.hex)
        textView.insertionPointColor = NSColor(hex: theme.chrome.activeBorder.hex)
        textView.backgroundColor = NSColor(hex: theme.chrome.panel.hex)
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

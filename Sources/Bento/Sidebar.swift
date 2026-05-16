import BentoCore
import SwiftUI

/// Project file tree sidebar. Tapping a file fires `onOpenFile`; the editor
/// surface is responsible for actually loading the buffer.
struct SidebarView: View {
    let theme: ThemeSpec
    let fileTree: ProjectFileTree
    let onOpenFile: (URL) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(fileTree.name.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
                    .padding(.top, 18)
                ForEach(fileTree.children) { node in
                    FileTreeRow(node: node, theme: theme, onOpenFile: onOpenFile)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 220, idealWidth: 220, maxWidth: 220, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(hex: theme.chrome.background.hex))
    }
}

struct FileTreeRow: View {
    let node: ProjectFileTree
    let theme: ThemeSpec
    var depth: Int = 0
    let onOpenFile: (URL) -> Void
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(node.kind == .directory ? (isExpanded ? "v" : ">") : " ")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
                    .frame(width: 10)
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(Color(hex: node.kind == .directory ? theme.chrome.text.hex : theme.chrome.dimText.hex))
            }
            .font(.system(size: 12, weight: node.kind == .directory ? .medium : .regular, design: .monospaced))
            .padding(.leading, CGFloat(depth * 12))
            .contentShape(Rectangle())
            .onTapGesture {
                switch node.kind {
                case .directory:
                    isExpanded.toggle()
                case .file:
                    onOpenFile(URL(fileURLWithPath: node.path))
                }
            }

            if isExpanded {
                ForEach(node.children) { child in
                    FileTreeRow(node: child, theme: theme, depth: depth + 1, onOpenFile: onOpenFile)
                }
            }
        }
    }
}

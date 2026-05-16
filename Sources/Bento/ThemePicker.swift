import BentoCore
import SwiftUI

struct ThemePicker: View {
    let theme: ThemeSpec
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Choose Bento's finish")
                .font(.system(size: 22, weight: .bold))
            Text("This controls app chrome, terminal colors, editor syntax, cursor, and selection styling.")
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(Color(hex: theme.chrome.dimText.hex))
            HStack(spacing: 10) {
                ForEach(ThemeSpec.builtIns) { option in
                    Button {
                        onSelect(option.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(hex: option.chrome.panel.hex))
                                .frame(height: 64)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3)
                                        .stroke(Color(hex: option.chrome.activeBorder.hex), lineWidth: 1)
                                )
                            Text(option.name)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            Text(option.terminal.prompt.hex)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Color(hex: option.chrome.dimText.hex))
                        }
                        .padding(10)
                        .frame(width: 132, alignment: .leading)
                        .background(Color(hex: option.chrome.background.hex))
                        .overlay(Rectangle().stroke(Color(hex: option.chrome.border.hex), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(24)
        .background(Color(hex: theme.chrome.panel.hex))
        .overlay(Rectangle().stroke(Color(hex: theme.chrome.activeBorder.hex), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 30, y: 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.45))
    }
}

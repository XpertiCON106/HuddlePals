import SwiftUI

/// Caption input that hard-enforces the 80-character limit and shows a
/// live counter once the writer gets close.
struct CaptionTextField: View {
    @Binding var text: String
    var placeholder = "Add a line… (optional)"

    private var remaining: Int { VaultEngine.captionLimit - text.count }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField(placeholder, text: $text, axis: .vertical)
                .font(.system(size: 16))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1...3)
                .padding(14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onChange(of: text) { _, newValue in
                    if newValue.count > VaultEngine.captionLimit {
                        text = String(newValue.prefix(VaultEngine.captionLimit))
                    }
                }
            if text.count > VaultEngine.captionLimit - 20 {
                Text("\(remaining)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(remaining <= 5 ? Theme.destructive : Theme.textSecondary)
            }
        }
    }
}

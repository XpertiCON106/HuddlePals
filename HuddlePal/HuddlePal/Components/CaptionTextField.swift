import SwiftUI

/// Caption input that hard-enforces the 80-character limit and shows a
/// live counter once the writer gets close.
struct CaptionTextField: View {
    @Binding var text: String
    var placeholder = "Add a line… (optional)"

    private var remaining: Int { HuddleEngine.captionLimit - text.serverLength }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField(placeholder, text: $text, axis: .vertical)
                .font(.system(size: 16))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1...3)
                .padding(14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                )
                .onChange(of: text) { _, newValue in
                    if newValue.serverLength > HuddleEngine.captionLimit {
                        text = newValue.prefix(serverLength: HuddleEngine.captionLimit)
                    }
                }
            if text.serverLength > HuddleEngine.captionLimit - 20 {
                Text("\(remaining)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(remaining <= 5 ? Theme.destructive : Theme.textSecondary)
            }
        }
    }
}

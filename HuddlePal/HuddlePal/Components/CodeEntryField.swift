import SwiftUI

/// Verification code entry: one hidden text field drives `length` visible
/// boxes (6–10 — the backend picks the code length), so SMS autofill
/// (`.oneTimeCode`), paste, and the number pad all work exactly like the
/// system experience.
struct CodeEntryField: View {
    @Binding var code: String
    var length: Int = 6

    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($focused)
                .opacity(0.02)
                .frame(width: 1, height: 1)
                .accessibilityLabel("Verification code")

            HStack(spacing: length > 6 ? 6 : 10) {
                ForEach(0..<length, id: \.self) { index in
                    digitBox(at: index)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
        }
        .onChange(of: code) { _, newValue in
            let digits = String(newValue.filter(\.isNumber).prefix(length))
            if digits != newValue { code = digits }
        }
        .onAppear { focused = true }
    }

    private func digitBox(at index: Int) -> some View {
        let characters = Array(code)
        let isActive = focused && index == min(characters.count, length - 1)
        return RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Theme.surface)
            // Up to 46pt wide, shrinking so 8–10 boxes still fit a phone.
            .frame(maxWidth: 46)
            .frame(height: 56)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isActive ? Theme.accent.opacity(0.6) : Theme.hairline,
                        lineWidth: isActive ? 1.5 : 1
                    )
            )
            .overlay {
                if index < characters.count {
                    Text(String(characters[index]))
                        .font(.system(size: 24, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            .shadow(color: Theme.shadow, radius: 4, x: 0, y: 2)
            .animation(.easeInOut(duration: 0.12), value: isActive)
    }
}

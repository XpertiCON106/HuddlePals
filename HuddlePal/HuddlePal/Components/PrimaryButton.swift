import SwiftUI

/// The single action style: ink-black bar, white label, soft lift. One
/// button color in the whole app keeps the hierarchy unmistakable.
struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    var isLoading = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    HuddleSpinner(size: 20, color: Theme.onAccent, label: nil)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(Theme.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            // The shadow is the fill's, not the label's: on the label it
            // haloed the text and cost it contrast.
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.accent.opacity(isEnabled ? 1 : 0.25))
                    .shadow(
                        color: .black.opacity(isEnabled ? 0.18 : 0),
                        radius: 12, x: 0, y: 5
                    )
            )
        }
        .disabled(!isEnabled || isLoading)
        .animation(.easeInOut(duration: 0.15), value: isEnabled)
    }
}

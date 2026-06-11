import SwiftUI

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
                    ProgressView()
                        .tint(Theme.background)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(Theme.background)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                Theme.accent.opacity(isEnabled ? 1 : 0.35),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
        .disabled(!isEnabled || isLoading)
        .animation(.easeInOut(duration: 0.15), value: isEnabled)
    }
}

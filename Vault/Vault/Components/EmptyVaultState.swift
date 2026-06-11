import SwiftUI

struct EmptyVaultState: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.accent.opacity(0.7))
            Text(title)
                .font(Theme.displayFont(22))
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

import SwiftUI

/// Flame + count in a hairline capsule — ink on white, like a pressed
/// stamp. The streak belongs to the group, so it sits in the vault header,
/// not on any individual.
struct StreakBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "flame.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(count > 0 ? Theme.accent : Theme.textSecondary.opacity(0.6))
            Text("\(count)")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(count > 0 ? Theme.textPrimary : Theme.textSecondary)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
        .shadow(color: Theme.shadow, radius: 6, x: 0, y: 2)
        .accessibilityLabel("Group streak: \(count) days")
    }
}

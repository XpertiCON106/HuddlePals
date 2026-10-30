import SwiftUI

/// The birthday already screened before sign-in, shown privately and
/// without an editing action on the profile setup step.
struct BirthdayRow: View {
    let birthday: Birthday?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "gift")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Text("Birthday")
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(birthday?.formatted() ?? "Not added")
                .foregroundStyle(Theme.textSecondary)
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Birthday")
        .accessibilityValue(birthday?.formatted() ?? "Not added")
        .accessibilityHint("Only you can see it.")
        .accessibilityIdentifier("birthdayRow")
    }
}

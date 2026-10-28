import SwiftUI

/// "Birthday" and its date (or "Add your birthday", marked Required),
/// opening the app's card with a date wheel, on the sign-up profile step
/// (Profile only shows it). Says what was picked through `onPicked`; the
/// owner decides whether it's kept (it must meet the minimum age).
struct BirthdayRow: View {
    let birthday: Birthday?
    let onPicked: (Birthday) -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var picking = false
    @State private var wheel = Birthday.wheelStart.date()

    var body: some View {
        Button {
            wheel = (birthday ?? .wheelStart).date()
            picking = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "gift")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(birthday == nil && isEnabled ? Theme.accent : Theme.textSecondary)
                if let birthday {
                    Text("Birthday")
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(birthday.formatted())
                        .foregroundStyle(Theme.textSecondary)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    // Not given yet: asked for plainly, and marked as needed.
                    Text("Add your birthday")
                        .fontWeight(.semibold)
                        .foregroundStyle(isEnabled ? Theme.accent : Theme.textSecondary)
                    Spacer()
                    Text("Required")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.surfaceElevated, in: Capsule())
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Birthday")
        .accessibilityValue(birthday?.formatted() ?? "Not added. Required.")
        .accessibilityHint("Only you can see it.")
        .appDialog(
            "Your birthday",
            isPresented: $picking,
            message: "Only you can see it.",
            actions: [
                DialogAction("Done") { onPicked(Birthday(date: wheel)) },
                .cancel(),
            ]
        ) {
            DatePicker("Birthday", selection: $wheel, in: ...Date.now, displayedComponents: .date)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(height: 170)
        }
    }
}

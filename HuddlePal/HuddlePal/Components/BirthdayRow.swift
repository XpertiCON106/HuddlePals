import SwiftUI

/// "Birthday" and its date (or Add), opening the app's card with a date
/// wheel. Says what was picked through `onPicked`; the owner decides whether
/// it's kept (it must meet the minimum age).
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
            HStack(spacing: 8) {
                Text("Birthday")
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(birthday?.formatted() ?? "Add")
                    .foregroundStyle(birthday == nil && isEnabled ? Theme.accent : Theme.textSecondary)
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Birthday")
        .accessibilityValue(birthday?.formatted() ?? "Not added")
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

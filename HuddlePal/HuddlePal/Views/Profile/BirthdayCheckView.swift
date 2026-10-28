import SwiftUI

/// Asked once of an account made before birthdays were (`needsBirthday`),
/// before anything else: the birthday, which only its owner can see. Under
/// the minimum age, HuddlePals stops there and offers to sign out.
struct BirthdayCheckView: View {
    @Environment(AppDependencies.self) private var deps
    @State private var wheel = Birthday.wheelStart.date()
    @State private var isSaving = false
    @State private var isUnderage = false
    @State private var errorMessage: String?

    var body: some View {
        if isUnderage {
            UnderageNotice {
                Task { await deps.signOut() }
            }
        } else {
            question
        }
    }

    private var question: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "gift.fill")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 56)
                    .accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text("When's your birthday?")
                        .font(Theme.displayFont(28))
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text("Only you can see it. We ask everyone once.")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }

                DatePicker("Birthday", selection: $wheel, in: ...Date.now, displayedComponents: .date)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .cardSurface()

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.destructive)
                        .multilineTextAlignment(.center)
                }

                PrimaryButton(title: "Continue", isLoading: isSaving) {
                    Task { await save() }
                }
            }
            .padding(.horizontal, Theme.screenPadding)
            .padding(.bottom, 36)
        }
        .background(Theme.background)
    }

    private func save() async {
        let birthday = Birthday(date: wheel)
        guard birthday.isOldEnough(on: .now) else {
            isUnderage = true
            return
        }
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        do {
            try await deps.auth.saveBirthday(birthday)
            deps.session.needsBirthday = false
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Under the minimum age: only this, and a way out. Shown in place of the
/// whole page, on the sign-up profile step and the one-time birthday question.
struct UnderageNotice: View {
    let signOut: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text("HuddlePals is for people \(Birthday.minimumAge) or older.")
                .font(Theme.displayFont(24))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Button(action: signOut) {
                Text("Sign out")
            }
            .buttonStyle(ActionButtonStyle(role: .secondary))
        }
        .padding(20)
        .cardSurface()
        .padding(.horizontal, Theme.screenPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

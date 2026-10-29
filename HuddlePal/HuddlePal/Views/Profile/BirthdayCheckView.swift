import SwiftUI

/// Asked once of an account made before birthdays were collected,
/// before anything else: the birthday, which only its owner can see. Under
/// the minimum age, HuddlePals stops there and offers to sign out.
struct BirthdayCheckView: View {
    @Environment(AppDependencies.self) private var deps
    @State private var viewModel: BirthdayCheckViewModel?
    @State private var showDeleteAccount = false

    var body: some View {
        Group {
            if let viewModel {
                if viewModel.isUnderage {
                    UnderageNotice(signOut: {
                        Task { await viewModel.signOut() }
                    }, deleteAccount: { showDeleteAccount = true })
                } else {
                    question(viewModel)
                }
            } else {
                Color.clear
            }
        }
        .onAppear {
            if viewModel == nil { viewModel = BirthdayCheckViewModel(deps: deps) }
        }
        .sheet(isPresented: $showDeleteAccount) {
            NavigationStack { DeleteAccountView() }
        }
    }

    private func question(_ model: BirthdayCheckViewModel) -> some View {
        @Bindable var model = model
        return ScrollView {
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

                BirthdayEntry(birthday: $model.birthday)
                    .disabled(model.isSaving || model.hasSavedBirthday)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .cardSurface()

                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.destructive)
                        .multilineTextAlignment(.center)
                }

                PrimaryButton(title: "Continue", isLoading: model.isSaving, isEnabled: model.canContinue) {
                    Task { await model.save() }
                }
                Button("Sign out") { Task { await model.signOut() } }
                    .disabled(model.isSaving)
                Button("Delete account") { showDeleteAccount = true }
                    .disabled(model.isSaving)
            }
            .padding(.horizontal, Theme.screenPadding)
            .padding(.bottom, 36)
        }
        .background(Theme.background)
    }

}

/// Under the minimum age: only this, and a way out. Shown in place of the
/// whole page, on the sign-up profile step and the one-time birthday question.
struct UnderageNotice: View {
    let signOut: () -> Void
    var deleteAccount: (() -> Void)? = nil
    var exitTitle = "Sign out"

    var body: some View {
        VStack(spacing: 18) {
            Text("HuddlePals is for people \(Birthday.minimumAge) or older.")
                .font(Theme.displayFont(24))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Button(action: signOut) {
                Text(exitTitle)
            }
            .buttonStyle(ActionButtonStyle(role: .secondary))
            if let deleteAccount {
                Button("Delete account", action: deleteAccount)
                    .foregroundStyle(Theme.destructive)
            }
        }
        .padding(20)
        .cardSurface()
        .padding(.horizontal, Theme.screenPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

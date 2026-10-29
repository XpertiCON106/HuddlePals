import StoreKit
import SwiftUI

/// Deleting the account, from Profile: what goes and what stays, Apple's
/// billing when it goes on, and DELETE typed before the button works.
struct DeleteAccountView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @State private var viewModel: DeleteAccountViewModel?

    var body: some View {
        Group {
            if let viewModel {
                DeleteAccountContent(viewModel: viewModel) { router.resetAll() }
            } else {
                Color.clear
            }
        }
        .background(Theme.background)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .onAppear {
            if viewModel == nil { viewModel = DeleteAccountViewModel(deps: deps) }
        }
    }
}

private struct DeleteAccountContent: View {
    @Bindable var viewModel: DeleteAccountViewModel
    let onDeleted: () -> Void

    @FocusState private var fieldFocused: Bool
    @State private var showManageSubscription = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.xmark")
                        .font(.system(size: 30))
                        .foregroundStyle(Theme.destructive)
                        .frame(width: 62, height: 62)
                        .background(Theme.destructive.opacity(0.13), in: Circle())
                        .accessibilityHidden(true)
                    Text("Delete your account?")
                        .font(Theme.displayFont(28))
                        .foregroundStyle(Theme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text("Take a moment. Here's what happens.")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.top, 8)

                VStack(alignment: .leading, spacing: 16) {
                    point("trash", "Your account, name, bio, birthday and profile photos are deleted, and you're signed out.")
                    point("photo.on.rectangle.angled", "Photos and videos you already posted stay in your huddles as \u{201C}Former member\u{201D}. A huddle's archive is permanent.")
                    point("person.2", "Huddles you keep pass to the member who's been in them longest. A huddle with no other member left is deleted, with everything in it.")
                    point("exclamationmark.circle", "This can't be undone.", warning: true)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface()
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                        .strokeBorder(Theme.destructive.opacity(0.35), lineWidth: 1)
                )

                if viewModel.appleBillingContinues {
                    billingWarning
                }

                VStack(alignment: .leading, spacing: 10) {
                    (Text("Type ")
                        + Text(DeleteAccountViewModel.confirmationWord).foregroundStyle(Theme.destructive)
                        + Text(" to confirm"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    TextField(DeleteAccountViewModel.confirmationWord, text: $viewModel.confirmation)
                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($fieldFocused)
                        .onSubmit { fieldFocused = false }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 52)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(
                                    viewModel.isConfirmed || fieldFocused ? Theme.destructive : Theme.destructive.opacity(0.35),
                                    lineWidth: viewModel.isConfirmed ? 2 : 1.5
                                )
                        )
                        .disabled(viewModel.isDeleting)
                        .accessibilityLabel("Type \(DeleteAccountViewModel.confirmationWord) to confirm")
                        .accessibilityIdentifier("deleteConfirmation")
                }

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.destructive)
                }
            }
            .padding(.horizontal, Theme.screenPadding)
            .padding(.bottom, 24)
        }
        // Red, not ink, on this page: the caret, and Manage subscription.
        .tint(Theme.destructive)
        .scrollDismissesKeyboard(.interactively)
        // Pinned above the keyboard: right there once DELETE is typed.
        .safeAreaInset(edge: .bottom) {
            Button {
                fieldFocused = false
                Task { if await viewModel.delete() { onDeleted() } }
            } label: {
                HStack(spacing: 8) {
                    if viewModel.isDeleting {
                        HuddleSpinner(size: 20, color: Theme.onDestructive, label: nil)
                    }
                    Text("Delete my account")
                }
            }
            .buttonStyle(ActionButtonStyle(role: .destructive))
            .disabled(!viewModel.canDelete)
            .accessibilityHint(viewModel.isConfirmed ? "" : "Type \(DeleteAccountViewModel.confirmationWord) above first.")
            .padding(.horizontal, Theme.screenPadding)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(Theme.background.opacity(0.94))
        }
        .task { await viewModel.load() }
        .manageSubscriptionsSheet(isPresented: $showManageSubscription)
        .appDialog(
            "Apple couldn't confirm it's you",
            isPresented: $viewModel.isAppleConfirmationFailurePresented,
            message: "You can still delete your account. Afterwards, remove HuddlePals in Settings › your name › Sign-In & Security › Sign in with Apple.",
            actions: [
                DialogAction("Delete account anyway", role: .destructive) {
                    Task { if await viewModel.deleteWithoutApple() { onDeleted() } }
                },
                .cancel(),
            ]
        )
    }

    /// Deleting the account doesn't stop Apple billing for Plus.
    private var billingWarning: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(DeleteAccountViewModel.billingContinuesWarning)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textPrimary)
            } icon: {
                Image(systemName: "creditcard")
                    .foregroundStyle(Theme.destructive)
            }
            if viewModel.canManageSubscription {
                Button("Manage subscription") { showManageSubscription = true }
                    .font(.system(size: 14, weight: .semibold))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .strokeBorder(Theme.destructive, lineWidth: 1)
        )
    }

    private func point(_ symbol: String, _ text: String, warning: Bool = false) -> some View {
        Label {
            Text(text)
                .font(.system(size: 15, weight: warning ? .semibold : .regular))
                .foregroundStyle(warning ? Theme.destructive : Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(Theme.destructive)
                .frame(width: 24)
        }
    }
}

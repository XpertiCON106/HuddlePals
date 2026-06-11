import SwiftUI

struct JoinVaultView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @State private var viewModel: JoinVaultViewModel?

    var body: some View {
        Group {
            if let viewModel {
                JoinVaultContent(viewModel: viewModel) {
                    router.popToRoot(of: .today)
                }
            } else {
                Color.clear
            }
        }
        .background(Theme.background)
        .navigationTitle("Join a Vault")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .onAppear {
            if viewModel == nil { viewModel = JoinVaultViewModel(deps: deps) }
        }
    }
}

private struct JoinVaultContent: View {
    @Bindable var viewModel: JoinVaultViewModel
    let onDone: () -> Void

    @FocusState private var codeFocused: Bool

    var body: some View {
        VStack(spacing: 24) {
            if let vault = viewModel.joinedVault {
                joinedState(vault)
            } else {
                entryState
            }
            Spacer()
        }
        .padding(Theme.screenPadding)
    }

    private var entryState: some View {
        VStack(spacing: 22) {
            Image(systemName: "person.badge.key")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.accent)
                .padding(.top, 24)

            Text("Enter your invite code")
                .font(Theme.displayFont(24))
                .foregroundStyle(Theme.textPrimary)

            Text("Ask the vault's keeper for the 6-character code.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)

            TextField("ABC123", text: $viewModel.code)
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .focused($codeFocused)
                .padding(.vertical, 14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onChange(of: viewModel.code) { _, newValue in
                    if newValue.count > 6 {
                        viewModel.code = String(newValue.prefix(6))
                    }
                }

            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.destructive)
                    .multilineTextAlignment(.center)
            }

            PrimaryButton(
                title: "Join vault",
                isLoading: viewModel.isJoining,
                isEnabled: viewModel.canJoin
            ) {
                codeFocused = false
                Task { await viewModel.join() }
            }
        }
        .onAppear { codeFocused = true }
    }

    private func joinedState(_ vault: Vault) -> some View {
        VStack(spacing: 18) {
            Text(vault.emoji)
                .font(.system(size: 64))
                .padding(.top, 32)
            Text("Welcome to \(vault.name)")
                .font(Theme.displayFont(26))
                .foregroundStyle(Theme.textPrimary)
            Text("Deposit a photo today to see what everyone else shared.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            PrimaryButton(title: "Go to today", systemImage: "lock.fill") {
                onDone()
            }
        }
    }
}

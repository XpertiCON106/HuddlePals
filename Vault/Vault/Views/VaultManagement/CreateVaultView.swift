import SwiftUI

struct CreateVaultView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @State private var viewModel: CreateVaultViewModel?

    var body: some View {
        Group {
            if let viewModel {
                CreateVaultContent(viewModel: viewModel) {
                    router.popToRoot(of: .today)
                }
            } else {
                Color.clear
            }
        }
        .background(Theme.background)
        .navigationTitle("Create a Vault")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .onAppear {
            if viewModel == nil { viewModel = CreateVaultViewModel(deps: deps) }
        }
    }
}

private struct CreateVaultContent: View {
    @Bindable var viewModel: CreateVaultViewModel
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if let vault = viewModel.createdVault {
                    createdState(vault)
                } else {
                    formState
                }
            }
            .padding(Theme.screenPadding)
        }
    }

    private var formState: some View {
        VStack(spacing: 24) {
            Text(viewModel.emoji)
                .font(.system(size: 64))
                .padding(.top, 12)

            TextField("Vault name", text: $viewModel.name)
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .multilineTextAlignment(.center)
                .padding(14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                ForEach(CreateVaultViewModel.emojiChoices, id: \.self) { choice in
                    Button {
                        viewModel.emoji = choice
                        Haptics.light()
                    } label: {
                        Text(choice)
                            .font(.system(size: 28))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                choice == viewModel.emoji ? Theme.surfaceElevated : .clear,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.destructive)
            }

            PrimaryButton(
                title: "Create vault",
                systemImage: "lock.shield",
                isLoading: viewModel.isCreating,
                isEnabled: viewModel.canCreate
            ) {
                Task { await viewModel.create() }
            }
        }
    }

    private func createdState(_ vault: Vault) -> some View {
        VStack(spacing: 20) {
            Text("\(vault.emoji)")
                .font(.system(size: 64))
                .padding(.top, 12)
            Text(vault.name)
                .font(Theme.displayFont(26))
                .foregroundStyle(Theme.textPrimary)
            Text("Share this code with up to 7 people you'd trust with the family album.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)

            Text(vault.inviteCode)
                .font(.system(size: 34, weight: .bold, design: .monospaced))
                .kerning(6)
                .foregroundStyle(Theme.accent)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            if let url = viewModel.shareURL {
                ShareLink(item: url, message: Text("Join our vault \"\(vault.name)\" on Vault")) {
                    Label("Share invite link", systemImage: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.background)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }

            Button("Done") { onDone() }
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

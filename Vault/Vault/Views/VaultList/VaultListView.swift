import SwiftUI

/// The shelf: every vault you belong to, each with its members, streak,
/// and today's lock state. Tap to step inside.
struct VaultListView: View {
    @Environment(AppDependencies.self) private var deps
    @State private var viewModel: VaultListViewModel?

    var body: some View {
        Group {
            if let viewModel {
                VaultListContent(viewModel: viewModel)
            } else {
                Color.clear
            }
        }
        .background(Theme.background)
        .onAppear {
            if viewModel == nil { viewModel = VaultListViewModel(deps: deps) }
        }
    }
}

private struct VaultListContent: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var viewModel: VaultListViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if viewModel.isLoading && !viewModel.hasVaults {
                    ProgressView()
                        .padding(.top, 120)
                } else if !viewModel.hasVaults {
                    emptyState
                } else {
                    ForEach(viewModel.rows) { row in
                        Button {
                            Haptics.light()
                            router.vaultsPath.append(.vaultHome(row.vault))
                        } label: {
                            VaultRowCard(row: row)
                        }
                        .buttonStyle(.plain)
                        .transition(.scale(scale: 0.97).combined(with: .opacity))
                    }
                }

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.destructive)
                }
            }
            .padding(.horizontal, Theme.screenPadding)
            .padding(.top, 8)
            .padding(.bottom, 36)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: viewModel.rows.map(\.id))
        }
        .refreshable { await viewModel.refresh() }
        .navigationTitle("Vaults")
        .toolbarBackground(Theme.background, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        router.vaultsPath.append(.createVault)
                    } label: {
                        Label("Create a Vault", systemImage: "plus.circle")
                    }
                    Button {
                        router.vaultsPath.append(.joinVault)
                    } label: {
                        Label("Join with a code", systemImage: "person.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .accessibilityLabel("Create or join a vault")
            }
        }
        .task { await viewModel.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await viewModel.refresh() }
            }
        }
        .onChange(of: deps.dateProvider.dayOffset) {
            Task { await viewModel.refresh() }
        }
        .onChange(of: deps.debug.simulateNotPostedToday) {
            Task { await viewModel.refresh() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            EmptyVaultState(
                systemImage: "shippingbox",
                title: "No vaults yet",
                message: "A vault is a small, private group — one with your family, one with your best friends. Create one or join with an invite code."
            )
            .padding(.top, 60)
            PrimaryButton(title: "Create a Vault", systemImage: "plus") {
                router.vaultsPath.append(.createVault)
            }
            Button("Join with a code") {
                router.vaultsPath.append(.joinVault)
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Theme.accent)
        }
    }
}

private struct VaultRowCard: View {
    let row: VaultListViewModel.Row

    var body: some View {
        HStack(spacing: 14) {
            Text(row.vault.emoji)
                .font(.system(size: 30))
                .frame(width: 56, height: 56)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(row.vault.name)
                    .font(Theme.displayFont(19))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    AvatarStack(users: row.members, size: 20)
                    Text(todayLine)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                StreakBadge(count: row.streak)
                Image(systemName: row.isUnlockedToday ? "lock.open" : "lock.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(row.isUnlockedToday ? Theme.textSecondary : Theme.accent)
            }
        }
        .padding(14)
        .cardSurface()
    }

    private var todayLine: String {
        if row.depositedTodayCount == 0 { return "Nobody has posted yet" }
        if row.isUnlockedToday { return "\(row.depositedTodayCount) of \(row.members.count) today" }
        return "\(row.depositedTodayCount) waiting for you"
    }
}

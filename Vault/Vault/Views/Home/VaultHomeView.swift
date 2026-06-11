import SwiftUI

/// The main screen. LOCKED: frosted grid of today's deposits + deposit CTA.
/// UNLOCKED: today's deposits as a vertical feed.
struct VaultHomeView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @State private var viewModel: VaultHomeViewModel?

    var body: some View {
        Group {
            if let viewModel {
                HomeContent(viewModel: viewModel)
            } else {
                Color.clear
            }
        }
        .background(Theme.background)
        .onAppear {
            if viewModel == nil { viewModel = VaultHomeViewModel(deps: deps) }
        }
    }
}

private struct HomeContent: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @Bindable var viewModel: VaultHomeViewModel

    var body: some View {
        Group {
            if let vault = viewModel.vault {
                vaultBody(vault)
            } else {
                NoVaultView()
            }
        }
        .navigationTitle("")
        .toolbar { toolbarContent }
        .toolbarBackground(Theme.background, for: .navigationBar)
        .task { await viewModel.refresh() }
        .onChange(of: deps.debug.simulateNotPostedToday) {
            Task { await viewModel.refresh() }
        }
        .onChange(of: deps.dateProvider.dayOffset) {
            Task { await viewModel.refresh() }
        }
        .sheet(isPresented: $viewModel.showCompose) {
            ComposeView { success in
                if success {
                    Task { await viewModel.handleDepositSuccess() }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let vault = viewModel.vault {
                    Button {
                        router.todayPath.append(.vaultSettings(vault))
                    } label: {
                        Label("Vault Settings", systemImage: "gearshape")
                    }
                }
                Button {
                    router.todayPath.append(.createVault)
                } label: {
                    Label("Create a Vault", systemImage: "plus.circle")
                }
                Button {
                    router.todayPath.append(.joinVault)
                } label: {
                    Label("Join a Vault", systemImage: "person.badge.plus")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func vaultBody(_ vault: Vault) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header(vault)

                if viewModel.todayDeposits.isEmpty && !viewModel.isUnlocked {
                    firstToDepositState
                } else if viewModel.isUnlocked {
                    unlockedFeed
                } else {
                    lockedGrid
                }
            }
            .padding(.horizontal, Theme.screenPadding)
            .padding(.bottom, 36)
        }
        .overlay {
            if viewModel.playUnlockReveal {
                UnlockRevealOverlay {
                    viewModel.unlockRevealFinished()
                }
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: viewModel.isUnlocked)
    }

    private func header(_ vault: Vault) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(vault.emoji) \(vault.name)")
                    .font(Theme.displayFont(28))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                StreakBadge(count: viewModel.streakCount)
            }
            HStack {
                AvatarStack(users: viewModel.members)
                Spacer()
                Text(deps.dateProvider.now, format: .dateTime.weekday(.wide).month().day())
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.top, 8)
    }

    // MARK: Locked

    private var lockedGrid: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Locked until you share", systemImage: "lock.fill")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.accent)

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 12
            ) {
                ForEach(viewModel.todayDeposits) { deposit in
                    BlurredDepositCard(deposit: deposit)
                }
            }

            depositCTA(title: "Add today's memory")
        }
    }

    private var firstToDepositState: some View {
        VStack(spacing: 18) {
            EmptyVaultState(
                systemImage: "sunrise.fill",
                title: "Nobody has posted yet",
                message: "Be the first today. Yours unlocks theirs the moment they deposit."
            )
            depositCTA(title: "Deposit the first memory")
        }
    }

    private func depositCTA(title: String) -> some View {
        PrimaryButton(title: title, systemImage: "plus") {
            viewModel.showCompose = true
        }
        .padding(.top, 6)
    }

    // MARK: Unlocked

    private var unlockedFeed: some View {
        VStack(alignment: .leading, spacing: 18) {
            if viewModel.todayDeposits.isEmpty {
                EmptyVaultState(
                    systemImage: "sparkles",
                    title: "Today is open",
                    message: "You're in — deposits from the others will appear here as they arrive."
                )
            } else {
                ForEach(viewModel.todayDeposits) { deposit in
                    Button {
                        router.todayPath.append(.depositDetail(deposit))
                    } label: {
                        DepositCard(deposit: deposit)
                    }
                    .buttonStyle(.plain)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
            }

            if !viewModel.waitingOn.isEmpty {
                HStack(spacing: 8) {
                    AvatarStack(users: viewModel.waitingOn, size: 24)
                    Text("Waiting on \(viewModel.waitingOn.map(\.displayName).joined(separator: ", "))")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.top, 2)
            }

            Button {
                viewModel.showCompose = true
            } label: {
                Label("Replace today's photo", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.top, 4)
        }
    }
}

// MARK: - Unlock reveal

/// The signature interaction: a lock springs open over a dimmed backdrop,
/// then the feed is revealed underneath.
private struct UnlockRevealOverlay: View {
    let onFinished: () -> Void

    @State private var lockOpen = false
    @State private var fadeOut = false

    var body: some View {
        ZStack {
            Theme.background.opacity(fadeOut ? 0 : 0.88)
            Image(systemName: lockOpen ? "lock.open.fill" : "lock.fill")
                .font(.system(size: 64, weight: .medium))
                .foregroundStyle(Theme.accent)
                .scaleEffect(lockOpen ? 1.25 : 1)
                .rotationEffect(.degrees(lockOpen ? -12 : 0))
                .opacity(fadeOut ? 0 : 1)
                .contentTransition(.symbolEffect(.replace))
        }
        .ignoresSafeArea()
        .allowsHitTesting(!fadeOut)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.55).delay(0.15)) {
                lockOpen = true
            }
            withAnimation(.easeOut(duration: 0.35).delay(0.95)) {
                fadeOut = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.35) {
                onFinished()
            }
        }
    }
}

// MARK: - No vault

private struct NoVaultView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        VStack(spacing: 20) {
            EmptyVaultState(
                systemImage: "shippingbox",
                title: "No vault yet",
                message: "A vault is a small, private group — create one or join with an invite code."
            )
            PrimaryButton(title: "Create a Vault", systemImage: "plus") {
                router.todayPath.append(.createVault)
            }
            Button("Join with a code") {
                router.todayPath.append(.joinVault)
            }
            .font(.system(size: 15, weight: .medium, design: .rounded))
            .foregroundStyle(Theme.accent)
        }
        .padding(Theme.screenPadding)
    }
}

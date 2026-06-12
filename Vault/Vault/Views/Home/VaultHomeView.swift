import SwiftUI

/// One vault's "Today". LOCKED: frosted grid of today's deposits + deposit
/// CTA. UNLOCKED: today's deposits as a vertical feed. When yesterday broke
/// the streak, the 24-hour recovery countdown sits at the top.
struct VaultHomeView: View {
    @Environment(AppDependencies.self) private var deps
    let vault: Vault

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
            if viewModel == nil { viewModel = VaultHomeViewModel(deps: deps, vault: vault) }
        }
    }
}

private struct HomeContent: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var viewModel: VaultHomeViewModel

    /// Identifiable wrapper so the recovery sheet can target yesterday.
    private struct DayKeyTarget: Identifiable {
        let key: String
        var id: String { key }
    }

    @State private var recoveryTarget: DayKeyTarget?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if let recovery = viewModel.recovery {
                    RecoveryBanner(
                        recovery: recovery,
                        missingMembers: viewModel.recoveryMissingMembers,
                        currentUserID: viewModel.currentUser?.id
                    ) {
                        recoveryTarget = DayKeyTarget(key: recovery.brokenDayKey)
                    }
                }

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
        .refreshable { await viewModel.refresh() }
        .overlay {
            if viewModel.playUnlockReveal {
                UnlockRevealOverlay {
                    viewModel.unlockRevealFinished()
                }
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: viewModel.isUnlocked)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .toolbarBackground(Theme.background, for: .navigationBar)
        .task { await viewModel.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await viewModel.refresh() }
            }
        }
        .onChange(of: deps.debug.simulateNotPostedToday) {
            Task { await viewModel.refresh() }
        }
        .onChange(of: deps.dateProvider.dayOffset) {
            Task { await viewModel.refresh() }
        }
        .sheet(isPresented: $viewModel.showCompose) {
            ComposeView(vault: viewModel.vault) { success in
                if success {
                    Task { await viewModel.handleDepositSuccess() }
                }
            }
        }
        .sheet(item: $recoveryTarget) { target in
            // Recovery: backfill the broken day within the 24h window.
            ComposeView(vault: viewModel.vault, targetDayKey: target.key) { success in
                if success {
                    Task { await viewModel.handleDepositSuccess() }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 16) {
                Button {
                    router.vaultsPath.append(.archive(viewModel.vault))
                } label: {
                    Image(systemName: "archivebox")
                        .foregroundStyle(Theme.textSecondary)
                }
                Button {
                    router.vaultsPath.append(.vaultSettings(viewModel.vault))
                } label: {
                    Image(systemName: "gearshape")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(viewModel.vault.emoji) \(viewModel.vault.name)")
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
                .font(.system(size: 14, weight: .semibold))
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
                        router.vaultsPath.append(.depositDetail(deposit))
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
        }
    }
}

// MARK: - Recovery banner

/// The streak broke yesterday, but it isn't gone yet: a 24-hour window is
/// running. Live countdown, who's missing, and — if the current user is
/// one of them — the way back in.
private struct RecoveryBanner: View {
    let recovery: VaultEngine.StreakRecovery
    let missingMembers: [User]
    let currentUserID: UUID?
    let onRecover: () -> Void

    private var currentUserIsMissing: Bool {
        guard let currentUserID else { return false }
        return recovery.missingMemberIDs.contains(currentUserID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.heart.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.destructive)
                    .symbolEffect(.pulse)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Streak on the line")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Save the \(recovery.recoverableStreak)-day streak before the window closes.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Text(timerInterval: Date()...recovery.deadline, countsDown: true)
                    .font(.system(size: 17, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.destructive)
                    .monospacedDigit()
            }

            HStack(spacing: 8) {
                AvatarStack(users: missingMembers, size: 22)
                Text(missingLine)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                if currentUserIsMissing {
                    Button("Post yesterday's") {
                        onRecover()
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                }
            }
        }
        .padding(14)
        .cardSurface()
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .strokeBorder(Theme.destructive.opacity(0.35), lineWidth: 1)
        )
    }

    private var missingLine: String {
        let names = missingMembers.map(\.displayName).joined(separator: ", ")
        return names.isEmpty ? "Waiting on yesterday's photos" : "Missing yesterday: \(names)"
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

import Foundation
import Observation

@MainActor
@Observable
final class VaultHomeViewModel {
    private let deps: AppDependencies
    let vault: Vault

    private(set) var todayDeposits: [Deposit] = []
    private(set) var isUnlocked = false
    private(set) var streakCount = 0
    private(set) var members: [User] = []
    /// Non-nil while yesterday broke the streak and the 24h recovery
    /// window is still open.
    private(set) var recovery: VaultEngine.StreakRecovery?
    /// Set for one render cycle when a deposit flips the gate open, to
    /// drive the lock-opening reveal.
    private(set) var playUnlockReveal = false

    var showCompose = false

    var currentUser: User? { deps.session.currentUser }

    var todayKey: String {
        deps.engine.todayKey(now: deps.dateProvider.now)
    }

    /// Members who haven't deposited today — drives the "waiting on…" line.
    var waitingOn: [User] {
        let depositedIDs = Set(todayDeposits.compactMap { $0.author?.id })
        return members.filter { !depositedIDs.contains($0.id) }
    }

    /// Members still missing from the broken day, resolved to users.
    var recoveryMissingMembers: [User] {
        guard let recovery else { return [] }
        return members.filter { recovery.missingMemberIDs.contains($0.id) }
    }

    init(deps: AppDependencies, vault: Vault) {
        self.deps = deps
        self.vault = vault
    }

    func refresh() async {
        guard let user = currentUser else {
            todayDeposits = []
            members = []
            isUnlocked = false
            recovery = nil
            return
        }
        do {
            let all = try await deps.depositService.deposits(in: vault)
            let key = todayKey
            todayDeposits = all
                .filter { $0.dayKey == key }
                .sorted { $0.createdAt < $1.createdAt }
            members = vault.members

            let snapshots = all.compactMap(\.snapshot)
            let gateOpen = deps.engine.isUnlocked(
                vaultID: vault.id,
                currentUserID: user.id,
                deposits: snapshots,
                now: deps.dateProvider.now
            )
            // DEBUG override demos the locked state on demand.
            isUnlocked = gateOpen && !deps.debug.simulateNotPostedToday
            streakCount = vault.streakCount

            let skips = (try? await deps.vaultService.skipRecords(for: vault)) ?? [:]
            recovery = deps.engine.recovery(
                memberIDs: Set(members.map(\.id)),
                deposits: snapshots,
                skips: skips,
                now: deps.dateProvider.now
            )
        } catch {
            // Pull-based refresh: keep last state on transient failure.
        }
    }

    /// Called when Compose succeeds: recompute streak, reveal, celebrate.
    func handleDepositSuccess() async {
        let wasLocked = !isUnlocked
        deps.debug.simulateNotPostedToday = false
        try? await deps.vaultService.recomputeStreak(for: vault, now: deps.dateProvider.now)
        await refresh()
        if wasLocked, isUnlocked {
            playUnlockReveal = true
            Haptics.unlock()
        }
    }

    func unlockRevealFinished() {
        playUnlockReveal = false
    }
}

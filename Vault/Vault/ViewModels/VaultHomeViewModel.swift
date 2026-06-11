import Foundation
import Observation

@MainActor
@Observable
final class VaultHomeViewModel {
    private let deps: AppDependencies

    private(set) var todayDeposits: [Deposit] = []
    private(set) var isUnlocked = false
    private(set) var streakCount = 0
    private(set) var members: [User] = []
    /// Set for one render cycle when a deposit flips the gate open, to
    /// drive the lock-opening reveal.
    private(set) var playUnlockReveal = false

    var showCompose = false

    var vault: Vault? { deps.session.activeVault }
    var currentUser: User? { deps.session.currentUser }

    var todayKey: String {
        deps.engine.todayKey(now: deps.dateProvider.now)
    }

    /// Members who haven't deposited today — drives the "waiting on…" line.
    var waitingOn: [User] {
        let depositedIDs = Set(todayDeposits.compactMap { $0.author?.id })
        return members.filter { !depositedIDs.contains($0.id) }
    }

    init(deps: AppDependencies) {
        self.deps = deps
    }

    func refresh() async {
        guard let vault, let user = currentUser else {
            todayDeposits = []
            members = []
            isUnlocked = false
            return
        }
        do {
            let all = try await deps.depositService.deposits(in: vault)
            let key = todayKey
            todayDeposits = all
                .filter { $0.dayKey == key }
                .sorted { $0.createdAt < $1.createdAt }
            members = vault.members

            let gateOpen = deps.engine.isUnlocked(
                vaultID: vault.id,
                currentUserID: user.id,
                deposits: all.compactMap(\.snapshot),
                now: deps.dateProvider.now
            )
            // DEBUG override demos the locked state on demand.
            isUnlocked = gateOpen && !deps.debug.simulateNotPostedToday
            streakCount = vault.streakCount
        } catch {
            // Mock services can't realistically fail here; keep last state.
        }
    }

    /// Called when Compose succeeds: recompute streak, reveal, celebrate.
    func handleDepositSuccess() async {
        guard let vault else { return }
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

import Foundation
import Observation

@MainActor
@Observable
final class VaultListViewModel {
    struct Row: Identifiable {
        let vault: Vault
        let members: [User]
        let streak: Int
        /// Whether the current user has deposited today (gate open).
        let isUnlockedToday: Bool
        /// How many members have deposited today.
        let depositedTodayCount: Int
        var id: UUID { vault.id }
    }

    private let deps: AppDependencies
    private(set) var rows: [Row] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    var hasVaults: Bool { !rows.isEmpty }

    init(deps: AppDependencies) {
        self.deps = deps
    }

    func refresh() async {
        guard let user = deps.session.currentUser else {
            rows = []
            return
        }
        if rows.isEmpty { isLoading = true }
        defer { isLoading = false }
        do {
            let vaults = try await deps.vaultService.vaults(for: user)
            var built: [Row] = []
            for vault in vaults {
                // Per-vault sync keeps every row's gate state truthful.
                let deposits = try await deps.depositService.deposits(in: vault)
                try? await deps.vaultService.recomputeStreak(for: vault, now: deps.dateProvider.now)
                let snapshots = deposits.compactMap(\.snapshot)
                let today = deps.engine.todayKey(now: deps.dateProvider.now)
                let unlocked = deps.engine.isUnlocked(
                    vaultID: vault.id,
                    currentUserID: user.id,
                    deposits: snapshots,
                    now: deps.dateProvider.now
                ) && !deps.debug.simulateNotPostedToday
                built.append(Row(
                    vault: vault,
                    members: vault.members,
                    streak: vault.streakCount,
                    isUnlockedToday: unlocked,
                    depositedTodayCount: Set(
                        snapshots.lazy.filter { $0.dayKey == today }.map(\.authorID)
                    ).count
                ))
            }
            rows = built
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

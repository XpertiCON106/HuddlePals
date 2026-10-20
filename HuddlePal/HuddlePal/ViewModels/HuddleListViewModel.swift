import Foundation
import Observation

@MainActor
@Observable
final class HuddleListViewModel {
    struct Row: Identifiable {
        let huddle: Huddle
        let members: [User]
        let streak: Int
        /// Whether the current user has deposited today (gate open).
        let isUnlockedToday: Bool
        /// How many members have deposited today.
        let depositedTodayCount: Int
        var id: UUID { huddle.id }
    }

    private let deps: AppDependencies
    private(set) var rows: [Row] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    /// Huddle id → the dayKey its streak was last recomputed for.
    @ObservationIgnored private var streakRecomputedDay: [UUID: String] = [:]

    var hasHuddles: Bool { !rows.isEmpty }

    init(deps: AppDependencies) {
        self.deps = deps
    }

    /// Light by design — this runs on every appear, foreground, and pull:
    /// the huddle rows plus one "who posted today" read for all huddles. Full
    /// history (photos, reactions, comments) syncs only when a huddle opens.
    func refresh() async {
        guard let user = deps.session.currentUser else {
            rows = []
            return
        }
        if rows.isEmpty { isLoading = true }
        defer { isLoading = false }
        do {
            let huddles = try await deps.huddleService.huddles(for: user)
            let now = deps.dateProvider.now
            let today = deps.engine.todayKey(now: now)
            await recomputeStreaksIfNeeded(huddles, today: today, now: now)
            let depositors = try await deps.depositService.depositorIDs(in: huddles, dayKey: today)

            rows = huddles.map { huddle in
                let postedToday = depositors[huddle.id] ?? []
                return Row(
                    huddle: huddle,
                    members: huddle.members,
                    streak: huddle.streakCount,
                    // The gate: unlocked ⟺ you deposited today.
                    isUnlockedToday: postedToday.contains(user.id) && !deps.debug.simulateNotPostedToday,
                    depositedTodayCount: postedToday.count
                )
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// A stored streak only goes stale when a day ends (an incomplete day
    /// breaks it) or a deposit lands — and deposits recompute on their own
    /// (`HuddleHomeViewModel.handleDepositSuccess`). So once per huddle per day
    /// is enough; other members' recomputes arrive with the huddle rows.
    private func recomputeStreaksIfNeeded(_ huddles: [Huddle], today: String, now: Date) async {
        for huddle in huddles where streakRecomputedDay[huddle.id] != today {
            do {
                try await deps.huddleService.recomputeStreak(for: huddle, now: now)
                streakRecomputedDay[huddle.id] = today
            } catch {
                // Retried on the next refresh; the row shows the stored streak.
            }
        }
    }
}

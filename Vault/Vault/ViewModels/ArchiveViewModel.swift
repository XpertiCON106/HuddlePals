import Foundation
import Observation

@MainActor
@Observable
final class ArchiveViewModel {
    struct DaySection: Identifiable {
        let dayKey: String
        let date: Date
        let deposits: [Deposit]
        var id: String { dayKey }
    }

    struct MonthSection: Identifiable {
        let title: String
        let days: [DaySection]
        var id: String { title }
    }

    private let deps: AppDependencies
    let vault: Vault
    private(set) var months: [MonthSection] = []
    /// Non-nil when "add to yesterday" should be offered.
    private(set) var backfillDayKey: String?

    init(deps: AppDependencies, vault: Vault) {
        self.deps = deps
        self.vault = vault
    }

    func refresh() async {
        guard let user = deps.session.currentUser else {
            months = []
            backfillDayKey = nil
            return
        }
        do {
            let now = deps.dateProvider.now
            let engine = deps.engine
            let todayKey = engine.todayKey(now: now)
            let all = try await deps.depositService.deposits(in: vault)

            // The gate only applies to today: hide today's section while
            // locked (Home owns the locked presentation), show it once open.
            let unlocked = engine.isUnlocked(
                vaultID: vault.id,
                currentUserID: user.id,
                deposits: all.compactMap(\.snapshot),
                now: now
            ) && !deps.debug.simulateNotPostedToday
            // Hide today while locked, and hide blocked members' photos.
            let blocked = deps.session.blockedUserIDs
            let visible = all.filter {
                ($0.dayKey != todayKey || unlocked)
                    && !blocked.contains($0.author?.id ?? UUID())
            }

            months = Self.group(visible, engine: engine)

            // Backfill: offered when yesterday is inside the 48h window and
            // the current user has no deposit there.
            if let target = engine.backfillTargetKey(now: now),
               !all.contains(where: { $0.author?.id == user.id && $0.dayKey == target }) {
                backfillDayKey = target
            } else {
                backfillDayKey = nil
            }
        } catch {
            // Pull-based refresh: keep the last-known archive on a transient
            // failure rather than collapsing to the misleading empty state.
        }
    }

    private static func group(_ deposits: [Deposit], engine: VaultEngine) -> [MonthSection] {
        let byDay = Dictionary(grouping: deposits, by: \.dayKey)
        let days: [DaySection] = byDay.compactMap { key, items in
            guard let date = engine.date(fromDayKey: key) else { return nil }
            return DaySection(
                dayKey: key,
                date: date,
                deposits: items.sorted { $0.createdAt < $1.createdAt }
            )
        }
        .sorted { $0.dayKey > $1.dayKey } // newest first

        let monthFormatter = DateFormatter()
        monthFormatter.calendar = engine.calendar
        monthFormatter.timeZone = engine.calendar.timeZone
        monthFormatter.dateFormat = "MMMM yyyy"

        var order: [String] = []
        var grouped: [String: [DaySection]] = [:]
        for day in days {
            let title = monthFormatter.string(from: day.date)
            if grouped[title] == nil { order.append(title) }
            grouped[title, default: []].append(day)
        }
        return order.map { MonthSection(title: $0, days: grouped[$0] ?? []) }
    }
}

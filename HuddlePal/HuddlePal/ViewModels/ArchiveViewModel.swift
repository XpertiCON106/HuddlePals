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
    let huddle: Huddle
    private(set) var months: [MonthSection] = []
    /// Non-nil when "add to yesterday" should be offered.
    private(set) var backfillDayKey: String?

    init(deps: AppDependencies, huddle: Huddle) {
        self.deps = deps
        self.huddle = huddle
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
            let all = try await deps.depositService.deposits(in: huddle)

            // The gate only applies to today: hide today's section while
            // locked (Home owns the locked presentation), show it once open.
            let unlocked = engine.isUnlocked(
                huddleID: huddle.id,
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

    /// Backfilling can complete yesterday and so restore the streak (what
    /// the recovery window is for): recompute it now, as Home does after a
    /// deposit, instead of at the huddle list's next daily recompute.
    func handleBackfillSuccess() async {
        try? await deps.huddleService.recomputeStreak(for: huddle, now: deps.dateProvider.now)
        await refresh()
        await deps.reminders.refresh()
    }

    private static func group(_ deposits: [Deposit], engine: HuddleEngine) -> [MonthSection] {
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

        // Display only: the user's own calendar and locale (the engine's
        // calendar is always Gregorian, for day keys).
        let monthFormatter = DateFormatter()
        monthFormatter.calendar = Calendar.current
        monthFormatter.timeZone = engine.calendar.timeZone
        monthFormatter.setLocalizedDateFormatFromTemplate("MMMMyyyy")

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

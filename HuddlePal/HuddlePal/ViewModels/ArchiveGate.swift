import Foundation

/// The free plan's 30-day archive window, for the archive and deposit detail.
/// Viewing only: nothing is deleted (the rows and their encrypted files stay,
/// on the device and the server), streaks still count every day, and a
/// locked day is drawn without loading or decrypting anything. Never with
/// Plus.
@MainActor
enum ArchiveGate {
    /// Whether the signed-in account can't open `dayKey` on the free plan.
    /// "Today" is the latest of the device's day, the server's and the day
    /// before the huddle's newest deposit, so setting the phone's clock back
    /// opens nothing.
    static func isLocked(_ dayKey: String, newestDayKey: String?, deps: AppDependencies) -> Bool {
        let plus = deps.plus
        guard !plus.isPremium else { return false }
        let engine = deps.engine
        let today = engine.archiveTodayKey(
            deviceTodayKey: engine.todayKey(now: deps.dateProvider.now),
            serverTodayKey: plus.status.map { engine.dayKey(for: $0.serverNow()) },
            newestDepositDayKey: newestDayKey
        )
        return !engine.isDayUnlockedInArchive(dayKey: dayKey, todayDayKey: today, isPremium: false)
    }
}

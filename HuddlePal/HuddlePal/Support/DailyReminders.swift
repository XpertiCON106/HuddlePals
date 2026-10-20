import Foundation
import Observation
import UserNotifications

// MARK: - Settings

/// Per-user daily upload reminder preference, persisted across launches.
/// Opt-in: nothing is scheduled until the user turns it on (which is when
/// notification permission is requested).
@Observable
final class ReminderSettings {
    private static let enabledKey = "huddlepal.reminder.enabled"
    private static let hourKey = "huddlepal.reminder.hour"
    private static let minuteKey = "huddlepal.reminder.minute"

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }
    var hour: Int {
        didSet { UserDefaults.standard.set(hour, forKey: Self.hourKey) }
    }
    var minute: Int {
        didSet { UserDefaults.standard.set(minute, forKey: Self.minuteKey) }
    }

    init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        hour = defaults.object(forKey: Self.hourKey) as? Int ?? 19
        minute = defaults.object(forKey: Self.minuteKey) as? Int ?? 0
    }
}

// MARK: - Scheduler

/// Schedules the daily upload reminder (and a couple of gentle follow-ups)
/// as local notifications via `UNUserNotificationCenter`. Backend-agnostic
/// — runs identically in mock and live mode, since notification delivery is
/// a device concern, not a data concern.
///
/// Strategy: a rolling window of explicitly-dated, non-repeating
/// notifications for the next several days, fully torn down and rebuilt on
/// each refresh. That lets us (a) suppress *today* once the user has
/// uploaded, while (b) keeping reminders alive for upcoming days even if
/// the app isn't reopened. ~3 notifications/day × 7 days stays well under
/// the iOS 64-pending limit.
final class DailyReminderScheduler {
    /// How many days ahead to keep scheduled.
    static let windowDays = 7
    /// Gentle nudges after the chosen time if still not uploaded (the cap).
    static let followUpCount = 2
    static let followUpGapMinutes = 90

    private let center = UNUserNotificationCenter.current()
    private let identifierPrefix = "huddlepal.daily.reminder."

    private var allIdentifiers: [String] {
        var ids: [String] = []
        for day in 0..<Self.windowDays {
            ids.append("\(identifierPrefix)\(day).main")
            for followUp in 0..<Self.followUpCount {
                ids.append("\(identifierPrefix)\(day).f\(followUp)")
            }
        }
        return ids
    }

    // MARK: Authorization

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// Standard permission request; returns whether reminders may be shown.
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    // MARK: Scheduling

    func cancelAll() {
        center.removePendingNotificationRequests(withIdentifiers: allIdentifiers)
    }

    /// Tears down and rebuilds the rolling window. No-ops (after cancelling)
    /// when disabled, unauthorized, or — for today only — already uploaded.
    func reschedule(
        enabled: Bool,
        hour: Int,
        minute: Int,
        suppressToday: Bool,
        calendar: Calendar,
        now: Date
    ) async {
        cancelAll()
        guard enabled else { return }
        let status = await authorizationStatus()
        guard status == .authorized || status == .provisional else { return }

        for day in 0..<Self.windowDays {
            // Today's nudges are pointless once the user has uploaded.
            if day == 0, suppressToday { continue }
            guard let dayDate = calendar.date(byAdding: .day, value: day, to: now) else { continue }

            schedule(
                id: "\(identifierPrefix)\(day).main",
                title: "Your daily photo is waiting",
                body: "Add today's photo before the day slips away.",
                onDay: dayDate, atMinutes: hour * 60 + minute,
                calendar: calendar
            )

            for followUp in 0..<Self.followUpCount {
                let minutesIntoDay = hour * 60 + minute + Self.followUpGapMinutes * (followUp + 1)
                // A gentle nudge stays within the same day — never spills
                // into the small hours of the next.
                guard minutesIntoDay < 24 * 60 else { break }
                schedule(
                    id: "\(identifierPrefix)\(day).f\(followUp)",
                    title: "Still time today",
                    body: "A quick photo keeps your huddle's streak alive.",
                    onDay: dayDate, atMinutes: minutesIntoDay,
                    calendar: calendar
                )
            }
        }
    }

    private func schedule(
        id: String,
        title: String,
        body: String,
        onDay dayDate: Date,
        atMinutes minutesIntoDay: Int,
        calendar: Calendar
    ) {
        var components = calendar.dateComponents([.year, .month, .day], from: dayDate)
        components.hour = minutesIntoDay / 60
        components.minute = minutesIntoDay % 60

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        // Non-repeating, explicitly dated: iOS silently drops it if the
        // moment is already in the past (e.g. today's main time has passed),
        // which is exactly what we want.
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}

// MARK: - Coordinator

/// Glue between the user's reminder preference, the current upload state,
/// and the scheduler. Refreshed on launch, on app foreground, after a
/// deposit, and whenever the setting changes.
@MainActor
@Observable
final class ReminderCoordinator {
    let settings: ReminderSettings
    private let scheduler: DailyReminderScheduler
    private let session: AppSession
    private let engine: HuddleEngine
    private let dateProvider: DateProviding

    /// Reflects the OS permission state for the UI (e.g. show a "denied"
    /// note). Refreshed by `updateAuthorizationStatus()`.
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    init(
        settings: ReminderSettings,
        scheduler: DailyReminderScheduler,
        session: AppSession,
        engine: HuddleEngine,
        dateProvider: DateProviding
    ) {
        self.settings = settings
        self.scheduler = scheduler
        self.session = session
        self.engine = engine
        self.dateProvider = dateProvider
    }

    var permissionDenied: Bool { authorizationStatus == .denied }

    /// True when there's nothing to nag about: the user has deposited today
    /// in every huddle they belong to (or belongs to none).
    private var hasUploadedEverywhereToday: Bool {
        guard let user = session.currentUser else { return true }
        let huddles = user.memberships.compactMap(\.huddle)
        guard !huddles.isEmpty else { return true }
        let today = engine.todayKey(now: dateProvider.now)
        return huddles.allSatisfy { huddle in
            huddle.deposits.contains { $0.author?.id == user.id && $0.dayKey == today }
        }
    }

    func updateAuthorizationStatus() async {
        authorizationStatus = await scheduler.authorizationStatus()
    }

    /// Turning reminders on requests permission the standard way. Denied →
    /// stays off and the UI surfaces the denial.
    func setEnabled(_ enabled: Bool) async {
        if enabled {
            let granted = await scheduler.requestAuthorization()
            await updateAuthorizationStatus()
            guard granted else {
                settings.isEnabled = false
                return
            }
        }
        settings.isEnabled = enabled
        await refresh()
    }

    func updateTime(hour: Int, minute: Int) async {
        settings.hour = hour
        settings.minute = minute
        await refresh()
    }

    /// Recompute and reschedule. Cheap; safe to call often.
    func refresh() async {
        await updateAuthorizationStatus()
        await scheduler.reschedule(
            enabled: settings.isEnabled,
            hour: settings.hour,
            minute: settings.minute,
            suppressToday: hasUploadedEverywhereToday,
            calendar: engine.calendar,
            now: dateProvider.now
        )
    }
}

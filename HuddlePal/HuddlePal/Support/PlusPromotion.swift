import Foundation
import Observation
import UserNotifications

// MARK: - Settings

/// HuddlePals+ promotion on this device: whether the one-time intro has
/// shown, and whether the person asked to be reminded about it now and then
/// (opt-in, as App Review guideline 4.5.4 asks of promotional notifications)
/// and when the next reminder is due.
@Observable
final class PlusPromoSettings {
    private static let introShownKey = "huddlepal.plusIntro.shown"
    private static let remindersKey = "huddlepal.plusReminders.enabled"
    private static let nextKey = "huddlepal.plusReminders.next"

    @ObservationIgnored private let defaults: UserDefaults

    var introShown: Bool {
        didSet { defaults.set(introShown, forKey: Self.introShownKey) }
    }
    var remindersEnabled: Bool {
        didSet { defaults.set(remindersEnabled, forKey: Self.remindersKey) }
    }
    var nextReminder: Date? {
        didSet { defaults.set(nextReminder, forKey: Self.nextKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        introShown = defaults.bool(forKey: Self.introShownKey)
        remindersEnabled = defaults.bool(forKey: Self.remindersKey)
        nextReminder = defaults.object(forKey: Self.nextKey) as? Date
    }
}

// MARK: - Scheduler

/// What `PlusPromotion` needs from the notification center; a protocol so
/// tests can watch what gets scheduled or cancelled.
protocol PlusReminderScheduling: AnyObject {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async -> Bool
    func schedule(at date: Date, calendar: Calendar)
    func cancel()
}

/// The one pending HuddlePals+ reminder, as a local notification.
final class PlusReminderScheduler: PlusReminderScheduling {
    static let identifier = "huddlepal.plus.reminder"
    static let title = "HuddlePals+"
    static let body = "Post 6-second videos, keep huddles of up to 10, and see every day in your archive."

    private let center = UNUserNotificationCenter.current()

    func authorizationStatus() async -> UNAuthorizationStatus {
        if UITestHooks.notificationsDenied { return .denied }
        return await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization() async -> Bool {
        if UITestHooks.notificationsDenied { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func schedule(at date: Date, calendar: Calendar) {
        let time = calendar.dateComponents([.hour, .minute], from: date)
        let components = DailyReminderScheduler.triggerComponents(
            onDay: date, atMinutes: (time.hour ?? 12) * 60 + (time.minute ?? 0), calendar: calendar
        )
        let content = UNMutableNotificationContent()
        content.title = Self.title
        content.body = Self.body
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        // Same identifier every time: adding it again replaces it.
        center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: trigger))
    }

    func cancel() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
    }
}

// MARK: - Coordinator

/// Introduces HuddlePals+ once, after someone's first post opens a huddle,
/// and, if they asked to be reminded, keeps one reminder pending on a
/// random day two to four weeks out, at a random hour of the day. A new one
/// is picked when the app next opens after the last came due. Nothing is
/// sent once they have Plus, turn it off in Profile, or sign out.
@MainActor
@Observable
final class PlusPromotion {
    /// What MainView shows: the intro, or the paywall a reminder opened.
    enum Sheet: String, Identifiable {
        case intro
        case paywall

        var id: String { rawValue }
    }

    /// Days from one reminder to the next.
    static let gapDays = 14...28
    /// The hours a reminder may come at: 10:00 to 18:59.
    static let hours = 10..<19

    let settings: PlusPromoSettings
    @ObservationIgnored private let scheduler: any PlusReminderScheduling
    @ObservationIgnored private let session: AppSession
    @ObservationIgnored private let plus: any PlusServiceProtocol
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let dateProvider: DateProviding

    var sheet: Sheet?
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    init(
        settings: PlusPromoSettings,
        scheduler: any PlusReminderScheduling,
        session: AppSession,
        plus: any PlusServiceProtocol,
        calendar: Calendar,
        dateProvider: DateProviding
    ) {
        self.settings = settings
        self.scheduler = scheduler
        self.session = session
        self.plus = plus
        self.calendar = calendar
        self.dateProvider = dateProvider
    }

    var permissionDenied: Bool { authorizationStatus == .denied }

    /// A post just opened a huddle (its reveal has played). The first time,
    /// introduce HuddlePals+, unless they already have it. UI tests see the
    /// intro only when they ask for it, so it never covers their next tap.
    func postOpenedHuddle() {
        guard !UITestHooks.isUITesting || UITestHooks.plusIntro else { return }
        guard !settings.introShown, session.currentUser != nil else { return }
        settings.introShown = true
        guard !plus.isPremium else { return }
        sheet = .intro
    }

    /// The reminder was tapped: show what HuddlePals+ adds.
    func reminderTapped() {
        guard session.currentUser != nil, !plus.isPremium else { return }
        sheet = .paywall
    }

    /// "Remind me later" on the intro, or the switch in Profile. Turning it
    /// on asks for notification permission the standard way; refused, it
    /// stays off.
    func setRemindersEnabled(_ enabled: Bool) async {
        if enabled {
            let granted = await scheduler.requestAuthorization()
            await updateAuthorizationStatus()
            guard granted else {
                settings.remindersEnabled = false
                return
            }
        }
        settings.remindersEnabled = enabled
        await refresh()
    }

    func updateAuthorizationStatus() async {
        authorizationStatus = await scheduler.authorizationStatus()
    }

    /// Keeps the next reminder pending, or none. On launch, foreground,
    /// sign-out, when Plus turns on or off, and when the switch changes.
    func refresh() async {
        await updateAuthorizationStatus()
        let allowed = authorizationStatus == .authorized || authorizationStatus == .provisional
        guard settings.remindersEnabled, allowed, session.currentUser != nil, !plus.isPremium else {
            scheduler.cancel()
            return
        }
        let now = dateProvider.now
        let next: Date
        if let pending = settings.nextReminder, pending > now {
            next = pending
        } else {
            var generator = SystemRandomNumberGenerator()
            next = Self.nextReminder(after: now, calendar: calendar, using: &generator)
            settings.nextReminder = next
        }
        scheduler.schedule(at: next, calendar: calendar)
    }

    /// A random day `gapDays` after `now`, at a random minute within `hours`.
    static func nextReminder(
        after now: Date,
        calendar: Calendar,
        using generator: inout some RandomNumberGenerator
    ) -> Date {
        let days = Int.random(in: gapDays, using: &generator)
        let minuteOfDay = Int.random(in: (hours.lowerBound * 60)..<(hours.upperBound * 60), using: &generator)
        let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) ?? now
        return calendar.date(
            bySettingHour: minuteOfDay / 60, minute: minuteOfDay % 60, second: 0, of: day
        ) ?? day
    }
}

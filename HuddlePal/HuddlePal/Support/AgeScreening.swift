import Foundation
import Observation

/// The pre-sign-in age screen. A rejected birthday never leaves the device:
/// only its next eligible UTC date persists, so reopening cannot undo it.
/// An eligible birthday is kept only until the account records it.
@MainActor
@Observable
final class AgeScreening {
    private static let birthdayKey = "huddlepal.age.pendingBirthday"
    private static let retryKey = "huddlepal.age.retryOn"
    private let defaults: UserDefaults?

    private(set) var birthday: Birthday?
    private(set) var retryOn: Birthday?

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        birthday = defaults?.string(forKey: Self.birthdayKey).flatMap(Birthday.init(isoDate:))
        retryOn = defaults?.string(forKey: Self.retryKey).flatMap(Birthday.init(isoDate:))
    }

    func isBlocked(at now: Date = .now) -> Bool {
        guard let retryOn else { return false }
        return Birthday.eligibilityCalendar.startOfDay(for: now) < retryOn.date(in: Birthday.eligibilityCalendar)
    }

    func hasEligibleBirthday(at now: Date = .now) -> Bool {
        !isBlocked(at: now) && birthday?.isOldEnough(on: now, calendar: Birthday.eligibilityCalendar) == true
    }

    @discardableResult
    func submit(_ picked: Birthday, now: Date = .now) -> Bool {
        let calendar = Birthday.eligibilityCalendar
        guard !isBlocked(at: now), picked.isValid,
              picked.date(in: calendar) <= calendar.startOfDay(for: now) else { return false }
        guard picked.isOldEnough(on: now, calendar: Birthday.eligibilityCalendar) else {
            birthday = nil
            defaults?.removeObject(forKey: Self.birthdayKey)
            // Feb 29 becomes March 1 in a non-leap eligibility year, the
            // first day the month/day comparison can say this person is 13.
            guard let date = calendar.date(from: DateComponents(
                year: picked.year + Birthday.minimumAge, month: picked.month, day: picked.day
            )) else { return false }
            retryOn = Birthday(date: date, calendar: calendar)
            defaults?.set(retryOn?.isoDate, forKey: Self.retryKey)
            return false
        }
        retryOn = nil
        birthday = picked
        defaults?.removeObject(forKey: Self.retryKey)
        defaults?.set(picked.isoDate, forKey: Self.birthdayKey)
        return true
    }

    func clearPendingBirthday() {
        birthday = nil
        defaults?.removeObject(forKey: Self.birthdayKey)
    }
}

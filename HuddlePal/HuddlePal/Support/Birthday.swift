import Foundation

/// Someone's birthday, as a calendar date (no time, no time zone, so it
/// never moves a day when the phone's zone does). Only its owner can see it;
/// it's asked for so everyone here meets the Terms' minimum age (2.1).
struct Birthday: Equatable, Hashable {
    let year: Int
    let month: Int
    let day: Int

    /// The Terms' minimum age.
    static let minimumAge = 13
    /// Where the wheel starts before one is chosen.
    static let wheelStart = Birthday(year: 2000, month: 1, day: 1)

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day `date` falls on in `calendar` (the wheel's choice).
    init(date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 2000, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// From a Postgres date, "1996-04-12".
    init?(isoDate: String) {
        let parts = isoDate.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        self.init(year: parts[0], month: parts[1], day: parts[2])
    }

    /// As Postgres writes a date: "1996-04-12".
    var isoDate: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Midnight that day in `calendar`, for the wheel and for formatting.
    func date(in calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .now
    }

    /// Whole years old on `today`'s date in `calendar`.
    func age(on today: Date, calendar: Calendar = .current) -> Int {
        let now = calendar.dateComponents([.year, .month, .day], from: today)
        guard let year = now.year, let month = now.month, let day = now.day else { return 0 }
        let hadBirthdayThisYear = (month, day) >= (self.month, self.day)
        return year - self.year - (hadBirthdayThisYear ? 0 : 1)
    }

    func isOldEnough(on today: Date, calendar: Calendar = .current) -> Bool {
        age(on: today, calendar: calendar) >= Self.minimumAge
    }

    /// "April 12, 1996".
    func formatted(calendar: Calendar = .current) -> String {
        date(in: calendar).formatted(.dateTime.month(.wide).day().year())
    }
}

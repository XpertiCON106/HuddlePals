import Foundation

// MARK: - Value types

/// A pure-value view of a `Deposit`, so the engine never touches SwiftData.
struct DepositSnapshot: Hashable, Sendable {
    let id: UUID
    let vaultID: UUID
    let authorID: UUID
    let dayKey: String
    let createdAt: Date

    init(id: UUID = UUID(), vaultID: UUID, authorID: UUID, dayKey: String, createdAt: Date = .now) {
        self.id = id
        self.vaultID = vaultID
        self.authorID = authorID
        self.dayKey = dayKey
        self.createdAt = createdAt
    }
}

struct StreakResult: Equatable, Sendable {
    let count: Int
    /// Most recent day that counted toward the streak, nil when count == 0.
    let lastCompleteDayKey: String?

    static let zero = StreakResult(count: 0, lastCompleteDayKey: nil)
}

// MARK: - VaultEngine

/// All vault business rules as pure functions: dayKey derivation, the
/// reciprocity gate, group streak math, same-day replacement, and the
/// backfill window. No SwiftData, no UIKit, no singletons — everything is
/// injected so tests can pin the calendar and the clock.
struct VaultEngine {
    static let captionLimit = 80
    static let backfillWindow: TimeInterval = 48 * 60 * 60
    static let defaultSkipTokens = 2

    let calendar: Calendar
    private let formatter: DateFormatter

    init(calendar: Calendar = .current) {
        self.calendar = calendar
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        self.formatter = formatter
    }

    // MARK: Day keys

    /// "yyyy-MM-dd" in the engine's (device) timezone. Lexicographic order
    /// of keys matches chronological order.
    func dayKey(for date: Date) -> String {
        formatter.string(from: date)
    }

    /// Start of the day a key represents.
    func date(fromDayKey key: String) -> Date? {
        guard let parsed = formatter.date(from: key) else { return nil }
        return calendar.startOfDay(for: parsed)
    }

    func dayKey(byAdding days: Int, to key: String) -> String? {
        guard let base = date(fromDayKey: key),
              let shifted = calendar.date(byAdding: .day, value: days, to: base)
        else { return nil }
        return dayKey(for: shifted)
    }

    func todayKey(now: Date) -> String {
        dayKey(for: now)
    }

    func yesterdayKey(now: Date) -> String? {
        dayKey(byAdding: -1, to: todayKey(now: now))
    }

    // MARK: Reciprocity gate

    /// The vault is unlocked for today iff the current user has deposited
    /// today. Previous days are always visible — the gate only ever applies
    /// to today's deposits.
    func isUnlocked(vaultID: UUID, currentUserID: UUID, deposits: [DepositSnapshot], now: Date) -> Bool {
        let today = todayKey(now: now)
        return deposits.contains {
            $0.vaultID == vaultID && $0.authorID == currentUserID && $0.dayKey == today
        }
    }

    // MARK: Same-day replacement

    /// One deposit per user per vault per dayKey: applying a new deposit
    /// replaces any existing one for the same (vault, author, dayKey).
    /// Returns the new set plus the id of the replaced deposit, if any.
    func applying(
        _ new: DepositSnapshot,
        to deposits: [DepositSnapshot]
    ) -> (deposits: [DepositSnapshot], replacedID: UUID?) {
        let existing = deposits.first {
            $0.id != new.id
                && $0.vaultID == new.vaultID
                && $0.authorID == new.authorID
                && $0.dayKey == new.dayKey
        }
        var result = deposits.filter { $0.id != existing?.id }
        result.append(new)
        return (result, existing?.id)
    }

    // MARK: Streaks

    /// A day is complete when every current member either deposited or
    /// spent a skip token for that dayKey.
    func isDayComplete(
        dayKey key: String,
        memberIDs: Set<UUID>,
        deposits: [DepositSnapshot],
        skips: [String: Set<UUID>] = [:]
    ) -> Bool {
        guard !memberIDs.isEmpty else { return false }
        let covered = Set(deposits.lazy.filter { $0.dayKey == key }.map(\.authorID))
            .union(skips[key] ?? [])
        return memberIDs.subtracting(covered).isEmpty
    }

    /// Consecutive complete days ending at today (if today is already
    /// complete) or yesterday (today is still in progress, so an incomplete
    /// today never breaks the streak). An incomplete *ended* day resets to 0.
    func computeStreak(
        memberIDs: Set<UUID>,
        deposits: [DepositSnapshot],
        skips: [String: Set<UUID>] = [:],
        now: Date
    ) -> StreakResult {
        let today = todayKey(now: now)
        var cursor: String
        if isDayComplete(dayKey: today, memberIDs: memberIDs, deposits: deposits, skips: skips) {
            cursor = today
        } else if let yesterday = yesterdayKey(now: now) {
            cursor = yesterday
        } else {
            return .zero
        }

        var count = 0
        var lastComplete: String?
        // Hard cap guards against a malformed calendar looping forever.
        while count < 36_500,
              isDayComplete(dayKey: cursor, memberIDs: memberIDs, deposits: deposits, skips: skips) {
            count += 1
            if lastComplete == nil { lastComplete = cursor }
            guard let previous = dayKey(byAdding: -1, to: cursor) else { break }
            cursor = previous
        }
        return StreakResult(count: count, lastCompleteDayKey: lastComplete)
    }

    // MARK: Backfill

    /// A deposit may be created for a *past* dayKey within 48 hours of that
    /// day's start — in practice, "yesterday". Today is a normal deposit,
    /// not a backfill.
    ///
    /// TODO: BACKEND — backfill does not retroactively repair a broken
    /// streak in MVP. Streak repair needs a server-side recompute over the
    /// full deposit history once deposits sync.
    func canBackfill(dayKey key: String, now: Date) -> Bool {
        let today = todayKey(now: now)
        guard key < today else { return false }
        guard let dayStart = date(fromDayKey: key) else { return false }
        return now.timeIntervalSince(dayStart) < Self.backfillWindow
    }

    /// The dayKey backfill currently targets (yesterday), or nil if the
    /// window has closed.
    func backfillTargetKey(now: Date) -> String? {
        guard let yesterday = yesterdayKey(now: now),
              canBackfill(dayKey: yesterday, now: now) else { return nil }
        return yesterday
    }

    // MARK: Captions & invite codes

    /// Trims whitespace, enforces the 80-character cap, returns nil for
    /// empty input.
    static func sanitizedCaption(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(captionLimit))
    }

    /// 6-char alphanumeric code; ambiguous glyphs (0/O, 1/I/L) excluded.
    static func generateInviteCode(length: Int = 6) -> String {
        let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
        return String((0..<length).compactMap { _ in alphabet.randomElement() })
    }
}

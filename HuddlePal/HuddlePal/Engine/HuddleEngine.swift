import Foundation

// MARK: - Value types

/// A pure-value view of a `Deposit`, so the engine never touches SwiftData.
struct DepositSnapshot: Hashable, Sendable {
    let id: UUID
    let huddleID: UUID
    let authorID: UUID
    let dayKey: String
    let createdAt: Date

    init(id: UUID = UUID(), huddleID: UUID, authorID: UUID, dayKey: String, createdAt: Date = .now) {
        self.id = id
        self.huddleID = huddleID
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

// MARK: - HuddleEngine

/// All huddle business rules as pure functions: dayKey derivation, the
/// reciprocity gate, group streak math, once-and-permanent deposits,
/// the recovery window, and backfill. No SwiftData, no UIKit, no singletons — everything is
/// injected so tests can pin the calendar and the clock.
struct HuddleEngine {
    static let captionLimit = 80
    static let backfillWindow: TimeInterval = 48 * 60 * 60
    static let defaultSkipTokens = 2

    let calendar: Calendar
    private let formatter: DateFormatter

    /// Only the time zone is taken from `calendar`. Day keys are always
    /// Gregorian ("2026-10-21"), whatever calendar the user picked in
    /// Settings, because the server checks them against its own dates: with
    /// the Buddhist calendar (Thailand's default) "yyyy" would print 2569.
    /// Every calendar Foundation offers starts its days at midnight, so day
    /// boundaries are unchanged.
    init(calendar: Calendar = .current) {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        self.calendar = gregorian
        let formatter = DateFormatter()
        formatter.calendar = gregorian
        formatter.timeZone = gregorian.timeZone
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

    /// The huddle is unlocked for today iff the current user has deposited
    /// today. Previous days are always visible — the gate only ever applies
    /// to today's deposits.
    func isUnlocked(huddleID: UUID, currentUserID: UUID, deposits: [DepositSnapshot], now: Date) -> Bool {
        let today = todayKey(now: now)
        return deposits.contains {
            $0.huddleID == huddleID && $0.authorID == currentUserID && $0.dayKey == today
        }
    }

    // MARK: Permanence

    /// Once-and-permanent: exactly one deposit per member per huddle per
    /// day, no retakes, no redos. Services must refuse a second deposit
    /// for a dayKey this returns true for.
    func hasDeposit(
        huddleID: UUID,
        authorID: UUID,
        dayKey key: String,
        in deposits: [DepositSnapshot]
    ) -> Bool {
        deposits.contains {
            $0.huddleID == huddleID && $0.authorID == authorID && $0.dayKey == key
        }
    }

    // MARK: Streaks

    /// The members a day waits on: current members who joined *before* it.
    /// A member's join day is free — they may post, but the group's day
    /// doesn't depend on them — so joining never breaks a streak. Members
    /// missing from `joinedDayKeys` count on every day.
    func requiredMembers(
        on key: String,
        memberIDs: Set<UUID>,
        joinedDayKeys: [UUID: String] = [:]
    ) -> Set<UUID> {
        memberIDs.filter { id in
            guard let joined = joinedDayKeys[id] else { return true }
            return key > joined
        }
    }

    /// A day is complete when every member it waits on (see
    /// `requiredMembers`) either deposited or spent a skip token for that
    /// dayKey. A day that waits on nobody is never complete.
    func isDayComplete(
        dayKey key: String,
        memberIDs: Set<UUID>,
        joinedDayKeys: [UUID: String] = [:],
        deposits: [DepositSnapshot],
        skips: [String: Set<UUID>] = [:]
    ) -> Bool {
        let required = requiredMembers(on: key, memberIDs: memberIDs, joinedDayKeys: joinedDayKeys)
        guard !required.isEmpty else { return false }
        let covered = Set(deposits.lazy.filter { $0.dayKey == key }.map(\.authorID))
            .union(skips[key] ?? [])
        return required.subtracting(covered).isEmpty
    }

    /// Consecutive complete days ending at today (if today is already
    /// complete) or yesterday (today is still in progress, so an incomplete
    /// today never breaks the streak). An incomplete *ended* day resets to 0.
    func computeStreak(
        memberIDs: Set<UUID>,
        joinedDayKeys: [UUID: String] = [:],
        deposits: [DepositSnapshot],
        skips: [String: Set<UUID>] = [:],
        now: Date
    ) -> StreakResult {
        func complete(_ key: String) -> Bool {
            isDayComplete(
                dayKey: key, memberIDs: memberIDs, joinedDayKeys: joinedDayKeys,
                deposits: deposits, skips: skips
            )
        }
        let today = todayKey(now: now)
        var cursor: String
        if complete(today) {
            cursor = today
        } else if let yesterday = yesterdayKey(now: now) {
            cursor = yesterday
        } else {
            return .zero
        }

        var count = 0
        var lastComplete: String?
        // Hard cap guards against a malformed calendar looping forever.
        while count < 36_500, complete(cursor) {
            count += 1
            if lastComplete == nil { lastComplete = cursor }
            guard let previous = dayKey(byAdding: -1, to: cursor) else { break }
            cursor = previous
        }
        return StreakResult(count: count, lastCompleteDayKey: lastComplete)
    }

    // MARK: Recovery window

    /// A broken-but-recoverable streak. Exists from the moment a day ends
    /// incomplete until 24h later (== the backfill deadline for that day):
    /// if the missing members backfill within the window, the streak is
    /// restored by the normal full-history recompute; when the window
    /// expires, backfill becomes impossible and the reset is permanent.
    struct StreakRecovery: Equatable, Sendable {
        let brokenDayKey: String
        let missingMemberIDs: Set<UUID>
        /// When the window closes (brokenDay start + 48h).
        let deadline: Date
        /// What the streak becomes if recovery succeeds right now.
        let recoverableStreak: Int

        /// A recovery computed earlier can outlive its window (the app stays
        /// open past midnight): it only counts while `now < deadline`.
        func isOpen(at now: Date) -> Bool {
            now < deadline
        }

        /// The countdown's range. Never reversed: a `ClosedRange` whose lower
        /// bound passed its upper bound traps, which crashed the Home screen
        /// when a banner was still showing after its deadline.
        func countdown(from now: Date) -> ClosedRange<Date> {
            now...max(now, deadline)
        }
    }

    /// Non-nil while yesterday ended incomplete, the window is still open,
    /// and there is actually a streak worth restoring.
    func recovery(
        memberIDs: Set<UUID>,
        joinedDayKeys: [UUID: String] = [:],
        deposits: [DepositSnapshot],
        skips: [String: Set<UUID>] = [:],
        now: Date
    ) -> StreakRecovery? {
        guard let brokenKey = yesterdayKey(now: now),
              !isDayComplete(
                  dayKey: brokenKey, memberIDs: memberIDs, joinedDayKeys: joinedDayKeys,
                  deposits: deposits, skips: skips
              ),
              let dayStart = date(fromDayKey: brokenKey)
        else { return nil }
        let deadline = dayStart.addingTimeInterval(Self.backfillWindow)
        guard now < deadline else { return nil }

        let covered = Set(deposits.lazy.filter { $0.dayKey == brokenKey }.map(\.authorID))
            .union(skips[brokenKey] ?? [])
        // Only members that day waited on can be "missing" from it.
        let missing = requiredMembers(on: brokenKey, memberIDs: memberIDs, joinedDayKeys: joinedDayKeys)
            .subtracting(covered)
        guard !missing.isEmpty else { return nil }

        // Streak as if the broken day were covered — only meaningful when
        // the patched chain extends beyond the broken day itself.
        var patched = skips
        patched[brokenKey, default: []].formUnion(missing)
        let restored = computeStreak(
            memberIDs: memberIDs, joinedDayKeys: joinedDayKeys,
            deposits: deposits, skips: patched, now: now
        ).count
        guard restored >= 2 else { return nil }

        return StreakRecovery(
            brokenDayKey: brokenKey,
            missingMemberIDs: missing,
            deadline: deadline,
            recoverableStreak: restored
        )
    }

    // MARK: Backfill

    /// A deposit may be created for a *past* dayKey within 48 hours of that
    /// day's start — in practice, "yesterday". Today is a normal deposit,
    /// not a backfill. There is no separate repair step: the next
    /// full-history recompute sees the backfilled day, which is how the
    /// recovery window restores a broken streak.
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

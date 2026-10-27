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

    // MARK: Archive window

    /// Whether the archive opens a day: always with Plus; on the free plan,
    /// `todayDayKey` and the 29 days before it. Later days open too: a member
    /// east of you posts under a day key ahead of your today. Older days stay
    /// in the archive, locked — nothing is ever deleted — and streaks always
    /// count the whole history.
    func isDayUnlockedInArchive(dayKey key: String, todayDayKey: String, isPremium: Bool) -> Bool {
        if isPremium { return true }
        guard let oldest = dayKey(byAdding: -(HuddleLimits.freeArchiveDays - 1), to: todayDayKey) else {
            return false
        }
        return key >= oldest
    }

    /// The "today" the archive window counts back from: the latest of the
    /// device's day, the server's (from its clock, when known), and the day
    /// before the newest deposit (a member east of you can be a day ahead).
    /// Setting the phone's clock back then opens no older day.
    func archiveTodayKey(deviceTodayKey: String, serverTodayKey: String?, newestDepositDayKey: String?) -> String {
        let candidates = [
            deviceTodayKey,
            serverTodayKey,
            newestDepositDayKey.flatMap { dayKey(byAdding: -1, to: $0) },
        ]
        return candidates.compactMap { $0 }.max() ?? deviceTodayKey
    }

    // MARK: Huddle limits

    /// Why a huddle refuses one more member. Each raw value is the error the
    /// server raises for it (huddle_join_rule, migration 013).
    enum JoinRefusal: String, CaseIterable, Sendable {
        /// Before the free limits start: 8 members, as always.
        case full = "huddle_full"
        /// The keeper is on the free plan: 4 members.
        case freeLimit = "join_blocked_free_limit"
        /// The keeper is on the free plan and this isn't one of the 3
        /// huddles they've kept longest.
        case invitesPaused = "join_blocked_invites_paused"
        /// The keeper has Plus: 10 members, the most a huddle can have.
        case maxMembers = "join_blocked_max_members"
        /// The joiner is already in 25 huddles.
        case membershipLimit = "join_blocked_membership_limit"
    }

    /// How many members a huddle takes and why it refuses one more, if it
    /// does: the server's huddle_join_rule. `keeperRank` is the huddle's
    /// place (0 for the longest kept) among its keeper's huddles, nil when
    /// it has no keeper.
    static func joinRule(
        memberCount: Int,
        keeperIsPremium: Bool,
        keeperRank: Int?,
        limitsActive: Bool
    ) -> (memberCap: Int, refusal: JoinRefusal?) {
        guard limitsActive else {
            let cap = HuddleLimits.legacyMembers
            return (cap, memberCount >= cap ? .full : nil)
        }
        if keeperRank != nil, keeperIsPremium {
            let cap = HuddleLimits.plusMembers
            return (cap, memberCount >= cap ? .maxMembers : nil)
        }
        let cap = HuddleLimits.freeMembers
        guard let keeperRank, keeperRank < HuddleLimits.freeHuddlesKept else { return (cap, .invitesPaused) }
        return (cap, memberCount >= cap ? .freeLimit : nil)
    }

    /// Whether someone in `joinerHuddleCount` huddles may join this one, in
    /// the server's order: their own limit first, then the huddle's rule.
    static func joinRefusal(
        memberCount: Int,
        keeperIsPremium: Bool,
        keeperRank: Int?,
        joinerHuddleCount: Int,
        limitsActive: Bool
    ) -> JoinRefusal? {
        if limitsActive, joinerHuddleCount >= HuddleLimits.huddlesJoined { return .membershipLimit }
        return joinRule(
            memberCount: memberCount, keeperIsPremium: keeperIsPremium,
            keeperRank: keeperRank, limitsActive: limitsActive
        ).refusal
    }

    /// A huddle's place in its keeper's queue: their huddles ordered by when
    /// they became keeper (then by id, as the server breaks ties), so one
    /// they inherit goes to the back. Nil when they don't keep it.
    static func keeperRank(of huddleID: UUID, among kept: [(huddleID: UUID, keeperSince: Date)]) -> Int? {
        kept.sorted {
            $0.keeperSince != $1.keeperSince
                ? $0.keeperSince < $1.keeperSince
                : $0.huddleID.uuidString.lowercased() < $1.huddleID.uuidString.lowercased()
        }
        .firstIndex { $0.huddleID == huddleID }
    }

    /// Why an account can't create another huddle. Raw values are the
    /// errors create_huddle raises.
    enum CreateRefusal: String, CaseIterable, Sendable {
        case freeLimit = "huddle_limit_reached_free"
        case plusLimit = "huddle_limit_reached_premium"
    }

    /// create_huddle's cap: huddles kept, inherited ones included.
    static func createRefusal(keptHuddles: Int, isPremium: Bool, limitsActive: Bool) -> CreateRefusal? {
        guard limitsActive else { return nil }
        if isPremium { return keptHuddles >= HuddleLimits.plusHuddlesKept ? .plusLimit : nil }
        return keptHuddles >= HuddleLimits.freeHuddlesKept ? .freeLimit : nil
    }

    // MARK: Captions

    /// Trims whitespace, enforces the 80-character cap, returns nil for
    /// empty input.
    static func sanitizedCaption(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.prefix(serverLength: captionLimit)
    }
}

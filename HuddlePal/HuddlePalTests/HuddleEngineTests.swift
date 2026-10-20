import XCTest
@testable import HuddlePal

/// Pure-logic tests for `HuddleEngine`. The calendar and clock are pinned so
/// every assertion is deterministic regardless of where CI runs.
final class HuddleEngineTests: XCTestCase {
    private var calendar: Calendar!
    private var engine: HuddleEngine!

    private let huddleID = UUID()
    private let alice = UUID()
    private let bob = UUID()
    private let cleo = UUID()
    private var members: Set<UUID> { [alice, bob, cleo] }
    /// Joins mid-streak in the "Joining" tests; never in `members`.
    private let dana = UUID()

    override func setUp() {
        super.setUp()
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        engine = HuddleEngine(calendar: calendar)
    }

    // MARK: Helpers

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func deposit(_ author: UUID, _ dayKey: String) -> DepositSnapshot {
        DepositSnapshot(huddleID: huddleID, authorID: author, dayKey: dayKey, createdAt: .now)
    }

    /// Deposits for every member on each day offset (relative to `now`),
    /// except the listed absentees.
    private func fullDays(
        offsets: ClosedRange<Int>,
        now: Date,
        absent: [Int: UUID] = [:]
    ) -> [DepositSnapshot] {
        var result: [DepositSnapshot] = []
        let today = engine.todayKey(now: now)
        for offset in offsets {
            guard let key = engine.dayKey(byAdding: offset, to: today) else { continue }
            for member in members where absent[offset] != member {
                result.append(deposit(member, key))
            }
        }
        return result
    }

    // MARK: 1. Perfect-day increment

    func testPerfectDayIncrementsStreak() {
        let now = date(2026, 6, 10)
        // Three perfect days ending today.
        let deposits = fullDays(offsets: -2...0, now: now)
        let streak = engine.computeStreak(memberIDs: members, deposits: deposits, now: now)
        XCTAssertEqual(streak.count, 3)
        XCTAssertEqual(streak.lastCompleteDayKey, "2026-06-10")

        // One more member-complete day on top increments again.
        let tomorrow = date(2026, 6, 11)
        let extended = deposits + members.map { deposit($0, "2026-06-11") }
        XCTAssertEqual(
            engine.computeStreak(memberIDs: members, deposits: extended, now: tomorrow).count,
            4
        )
    }

    // MARK: 2. Missing-member reset

    func testMissingMemberResetsStreak() {
        let now = date(2026, 6, 10)
        // Days -3..-2 perfect, but cleo missed yesterday and spent no token.
        let deposits = fullDays(offsets: -3...(-1), now: now, absent: [-1: cleo])
        let streak = engine.computeStreak(memberIDs: members, deposits: deposits, now: now)
        XCTAssertEqual(streak.count, 0, "an ended day with a missing member resets the streak")
        XCTAssertNil(streak.lastCompleteDayKey)
    }

    func testIncompleteTodayDoesNotResetStreak() {
        let now = date(2026, 6, 10)
        var deposits = fullDays(offsets: -2...(-1), now: now)
        deposits.append(deposit(alice, "2026-06-10")) // today still in progress
        let streak = engine.computeStreak(memberIDs: members, deposits: deposits, now: now)
        XCTAssertEqual(streak.count, 2, "today hasn't ended, so it can't break the streak")
        XCTAssertEqual(streak.lastCompleteDayKey, "2026-06-09")
    }

    // MARK: 3. Skip-token preservation

    func testSkipTokenPreservesStreak() {
        let now = date(2026, 6, 10)
        // cleo missed yesterday but a skip token was spent for her.
        let deposits = fullDays(offsets: -3...(-1), now: now, absent: [-1: cleo])
        let skips: [String: Set<UUID>] = ["2026-06-09": [cleo]]
        let streak = engine.computeStreak(memberIDs: members, deposits: deposits, skips: skips, now: now)
        XCTAssertEqual(streak.count, 3, "a spent skip token counts as deposited")
        XCTAssertEqual(streak.lastCompleteDayKey, "2026-06-09")
    }

    // MARK: 4. Once and permanent

    func testOnceAndPermanent() {
        let key = "2026-06-10"
        let existing = [deposit(alice, key), deposit(bob, key)]

        // The services consult this before any insert: a second deposit for
        // the same (huddle, author, day) must be refused.
        XCTAssertTrue(
            engine.hasDeposit(huddleID: huddleID, authorID: alice, dayKey: key, in: existing)
        )
        XCTAssertFalse(
            engine.hasDeposit(huddleID: huddleID, authorID: cleo, dayKey: key, in: existing),
            "a member who hasn't posted is free to"
        )
        XCTAssertFalse(
            engine.hasDeposit(huddleID: huddleID, authorID: alice, dayKey: "2026-06-11", in: existing),
            "a new day is always open"
        )
        XCTAssertFalse(
            engine.hasDeposit(huddleID: UUID(), authorID: alice, dayKey: key, in: existing),
            "per-huddle: the same day in another huddle is independent"
        )
    }

    // MARK: Recovery window

    func testRecoveryWindowOpensWhenStreakBreaks() {
        // Streak through -3..-2, cleo missed yesterday (-1), today is the
        // recovery window.
        let now = date(2026, 6, 10, 9, 0)
        let deposits = fullDays(offsets: -3...(-1), now: now, absent: [-1: cleo])

        let recovery = engine.recovery(memberIDs: members, deposits: deposits, now: now)
        XCTAssertNotNil(recovery)
        XCTAssertEqual(recovery?.brokenDayKey, "2026-06-09")
        XCTAssertEqual(recovery?.missingMemberIDs, [cleo])
        XCTAssertEqual(
            recovery?.recoverableStreak, 3,
            "restoring yesterday revives the 2-day chain plus yesterday itself"
        )
        // Deadline is the end of the recovery day: brokenDay start + 48h.
        XCTAssertEqual(
            recovery?.deadline,
            engine.date(fromDayKey: "2026-06-09")?.addingTimeInterval(48 * 3600)
        )
        // While the window is open the streak itself reads 0 — broken until
        // recovered.
        XCTAssertEqual(engine.computeStreak(memberIDs: members, deposits: deposits, now: now).count, 0)
    }

    func testRecoverySucceedsWithinWindow() {
        let now = date(2026, 6, 10, 9, 0)
        var deposits = fullDays(offsets: -3...(-1), now: now, absent: [-1: cleo])
        // cleo backfills the broken day inside the window…
        deposits.append(deposit(cleo, "2026-06-09"))
        XCTAssertNil(
            engine.recovery(memberIDs: members, deposits: deposits, now: now),
            "no recovery banner once the day is complete again"
        )
        // …and the full-history recompute restores the streak.
        XCTAssertEqual(engine.computeStreak(memberIDs: members, deposits: deposits, now: now).count, 3)
        XCTAssertTrue(engine.canBackfill(dayKey: "2026-06-09", now: now), "the fix is a legal backfill")
    }

    func testRecoveryWindowExpiresPermanently() {
        // Two days later: the window for 2026-06-09 has closed.
        let later = date(2026, 6, 11, 9, 0)
        let deposits = fullDays(offsets: -4...(-2), now: later, absent: [-2: cleo])
        XCTAssertNil(engine.recovery(memberIDs: members, deposits: deposits, now: later))
        XCTAssertFalse(
            engine.canBackfill(dayKey: "2026-06-09", now: later),
            "after expiry the broken day can never be filled — the reset is permanent"
        )
    }

    func testNoRecoveryWithoutAPriorStreak() {
        // Only yesterday exists and it's incomplete — nothing to restore.
        let now = date(2026, 6, 10, 9, 0)
        let deposits = fullDays(offsets: -1...(-1), now: now, absent: [-1: cleo])
        XCTAssertNil(engine.recovery(memberIDs: members, deposits: deposits, now: now))
    }

    // MARK: Joining — members count from the day after they join

    func testJoiningDoesNotResetTheStreak() {
        let now = date(2026, 6, 10, 9, 0)
        let deposits = fullDays(offsets: -5...(-1), now: now)
        let everyone = members.union([dana])
        let joined = [dana: "2026-06-10"]

        XCTAssertEqual(engine.computeStreak(memberIDs: members, deposits: deposits, now: now).count, 5)
        XCTAssertEqual(
            engine.computeStreak(memberIDs: everyone, joinedDayKeys: joined, deposits: deposits, now: now).count, 5,
            "a member who joined today owes no earlier day"
        )
        XCTAssertNil(
            engine.recovery(memberIDs: everyone, joinedDayKeys: joined, deposits: deposits, now: now),
            "and no recovery banner blames them for one"
        )
    }

    func testJoinDayIsFreeAndTheNextDayCounts() {
        let everyone = members.union([dana])
        let joined = [dana: "2026-06-10"]

        // The originals post 06-08 … 06-10; Dana skips her join day (06-10).
        let nextDay = date(2026, 6, 11, 9, 0)
        let deposits = fullDays(offsets: -3...(-1), now: nextDay)
        XCTAssertEqual(
            engine.computeStreak(memberIDs: everyone, joinedDayKeys: joined, deposits: deposits, now: nextDay).count, 3,
            "the join day completes without the newcomer"
        )

        // 06-11 ends with everyone but Dana: from here she counts, so it breaks.
        let dayAfter = date(2026, 6, 12, 9, 0)
        let more = deposits + fullDays(offsets: -1...(-1), now: dayAfter)
        XCTAssertEqual(
            engine.computeStreak(memberIDs: everyone, joinedDayKeys: joined, deposits: more, now: dayAfter).count, 0
        )
        let recovery = engine.recovery(memberIDs: everyone, joinedDayKeys: joined, deposits: more, now: dayAfter)
        XCTAssertEqual(recovery?.missingMemberIDs, [dana])
        XCTAssertEqual(recovery?.recoverableStreak, 4, "her backfill would restore 06-08 … 06-11")
    }

    func testRecoveryNeverBlamesSomeoneForTheirJoinDay() {
        // Cleo missed yesterday — the same day Dana joined. Only Cleo is missing.
        let now = date(2026, 6, 10, 9, 0)
        let deposits = fullDays(offsets: -3...(-1), now: now, absent: [-1: cleo])
        let recovery = engine.recovery(
            memberIDs: members.union([dana]), joinedDayKeys: [dana: "2026-06-09"],
            deposits: deposits, now: now
        )
        XCTAssertEqual(recovery?.missingMemberIDs, [cleo])
    }

    func testANewHuddlesFirstCountingDayIsTheDayAfterCreation() {
        // Everyone joined on creation day, so that day waits on no one.
        let joined = Dictionary(uniqueKeysWithValues: members.map { ($0, "2026-06-10") })
        let creationEvening = date(2026, 6, 10, 20, 0)
        let deposits = fullDays(offsets: 0...0, now: creationEvening)
        XCTAssertEqual(
            engine.computeStreak(memberIDs: members, joinedDayKeys: joined, deposits: deposits, now: creationEvening).count, 0
        )

        let nextEvening = date(2026, 6, 11, 20, 0)
        let more = deposits + fullDays(offsets: 0...0, now: nextEvening)
        XCTAssertEqual(
            engine.computeStreak(memberIDs: members, joinedDayKeys: joined, deposits: more, now: nextEvening).count, 1
        )
    }

    // MARK: 5. dayKey boundary behavior

    func testDayKeyBoundaryBehavior() {
        let lateNight = date(2026, 6, 9, 23, 59)
        let justPastMidnight = date(2026, 6, 10, 0, 1)

        XCTAssertEqual(engine.dayKey(for: lateNight), "2026-06-09")
        XCTAssertEqual(engine.dayKey(for: justPastMidnight), "2026-06-10")

        // A 23:59 deposit satisfies the gate for its day…
        let deposits = [deposit(alice, "2026-06-09")]
        XCTAssertTrue(
            engine.isUnlocked(huddleID: huddleID, currentUserID: alice, deposits: deposits, now: lateNight)
        )
        // …and two minutes later the huddle is locked again for the new day.
        XCTAssertFalse(
            engine.isUnlocked(huddleID: huddleID, currentUserID: alice, deposits: deposits, now: justPastMidnight)
        )
    }

    // MARK: 6. Backfill creation

    func testBackfillWindow() {
        let now = date(2026, 6, 10, 18, 0)

        XCTAssertTrue(engine.canBackfill(dayKey: "2026-06-09", now: now), "yesterday is within 48h of its day start")
        XCTAssertFalse(engine.canBackfill(dayKey: "2026-06-08", now: now), "two days back is outside the window")
        XCTAssertFalse(engine.canBackfill(dayKey: "2026-06-10", now: now), "today is a normal deposit, not a backfill")
        XCTAssertFalse(engine.canBackfill(dayKey: "2026-06-11", now: now), "future days can never be backfilled")
        XCTAssertEqual(engine.backfillTargetKey(now: now), "2026-06-09")
    }

    func testBackfillRepairsBrokenStreakOnRecompute() {
        let now = date(2026, 6, 10)
        var deposits = fullDays(offsets: -3...(-1), now: now, absent: [-1: cleo])
        let broken = engine.computeStreak(memberIDs: members, deposits: deposits, now: now)
        XCTAssertEqual(broken.count, 0)

        // cleo backfills yesterday. The day is now complete, so the next
        // recompute picks it up — there is no separate repair step.
        deposits.append(deposit(cleo, "2026-06-09"))
        let recomputed = engine.computeStreak(memberIDs: members, deposits: deposits, now: now)
        XCTAssertEqual(recomputed.count, 3, "recompute over full history sees the backfilled day")
    }

    // MARK: Reciprocity gate

    func testGateRequiresOwnDepositToday() {
        let now = date(2026, 6, 10)
        let today = engine.todayKey(now: now)

        XCTAssertFalse(
            engine.isUnlocked(
                huddleID: huddleID,
                currentUserID: alice,
                deposits: [deposit(bob, today), deposit(cleo, today)],
                now: now
            ),
            "everyone else's deposits never unlock your huddle"
        )
        XCTAssertTrue(
            engine.isUnlocked(
                huddleID: huddleID,
                currentUserID: alice,
                deposits: [deposit(alice, today)],
                now: now
            )
        )
        XCTAssertFalse(
            engine.isUnlocked(
                huddleID: huddleID,
                currentUserID: alice,
                deposits: [deposit(alice, "2026-06-09")],
                now: now
            ),
            "yesterday's deposit doesn't open today"
        )
    }

    // MARK: Captions & invite codes

    func testCaptionSanitization() {
        XCTAssertNil(HuddleEngine.sanitizedCaption(nil))
        XCTAssertNil(HuddleEngine.sanitizedCaption("   \n "))
        XCTAssertEqual(HuddleEngine.sanitizedCaption("  hello  "), "hello")
        XCTAssertEqual(
            HuddleEngine.sanitizedCaption(String(repeating: "x", count: 200))?.count,
            HuddleEngine.captionLimit
        )
    }

    func testInviteCodeShape() {
        for _ in 0..<20 {
            let code = HuddleEngine.generateInviteCode()
            XCTAssertEqual(code.count, 6)
            XCTAssertTrue(code.allSatisfy { $0.isLetter || $0.isNumber })
        }
    }

    // MARK: Identity color tokens

    /// Solid tokens are one color; "hex-hex" gradient tokens resolve to two.
    /// `AvatarStyle.base(for:)` must return the first component for both —
    /// it's what tints the locked card, where a plain `Color(hex:)` would
    /// fall back to gray for gradient tokens.
    func testAvatarStyleResolvesGradientTokens() {
        XCTAssertEqual(AvatarStyle.components(of: "E5484D").count, 1)
        XCTAssertEqual(AvatarStyle.components(of: "F76B15-E5484D").count, 2)
        // Malformed input still yields a usable single color (no crash).
        XCTAssertEqual(AvatarStyle.components(of: "").count, 1)
    }
}

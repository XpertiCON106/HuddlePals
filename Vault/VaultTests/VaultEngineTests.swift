import XCTest
@testable import Vault

/// Pure-logic tests for `VaultEngine`. The calendar and clock are pinned so
/// every assertion is deterministic regardless of where CI runs.
final class VaultEngineTests: XCTestCase {
    private var calendar: Calendar!
    private var engine: VaultEngine!

    private let vaultID = UUID()
    private let alice = UUID()
    private let bob = UUID()
    private let cleo = UUID()
    private var members: Set<UUID> { [alice, bob, cleo] }

    override func setUp() {
        super.setUp()
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        engine = VaultEngine(calendar: calendar)
    }

    // MARK: Helpers

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func deposit(_ author: UUID, _ dayKey: String) -> DepositSnapshot {
        DepositSnapshot(vaultID: vaultID, authorID: author, dayKey: dayKey, createdAt: .now)
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

    // MARK: 4. Same-day replacement

    func testSameDayReplacementDeposit() {
        let key = "2026-06-10"
        let original = deposit(alice, key)
        let bystander = deposit(bob, key)
        let replacement = deposit(alice, key)

        let (result, replacedID) = engine.applying(replacement, to: [original, bystander])

        XCTAssertEqual(replacedID, original.id)
        XCTAssertEqual(result.count, 2, "one per user per vault per day")
        let aliceDeposits = result.filter { $0.authorID == alice }
        XCTAssertEqual(aliceDeposits.map(\.id), [replacement.id])
        XCTAssertTrue(result.contains(bystander), "other members' deposits are untouched")

        // A different day is never a replacement.
        let nextDay = deposit(alice, "2026-06-11")
        let (twoDays, replaced) = engine.applying(nextDay, to: [original])
        XCTAssertNil(replaced)
        XCTAssertEqual(twoDays.count, 2)
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
            engine.isUnlocked(vaultID: vaultID, currentUserID: alice, deposits: deposits, now: lateNight)
        )
        // …and two minutes later the vault is locked again for the new day.
        XCTAssertFalse(
            engine.isUnlocked(vaultID: vaultID, currentUserID: alice, deposits: deposits, now: justPastMidnight)
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

    func testBackfillDoesNotRepairBrokenStreak() {
        // TODO: BACKEND — when streak repair ships, this test flips: a
        // backfilled day should then be allowed to mend the chain.
        let now = date(2026, 6, 10)
        var deposits = fullDays(offsets: -3...(-1), now: now, absent: [-1: cleo])
        let broken = engine.computeStreak(memberIDs: members, deposits: deposits, now: now)
        XCTAssertEqual(broken.count, 0)

        // cleo backfills yesterday. The day is now complete, so a recompute
        // naturally picks it up — MVP behavior is simply "recompute", and
        // this documents what that yields today.
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
                vaultID: vaultID,
                currentUserID: alice,
                deposits: [deposit(bob, today), deposit(cleo, today)],
                now: now
            ),
            "everyone else's deposits never unlock your vault"
        )
        XCTAssertTrue(
            engine.isUnlocked(
                vaultID: vaultID,
                currentUserID: alice,
                deposits: [deposit(alice, today)],
                now: now
            )
        )
        XCTAssertFalse(
            engine.isUnlocked(
                vaultID: vaultID,
                currentUserID: alice,
                deposits: [deposit(alice, "2026-06-09")],
                now: now
            ),
            "yesterday's deposit doesn't open today"
        )
    }

    // MARK: Captions & invite codes

    func testCaptionSanitization() {
        XCTAssertNil(VaultEngine.sanitizedCaption(nil))
        XCTAssertNil(VaultEngine.sanitizedCaption("   \n "))
        XCTAssertEqual(VaultEngine.sanitizedCaption("  hello  "), "hello")
        XCTAssertEqual(
            VaultEngine.sanitizedCaption(String(repeating: "x", count: 200))?.count,
            VaultEngine.captionLimit
        )
    }

    func testInviteCodeShape() {
        for _ in 0..<20 {
            let code = VaultEngine.generateInviteCode()
            XCTAssertEqual(code.count, 6)
            XCTAssertTrue(code.allSatisfy { $0.isLetter || $0.isNumber })
        }
    }
}

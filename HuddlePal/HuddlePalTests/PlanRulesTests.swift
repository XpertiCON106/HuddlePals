import XCTest
@testable import HuddlePal

/// The free plan's and Plus's rules as pure functions on `HuddleEngine`: the
/// archive window, and the mirror of the server's huddle_join_rule and
/// create_huddle caps (supabase/tests/caps.test.mjs covers the same cases
/// against Postgres).
final class PlanRulesTests: XCTestCase {
    private var engine: HuddleEngine!

    override func setUp() {
        super.setUp()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        engine = HuddleEngine(calendar: calendar)
    }

    // MARK: Archive window

    func testTheFreePlanOpensTodayAndThe29DaysBeforeIt() {
        let today = "2026-10-27"
        XCTAssertTrue(engine.isDayUnlockedInArchive(dayKey: today, todayDayKey: today, isPremium: false))
        XCTAssertTrue(engine.isDayUnlockedInArchive(dayKey: "2026-09-28", todayDayKey: today, isPremium: false), "today - 29")
        XCTAssertFalse(engine.isDayUnlockedInArchive(dayKey: "2026-09-27", todayDayKey: today, isPremium: false), "today - 30")
        XCTAssertFalse(engine.isDayUnlockedInArchive(dayKey: "2025-01-01", todayDayKey: today, isPremium: false))
    }

    func testPlusOpensEveryDay() {
        XCTAssertTrue(engine.isDayUnlockedInArchive(dayKey: "2019-02-03", todayDayKey: "2026-10-27", isPremium: true))
    }

    func testADayAheadOfYourTodayOpens() {
        // A member in a timezone east of yours posts under tomorrow's key.
        XCTAssertTrue(engine.isDayUnlockedInArchive(dayKey: "2026-10-28", todayDayKey: "2026-10-27", isPremium: false))
    }

    func testTheWindowCountsCalendarDaysAcrossMonthsYearsAndLeapDays() {
        XCTAssertTrue(engine.isDayUnlockedInArchive(dayKey: "2026-12-03", todayDayKey: "2027-01-01", isPremium: false))
        XCTAssertFalse(engine.isDayUnlockedInArchive(dayKey: "2026-12-02", todayDayKey: "2027-01-01", isPremium: false))
        XCTAssertTrue(engine.isDayUnlockedInArchive(dayKey: "2028-02-01", todayDayKey: "2028-03-01", isPremium: false), "29 days back in a leap year")
        XCTAssertFalse(engine.isDayUnlockedInArchive(dayKey: "2028-01-31", todayDayKey: "2028-03-01", isPremium: false))
    }

    func testAMalformedTodayLocksTheFreePlanRatherThanOpeningEverything() {
        XCTAssertFalse(engine.isDayUnlockedInArchive(dayKey: "2026-10-27", todayDayKey: "not a day", isPremium: false))
    }

    func testSettingTheClockBackOpensNoOlderDay() {
        let device = "2026-01-01" // the phone's clock, set back
        XCTAssertEqual(
            engine.archiveTodayKey(deviceTodayKey: device, serverTodayKey: "2026-10-27", newestDepositDayKey: nil),
            "2026-10-27"
        )
        XCTAssertEqual(
            engine.archiveTodayKey(deviceTodayKey: device, serverTodayKey: nil, newestDepositDayKey: "2026-10-27"),
            "2026-10-26",
            "offline: the newest deposit, less the day a member east of you can be ahead"
        )
        XCTAssertEqual(
            engine.archiveTodayKey(deviceTodayKey: "2026-10-27", serverTodayKey: "2026-10-26", newestDepositDayKey: "2026-10-28"),
            "2026-10-27",
            "a deposit a day ahead never shifts the window"
        )
        XCTAssertEqual(engine.archiveTodayKey(deviceTodayKey: "2026-10-27", serverTodayKey: nil, newestDepositDayKey: nil), "2026-10-27")
    }

    // MARK: Joining (huddle_join_rule)

    private func refusal(
        members: Int, premium: Bool = false, rank: Int? = 0, joinerIn: Int = 0, limits: Bool = true
    ) -> HuddleEngine.JoinRefusal? {
        HuddleEngine.joinRefusal(
            memberCount: members, keeperIsPremium: premium, keeperRank: rank,
            joinerHuddleCount: joinerIn, limitsActive: limits
        )
    }

    func testBeforeTheLimitsStartEveryHuddleTakes8() {
        XCTAssertNil(refusal(members: 7, rank: 9, joinerIn: 40, limits: false))
        XCTAssertEqual(refusal(members: 8, limits: false), .full)
        XCTAssertEqual(HuddleEngine.joinRule(memberCount: 2, keeperIsPremium: false, keeperRank: nil, limitsActive: false).memberCap, 8)
    }

    func testAFreeKeepersHuddleTakes4() {
        XCTAssertNil(refusal(members: 3))
        XCTAssertEqual(refusal(members: 4), .freeLimit)
        XCTAssertEqual(refusal(members: 7), .freeLimit, "grandfathered: over the cap, nobody removed, nobody added")
    }

    func testOnlyAFreeKeepersFirst3HuddlesTakeMembers() {
        XCTAssertNil(refusal(members: 1, rank: 2))
        XCTAssertEqual(refusal(members: 1, rank: 3), .invitesPaused)
        XCTAssertEqual(refusal(members: 1, rank: nil), .invitesPaused, "no keeper")
    }

    func testAPlusKeepersHuddlesTake10WhereverTheyAreInTheQueue() {
        XCTAssertNil(refusal(members: 9, premium: true, rank: 8))
        XCTAssertEqual(refusal(members: 10, premium: true), .maxMembers)
        XCTAssertEqual(HuddleEngine.joinRule(memberCount: 1, keeperIsPremium: true, keeperRank: 5, limitsActive: true).memberCap, 10)
    }

    func testNobodyJoinsMoreThan25HuddlesOnceTheLimitsAreOn() {
        XCTAssertNil(refusal(members: 1, joinerIn: 24))
        XCTAssertEqual(refusal(members: 1, premium: true, joinerIn: 25), .membershipLimit)
        XCTAssertEqual(refusal(members: 4, joinerIn: 25), .membershipLimit, "the joiner's limit is checked first, as on the server")
    }

    func testAKeepersQueueIsOrderedByWhenTheyBecameKeeper() {
        let first = UUID(), second = UUID(), inherited = UUID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let kept = [
            (huddleID: inherited, keeperSince: start.addingTimeInterval(500)),
            (huddleID: second, keeperSince: start.addingTimeInterval(100)),
            (huddleID: first, keeperSince: start),
        ]
        XCTAssertEqual(HuddleEngine.keeperRank(of: first, among: kept), 0)
        XCTAssertEqual(HuddleEngine.keeperRank(of: second, among: kept), 1)
        XCTAssertEqual(HuddleEngine.keeperRank(of: inherited, among: kept), 2)
        XCTAssertNil(HuddleEngine.keeperRank(of: UUID(), among: kept))
    }

    func testTiesInTheQueueBreakByIdLikeTheServer() {
        let a = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let b = UUID(uuidString: "FFFFFFFF-0000-4000-8000-000000000001")!
        let same = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(HuddleEngine.keeperRank(of: a, among: [(b, same), (a, same)]), 0)
    }

    // MARK: Creating (create_huddle)

    func testHuddlesKeptAreCappedAt3FreeAnd10WithPlusOnceTheLimitsAreOn() {
        XCTAssertNil(HuddleEngine.createRefusal(keptHuddles: 12, isPremium: false, limitsActive: false))
        XCTAssertNil(HuddleEngine.createRefusal(keptHuddles: 2, isPremium: false, limitsActive: true))
        XCTAssertEqual(HuddleEngine.createRefusal(keptHuddles: 3, isPremium: false, limitsActive: true), .freeLimit)
        XCTAssertNil(HuddleEngine.createRefusal(keptHuddles: 9, isPremium: true, limitsActive: true))
        XCTAssertEqual(HuddleEngine.createRefusal(keptHuddles: 10, isPremium: true, limitsActive: true), .plusLimit)
    }

    // MARK: The server's codes

    func testRefusalsCarryTheServersErrorCodes() {
        XCTAssertEqual(HuddleEngine.JoinRefusal.allCases.map(\.rawValue), [
            "huddle_full", "join_blocked_free_limit", "join_blocked_invites_paused",
            "join_blocked_max_members", "join_blocked_membership_limit",
        ])
        XCTAssertEqual(HuddleEngine.CreateRefusal.allCases.map(\.rawValue), [
            "huddle_limit_reached_free", "huddle_limit_reached_premium",
        ])
    }

    func testBuildsFromBeforePlusReadEveryNewRefusalAsYouCantJoin() {
        // Those builds map "huddle_full" to "already has 8 members" and
        // "blocked" to "You can't join this huddle.".
        for refusal in HuddleEngine.JoinRefusal.allCases where refusal != .full {
            XCTAssertFalse(refusal.rawValue.contains("huddle_full"), refusal.rawValue)
            XCTAssertTrue(refusal.rawValue.contains("blocked"), refusal.rawValue)
        }
    }

    func testServerMessagesMapToTheirOwnErrors() {
        let cases: [(String, HuddleServiceError)] = [
            ("huddle_full", .huddleFull),
            ("join_blocked_free_limit", .huddleFullFree),
            ("join_blocked_invites_paused", .invitesPaused),
            ("join_blocked_max_members", .huddleAtMaximum),
            ("join_blocked_membership_limit", .tooManyHuddles),
        ]
        for (message, expected) in cases {
            XCTAssertEqual(HuddleServiceError(serverJoinMessage: message)?.errorDescription, expected.errorDescription, message)
        }
        XCTAssertNil(HuddleServiceError(serverJoinMessage: "blocked"), "someone blocked you: not a limit")
        XCTAssertEqual(HuddleServiceError(serverCreateMessage: "huddle_limit_reached_free")?.errorDescription, HuddleServiceError.huddleLimitFree.errorDescription)
        XCTAssertEqual(HuddleServiceError(serverCreateMessage: "huddle_limit_reached_premium")?.errorDescription, HuddleServiceError.huddleLimitPlus.errorDescription)
        XCTAssertNil(HuddleServiceError(serverCreateMessage: "not authenticated"))
    }

    func testTheNumbersInTheCopyAreTheLimits() {
        XCTAssertTrue(HuddleServiceError.huddleFullFree.errorDescription!.contains("\(HuddleLimits.freeMembers) people"))
        XCTAssertTrue(HuddleServiceError.huddleFullFree.errorDescription!.contains("up to \(HuddleLimits.plusMembers)"))
        XCTAssertTrue(HuddleServiceError.huddleAtMaximum.errorDescription!.contains("\(HuddleLimits.plusMembers) members"))
        XCTAssertTrue(HuddleServiceError.tooManyHuddles.errorDescription!.contains("\(HuddleLimits.huddlesJoined) huddles"))
        XCTAssertTrue(HuddleServiceError.huddleLimitFree.errorDescription!.contains("\(HuddleLimits.freeHuddlesKept) huddles"))
        XCTAssertTrue(HuddleServiceError.huddleLimitPlus.errorDescription!.contains("\(HuddleLimits.plusHuddlesKept) huddles"))
        XCTAssertTrue(HuddleServiceError.huddleFull.errorDescription!.contains("\(HuddleLimits.legacyMembers) members"))
    }
}

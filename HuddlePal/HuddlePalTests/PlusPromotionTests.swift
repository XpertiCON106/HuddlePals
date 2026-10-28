import UserNotifications
import XCTest

@testable import HuddlePal

/// HuddlePals+ introduced once after a first post, and its reminders: only
/// when asked for, two to four weeks apart at a daytime hour, and never to
/// someone who has Plus, turned them off, or signed out.
@MainActor
final class PlusPromotionTests: XCTestCase {
    private var defaults: UserDefaults!
    private var settings: PlusPromoSettings!
    private var scheduler: PlusSchedulerSpy!
    private var session: AppSession!
    private var plans: MockPlanLedger!
    private var clock: FixedClock!
    private var promotion: PlusPromotion!
    private let calendar = Calendar(identifier: .gregorian)
    private let me = User(displayName: "Me", avatarColorHex: "E5484D")

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: "PlusPromotionTests")
        defaults.removePersistentDomain(forName: "PlusPromotionTests")
        settings = PlusPromoSettings(defaults: defaults)
        scheduler = PlusSchedulerSpy()
        session = AppSession()
        session.currentUser = me
        plans = MockPlanLedger()
        clock = FixedClock(now: Date(timeIntervalSince1970: 1_793_000_000))
        promotion = PlusPromotion(
            settings: settings,
            scheduler: scheduler,
            session: session,
            plus: MockPlusService(plans: plans, session: session),
            calendar: calendar,
            dateProvider: clock
        )
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: "PlusPromotionTests")
        try await super.tearDown()
    }

    // MARK: The intro

    func testTheIntroShowsOnceAfterTheFirstPost() {
        promotion.postOpenedHuddle()
        XCTAssertEqual(promotion.sheet, .intro)
        promotion.sheet = nil
        promotion.postOpenedHuddle()
        XCTAssertNil(promotion.sheet, "once")
        XCTAssertTrue(PlusPromoSettings(defaults: defaults).introShown, "and remembered across launches")
    }

    func testNobodyWithPlusIsIntroducedToIt() {
        plans.setPlus(true, for: me.id)
        promotion.postOpenedHuddle()
        XCTAssertNil(promotion.sheet)
        plans.setPlus(false, for: me.id)
        promotion.postOpenedHuddle()
        XCTAssertNil(promotion.sheet, "the first post was the moment")
    }

    func testTheIntroAsksForNothing() {
        promotion.postOpenedHuddle()
        XCTAssertEqual(scheduler.permissionRequests, 0)
        XCTAssertFalse(settings.remindersEnabled, "reminders are opt-in")
    }

    // MARK: Reminders

    func testRemindMeLaterAsksThenSchedulesTwoToFourWeeksOut() async throws {
        await promotion.setRemindersEnabled(true)
        XCTAssertEqual(scheduler.permissionRequests, 1)
        XCTAssertTrue(settings.remindersEnabled)
        let next = try XCTUnwrap(scheduler.scheduled.last)
        XCTAssertEqual(next, settings.nextReminder)
        assertInWindow(next, after: clock.now)
    }

    func testRefusedNotificationsLeaveRemindersOff() async {
        scheduler.grants = false
        await promotion.setRemindersEnabled(true)
        XCTAssertFalse(settings.remindersEnabled)
        XCTAssertTrue(scheduler.scheduled.isEmpty)
    }

    func testThePendingReminderKeepsItsDayUntilItsDue() async throws {
        await promotion.setRemindersEnabled(true)
        let first = try XCTUnwrap(settings.nextReminder)
        clock.now = clock.now.addingTimeInterval(3 * 86_400)
        await promotion.refresh()
        XCTAssertEqual(scheduler.scheduled.last, first, "a launch doesn't move it")

        clock.now = first.addingTimeInterval(3_600)
        await promotion.refresh()
        let second = try XCTUnwrap(scheduler.scheduled.last)
        XCTAssertNotEqual(second, first)
        assertInWindow(second, after: clock.now)
    }

    func testPlusSigningOutAndTheSwitchEachStopThem() async {
        await promotion.setRemindersEnabled(true)
        let cancels = scheduler.cancels

        plans.setPlus(true, for: me.id)
        await promotion.refresh()
        XCTAssertEqual(scheduler.cancels, cancels + 1, "nobody with Plus is reminded of it")
        plans.setPlus(false, for: me.id)

        session.currentUser = nil
        await promotion.refresh()
        XCTAssertEqual(scheduler.cancels, cancels + 2, "nor a signed-out device")
        session.currentUser = me

        await promotion.setRemindersEnabled(false)
        XCTAssertEqual(scheduler.cancels, cancels + 3, "nor someone who turned them off")
        XCTAssertFalse(PlusPromoSettings(defaults: defaults).remindersEnabled)
    }

    func testTappingAReminderOpensThePaywall() {
        promotion.reminderTapped()
        XCTAssertEqual(promotion.sheet, .paywall)
        promotion.sheet = nil
        plans.setPlus(true, for: me.id)
        promotion.reminderTapped()
        XCTAssertNil(promotion.sheet, "already has it")
    }

    func testEveryDrawLandsOnADaytimeHourTwoToFourWeeksOut() {
        var generator = SeededGenerator(seed: 42)
        var days = Set<Int>()
        var hours = Set<Int>()
        for _ in 0..<500 {
            let next = PlusPromotion.nextReminder(after: clock.now, calendar: calendar, using: &generator)
            assertInWindow(next, after: clock.now)
            days.insert(calendar.dateComponents([.day], from: calendar.startOfDay(for: clock.now), to: calendar.startOfDay(for: next)).day!)
            hours.insert(calendar.component(.hour, from: next))
        }
        XCTAssertEqual(days, Set(PlusPromotion.gapDays), "every day in the window comes up")
        XCTAssertEqual(hours, Set(PlusPromotion.hours), "and every hour")
    }

    private func assertInWindow(_ date: Date, after now: Date, file: StaticString = #filePath, line: UInt = #line) {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day!
        XCTAssertTrue(PlusPromotion.gapDays.contains(days), "\(days) days out", file: file, line: line)
        XCTAssertTrue(PlusPromotion.hours.contains(calendar.component(.hour, from: date)), "at \(date)", file: file, line: line)
    }
}

// MARK: - Restore instead of buying

@MainActor
final class PaywallRestoreOfferTests: XCTestCase {
    func testAnAppleAccountWithPlusIsOfferedRestoreNotTheDealAgain() async throws {
        let deps = AppDependencies.makeMock(inMemory: true)
        let plans = try XCTUnwrap(deps.mockPlans)
        deps.session.currentUser = User(displayName: "Me", avatarColorHex: "E5484D")

        let fresh = PaywallViewModel(deps: deps, context: .profile)
        await fresh.load()
        XCTAssertFalse(fresh.offersRestoreInsteadOfBuying)

        plans.purchasesLinkedElsewhere = true
        let paywall = PaywallViewModel(deps: deps, context: .profile)
        await paywall.load()
        XCTAssertTrue(paywall.offersRestoreInsteadOfBuying)
        await paywall.restore()
        XCTAssertTrue(paywall.isLinkedElsewhereAlertPresented, "said where nobody can miss it")
        XCTAssertEqual(paywall.message, PaywallViewModel.linkedElsewhere)
    }
}

// MARK: - Test doubles

private final class PlusSchedulerSpy: PlusReminderScheduling {
    var grants = true
    private(set) var permissionRequests = 0
    private(set) var scheduled: [Date] = []
    private(set) var cancels = 0
    private var decided = false

    func authorizationStatus() async -> UNAuthorizationStatus {
        decided ? (grants ? .authorized : .denied) : .notDetermined
    }

    func requestAuthorization() async -> Bool {
        permissionRequests += 1
        decided = true
        return grants
    }

    func schedule(at date: Date, calendar: Calendar) { scheduled.append(date) }
    func cancel() { cancels += 1 }
}

private final class FixedClock: DateProviding {
    var now: Date
    init(now: Date) { self.now = now }
}

/// SplitMix64: the same draws every run.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

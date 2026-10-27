import SwiftData
import XCTest

@testable import HuddlePal

/// The paywall and the places the free plan holds something back, in the
/// offline world: the archive past 30 days, a 4th huddle, a full or paused
/// huddle's invite, video in Compose, and Apple's billing at deletion.
@MainActor
final class PlusGateTests: XCTestCase {
    private var deps: AppDependencies!
    private var plans: MockPlanLedger!
    private var you: User!
    private var crew: Huddle!

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: ComposeViewModel.lastMediumKey)
        deps = AppDependencies.makeMock(inMemory: true)
        try await deps.seeder.regenerate()
        plans = try XCTUnwrap(deps.mockPlans)
        guard case .signedIn(let user) = try await deps.auth.currentState() else {
            throw XCTSkip("expected the seeded user to be signed in")
        }
        you = user
        deps.session.currentUser = user
        let huddles = try await deps.huddleService.huddles(for: user)
        crew = try XCTUnwrap(huddles.first { $0.inviteCode == SeedDataService.crewInviteCode })
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: ComposeViewModel.lastMediumKey)
        deps.dateProvider.reset()
        try await super.tearDown()
    }

    private func dayKey(_ offset: Int) -> String {
        deps.engine.dayKey(byAdding: offset, to: deps.engine.todayKey(now: deps.dateProvider.now))!
    }

    private func archive() async -> ArchiveViewModel {
        let viewModel = ArchiveViewModel(deps: deps, huddle: crew)
        await viewModel.refresh()
        return viewModel
    }

    private func lockedDays(_ viewModel: ArchiveViewModel) -> [String] {
        viewModel.months.flatMap(\.days).filter(\.isLocked).map(\.dayKey).sorted()
    }

    // MARK: The paywall

    func testThePaywallSaysWhatAppleAsksBeforeBuying() async {
        let paywall = PaywallViewModel(deps: deps, context: .archive)
        await paywall.load()
        XCTAssertEqual(paywall.phase, .ready)
        XCTAssertEqual(paywall.products.map(\.period), [.month, .year])
        XCTAssertEqual(paywall.selected?.period, .year, "the yearly plan is chosen first")
        XCTAssertEqual(paywall.buttonTitle, "Try it free for 1 week")
        let terms = paywall.renewalTerms
        for words in ["Free for 1 week, then $24.99 a year", "charged to your Apple Account", "renews automatically",
                      "at least 24 hours before the end of the current period", "Settings › your name › Subscriptions"] {
            XCTAssertTrue(terms.contains(words), "\(words) — in: \(terms)")
        }
        paywall.selectedID = PlusCatalog.monthly
        XCTAssertTrue(paywall.renewalTerms.contains("$2.99 a month"))
        XCTAssertEqual(PaywallContext.archive.headline, "Unlock your full huddle archive with HuddlePals Plus")
    }

    func testBuyingTurnsPlusOnAndClosesThePaywall() async {
        let paywall = PaywallViewModel(deps: deps, context: .video)
        await paywall.load()
        await paywall.purchase()
        XCTAssertTrue(paywall.didUnlock)
        XCTAssertTrue(deps.plus.isPremium)
        XCTAssertNil(paywall.message)
    }

    func testASubscriptionLinkedElsewhereOrMissingIsExplained() async {
        let paywall = PaywallViewModel(deps: deps, context: .profile)
        await paywall.load()
        await paywall.restore()
        XCTAssertEqual(paywall.message, "No HuddlePals Plus subscription was found for this Apple Account.")
        plans.purchasesLinkedElsewhere = true
        await paywall.purchase()
        XCTAssertEqual(paywall.message, PaywallViewModel.linkedElsewhere)
        XCTAssertFalse(paywall.didUnlock)
        XCTAssertFalse(deps.plus.isPremium)
    }

    func testTrialsAndPricesReadNaturally() {
        XCTAssertEqual(PaywallViewModel.trialLength(days: 1), "1 day")
        XCTAssertEqual(PaywallViewModel.trialLength(days: 3), "3 days")
        XCTAssertEqual(PaywallViewModel.trialLength(days: 7), "1 week")
        XCTAssertEqual(PaywallViewModel.trialLength(days: 14), "2 weeks")
        XCTAssertEqual(PaywallViewModel.trialLength(days: 30), "1 month")
        XCTAssertEqual(PaywallViewModel.price(MockPlusService.catalog[0]), "$2.99 a month")
    }

    // MARK: The archive

    func testOnTheFreePlanDaysPast30AreLockedAndPlusOpensThemAll() async {
        let locked = lockedDays(await archive())
        XCTAssertEqual(locked.count, 16, "days -45…-30")
        XCTAssertEqual(locked.first, dayKey(-45))
        XCTAssertEqual(locked.last, dayKey(-30))
        XCTAssertFalse(locked.contains(dayKey(-29)))

        plans.setPlus(true, for: you.id)
        let withPlus = await archive()
        XCTAssertEqual(lockedDays(withPlus), [])
    }

    func testSettingThePhonesClockBackOpensNoOlderDay() async {
        deps.dateProvider.dayOffset = -60 // the phone thinks it's two months ago
        let locked = lockedDays(await archive())
        XCTAssertEqual(locked.count, 16, "the server's clock and the newest deposit still say when today is")
    }

    func testADepositPastTheWindowIsLockedInItsDetailScreen() throws {
        let old = try XCTUnwrap(crew.deposits.first { $0.dayKey == dayKey(-40) })
        let recent = try XCTUnwrap(crew.deposits.first { $0.dayKey == dayKey(-2) })
        XCTAssertTrue(DepositDetailViewModel(deps: deps, deposit: old).isLocked)
        XCTAssertFalse(DepositDetailViewModel(deps: deps, deposit: recent).isLocked)
        plans.setPlus(true, for: you.id)
        XCTAssertFalse(DepositDetailViewModel(deps: deps, deposit: old).isLocked)
    }

    // MARK: Creating a huddle

    func testTheCreateScreenSaysWhenTheFreeCapIsReached() async {
        let first = CreateHuddleViewModel(deps: deps)
        XCTAssertNil(first.limitReached, "You keep 2")
        first.name = "Third"
        await first.create()
        XCTAssertNotNil(first.createdHuddle)

        let second = CreateHuddleViewModel(deps: deps)
        second.name = "Fourth"
        XCTAssertEqual(second.limitReached, .huddleLimitFree)
        XCTAssertTrue(second.canGetPlus)
        XCTAssertFalse(second.canCreate)

        plans.setPlus(true, for: you.id)
        XCTAssertNil(second.limitReached)
        XCTAssertTrue(second.canCreate)
    }

    func testPlusSaysTenIsTheMostAnyoneKeeps() async {
        plans.setPlus(true, for: you.id)
        for index in 0..<8 {
            let viewModel = CreateHuddleViewModel(deps: deps)
            viewModel.name = "Huddle \(index)"
            await viewModel.create()
        }
        let eleventh = CreateHuddleViewModel(deps: deps)
        XCTAssertEqual(eleventh.limitReached, .huddleLimitPlus)
        XCTAssertFalse(eleventh.canGetPlus, "nothing to buy past 10")
    }

    // MARK: Invites

    func testAFullFreeHuddleExplainsInsteadOfShowingItsCode() async {
        let settings = HuddleSettingsViewModel(deps: deps, huddle: crew)
        await settings.loadJoinStatus()
        XCTAssertEqual(settings.joinStatus, HuddleJoinStatus(refusal: .freeLimit, memberCount: 4, memberCap: 4))
        XCTAssertTrue(settings.invitesClosedMessage?.contains("full on the free plan") == true)
        XCTAssertTrue(settings.canReopenWithPlus, "the keeper can")

        plans.setPlus(true, for: you.id)
        await settings.loadJoinStatus()
        XCTAssertNil(settings.invitesClosedMessage)
        XCTAssertEqual(settings.joinStatus?.memberCap, 10)
    }

    func testAMemberSeesWhoCanReopenIt() async throws {
        deps.session.currentUser = try XCTUnwrap(crew.members.first { $0.id != you.id })
        let settings = HuddleSettingsViewModel(deps: deps, huddle: crew)
        await settings.loadJoinStatus()
        XCTAssertTrue(settings.invitesClosedMessage?.contains("when its keeper gets HuddlePals Plus") == true)
        XCTAssertFalse(settings.canReopenWithPlus, "only the keeper's plan opens it")
    }

    func testAKeepersHuddlesPastTheFirstThreeArePaused() async throws {
        plans.setPlus(true, for: you.id)
        _ = try await deps.huddleService.createHuddle(name: "Third", emoji: "🧪", keeper: you)
        let fourth = try await deps.huddleService.createHuddle(name: "Fourth", emoji: "🧪", keeper: you)
        plans.setPlus(false, for: you.id)
        let settings = HuddleSettingsViewModel(deps: deps, huddle: fourth)
        await settings.loadJoinStatus()
        XCTAssertEqual(settings.joinStatus?.refusal, .invitesPaused)
        XCTAssertTrue(settings.invitesClosedMessage?.contains("invites to this one are paused") == true)
    }

    // MARK: Compose

    func testComposeOpensOnVideoAfterAVideoOnlyWithPlus() async throws {
        plans.setPlus(true, for: you.id)
        let first = ComposeViewModel(deps: deps, huddle: crew)
        XCTAssertEqual(first.medium, .photo)
        first.choose(.video)
        first.setCapturedVideo(try await ClipPreparer.placeholder(seed: 41))
        first.continueToConfirm()
        let posted = await first.confirmAndPost()
        XCTAssertTrue(posted)
        XCTAssertEqual(ComposeViewModel(deps: deps, huddle: crew).medium, .video, "last time was a video")

        plans.setPlus(false, for: you.id)
        XCTAssertEqual(ComposeViewModel(deps: deps, huddle: crew).medium, .photo, "but not without Plus")
    }

    // MARK: Profile

    func testProfileShowsThePlanAndRestores() async {
        let profile = ProfileViewModel(deps: deps)
        XCTAssertEqual(profile.plusSummary, "Free plan")
        XCTAssertFalse(profile.canManageSubscription, "no Apple subscription to manage offline")
        await profile.restorePurchases()
        XCTAssertEqual(profile.plusMessage, "No HuddlePals Plus subscription was found for this Apple Account.")
        plans.setPlus(true, for: you.id)
        await profile.restorePurchases()
        XCTAssertEqual(profile.plusMessage, "HuddlePals Plus is on.")
        XCTAssertEqual(profile.plusSummary, "On")
    }

    func testDeletingTheAccountWarnsThatApplesBillingGoesOn() async {
        let profile = ProfileViewModel(deps: deps)
        await profile.prepareAccountDeletion()
        XCTAssertFalse(profile.appleBillingContinues)
        plans.setPlus(true, for: you.id)
        await profile.prepareAccountDeletion()
        XCTAssertTrue(profile.appleBillingContinues)
        XCTAssertTrue(ProfileViewModel.billingContinuesWarning.contains("Settings › your name › Subscriptions"))
    }
}

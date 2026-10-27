import XCTest

/// The free plan and HuddlePals Plus, end to end in the seeded world, with
/// the free limits on (`-ui-testing-free-limits`): the paywall shows what App
/// Review asks of a subscription, and each place the free plan holds
/// something back leads to it.
final class PlusJourneyTests: HuddleUITestCase {
    private func paywallHeadline(_ text: String) -> XCUIElement {
        app.staticTexts[text]
    }

    /// Price, period, renewal terms, the Terms of Use / Terms / Privacy links
    /// and Restore Purchases (guideline 3.1.2); buying turns Plus on.
    func testThePaywallShowsWhatAppleAsksAndBuyingTurnsPlusOn() {
        launchToShelf(arguments: ["-ui-testing-free-limits"])
        openTab("Profile")
        let getPlus = app.buttons["Get HuddlePals Plus"]
        scrollTo(getPlus)
        getPlus.tap()

        // Profile has its own "HuddlePals Plus" row: wait on the paywall's terms.
        let terms = waitFor(app.staticTexts["renewalTerms"])
        waitFor(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Yearly, $24.99 a year'")).firstMatch)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Monthly, $2.99 a month'")).firstMatch.exists)
        XCTAssertTrue(terms.label.contains("renews automatically"), terms.label)
        XCTAssertTrue(terms.label.contains("24 hours"), terms.label)
        for link in ["Terms of Use", "Terms of Service", "Privacy Policy"] {
            XCTAssertTrue(app.buttons[link].exists || app.links[link].exists, "\(link) link")
        }
        XCTAssertTrue(app.buttons["Restore Purchases"].exists)
        snapshot("paywall")

        app.buttons["Try it free for 1 week"].tap()
        // It says so for a moment, then closes itself.
        waitUntilGone(terms, timeout: 10)
        waitUntilGone(app.buttons["Close"], timeout: 10)
        let summary = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Current period ends'")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 5), "Profile shows Plus on, with its period")
        XCTAssertFalse(app.buttons["Get HuddlePals Plus"].exists)
    }

    /// A day past the free plan's 30 days shows who posted, locked, and opens
    /// the paywall.
    func testADayPastTheFreeWindowIsLockedAndLeadsToPlus() {
        launchToShelf(arguments: ["-ui-testing-free-limits"])
        openHuddle("The Crew")
        waitFor(app.buttons["Archive"]).tap()
        waitFor(app.navigationBars["Archive"])
        let locked = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Locked:'")).firstMatch
        scrollTo(locked, maxSwipes: 30)
        snapshot("archive locked days")
        locked.tap()
        waitFor(paywallHeadline("Unlock your full huddle archive with HuddlePals Plus"))
        snapshot("archive paywall")
    }

    /// Free: Video opens the paywall; after buying, the video camera.
    func testVideoOnTheFreePlanLeadsToPlusThenTheVideoCamera() {
        launchToShelf(arguments: ["-ui-testing-free-limits"])
        openHuddle("The Crew")
        waitFor(app.buttons["Add today's memory"]).tap()
        waitFor(app.buttons["Take test photo"])
        app.buttons["Cancel"].firstMatch.tap()
        waitFor(app.buttons["Video · Plus"]).tap()
        waitFor(paywallHeadline("Post 6-second video drops with HuddlePals Plus"))
        app.buttons["Try it free for 1 week"].tap()
        waitFor(app.buttons["Record test video"], timeout: 15)
    }

    /// The free plan keeps 3 huddles: the 4th says so, with the way to 10.
    func testAFourthHuddleNeedsPlus() {
        launchToShelf(arguments: ["-ui-testing-free-limits"])
        openAddMenu("Create a Huddle")
        let name = waitFor(app.textFields["Huddle name"])
        name.tap()
        name.typeText("Third")
        waitFor(app.buttons["Create huddle"]).tap()
        waitFor(app.buttons["Back to my huddles"], timeout: 15).tap()

        openAddMenu("Create a Huddle")
        waitFor(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'You keep 3 huddles'")).firstMatch)
        XCTAssertFalse(app.buttons["Create huddle"].isEnabled)
        snapshot("create limit")
        app.buttons["Get HuddlePals Plus"].tap()
        waitFor(paywallHeadline("Keep up to 10 huddles with HuddlePals Plus"))
    }

    /// The Crew is 4 people: full on the free plan, so its settings explain
    /// that instead of showing a code that would fail.
    func testAFullFreeHuddleExplainsItsInvite() {
        launchToShelf(arguments: ["-ui-testing-free-limits"])
        openHuddle("The Crew")
        waitFor(app.buttons["Huddle settings"]).tap()
        let closed = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'full on the free plan'")).firstMatch
        scrollTo(closed)
        XCTAssertFalse(app.staticTexts["inviteCode"].exists, "no code that would fail")
        snapshot("invite paused")
        app.buttons["Get HuddlePals Plus"].tap()
        waitFor(paywallHeadline("Reopen invites with HuddlePals Plus"))
    }
}

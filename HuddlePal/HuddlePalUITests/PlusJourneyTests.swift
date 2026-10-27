import XCTest

/// The free plan and HuddlePals+, end to end in the seeded world: the
/// paywall shows what App Review asks of a subscription, and each place the
/// free plan holds something back leads to it.
final class PlusJourneyTests: HuddleUITestCase {
    private func paywallHeadline(_ text: String) -> XCUIElement {
        app.staticTexts[text]
    }

    /// Price, period, renewal terms, the Terms of Use / Terms / Privacy links
    /// and Restore Purchases (guideline 3.1.2); buying turns Plus on.
    func testThePaywallShowsWhatAppleAsksAndBuyingTurnsPlusOn() {
        launchToShelf()
        openTab("Profile")
        let getPlus = app.buttons["Get HuddlePals+"]
        scrollTo(getPlus)
        getPlus.tap()

        // Profile has its own "HuddlePals+" row: wait on the paywall's terms.
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
        XCTAssertFalse(app.buttons["Get HuddlePals+"].exists)
    }

    /// A day past the free plan's 30 days shows who posted, locked, and opens
    /// the paywall; buying Plus opens every day there and then.
    func testADayPastTheFreeWindowIsLockedAndPlusOpensIt() {
        launchToShelf()
        openHuddle("The Crew")
        waitFor(app.buttons["Archive"]).tap()
        waitFor(app.navigationBars["Archive"])
        let lockedTiles = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Locked:'"))
        let locked = lockedTiles.firstMatch
        scrollTo(locked, maxSwipes: 30)
        snapshot("archive locked days")
        let lockedFrame = locked.frame
        locked.tap()
        waitFor(paywallHeadline("Unlock your full huddle archive with HuddlePals+"))
        snapshot("archive paywall")

        let terms = app.staticTexts["renewalTerms"]
        app.buttons["Try it free for 1 week"].tap()
        waitUntilGone(terms, timeout: 10)
        let opened = expectation(for: NSPredicate(format: "count == 0"), evaluatedWith: lockedTiles)
        wait(for: [opened], timeout: 10)
        // The same tile, where it was, now opens.
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: lockedFrame.midX, dy: lockedFrame.midY)).tap()
        waitFor(app.buttons["Send comment"], timeout: 10, "the day opens in full")
        XCTAssertFalse(app.buttons["Unlock your full archive"].exists)
    }

    /// Free: Video opens the paywall; after buying, the video camera.
    func testVideoOnTheFreePlanLeadsToPlusThenTheVideoCamera() {
        launchToShelf()
        openHuddle("The Crew")
        waitFor(app.buttons["Add today's memory"]).tap()
        waitFor(app.buttons["Take test photo"])
        app.buttons["Cancel"].firstMatch.tap()
        waitFor(app.buttons["Video · Plus"]).tap()
        waitFor(paywallHeadline("Post 6-second video drops with HuddlePals+"))
        app.buttons["Try it free for 1 week"].tap()
        waitFor(app.buttons["Record test video"], timeout: 15)
    }

    /// The free plan keeps 3 huddles: the 4th says so, with the way to 10.
    func testAFourthHuddleNeedsPlus() {
        launchToShelf()
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
        app.buttons["Get HuddlePals+"].tap()
        waitFor(paywallHeadline("Keep up to 10 huddles with HuddlePals+"))
    }

    /// Two huddles made with Plus, then Plus ends: the 4th one kept is past
    /// the free plan's first 3, so its invites are paused, and its settings
    /// say so to its keeper with the way back.
    func testAHuddlePastTheFirst3PausesItsInvitesWhenPlusEnds() {
        launchToShelf(arguments: ["-ui-testing-plus"])
        for name in ["Third", "Fourth"] {
            openAddMenu("Create a Huddle")
            let field = waitFor(app.textFields["Huddle name"])
            field.tap()
            field.typeText(name)
            waitFor(app.buttons["Create huddle"]).tap()
            waitFor(app.buttons["Back to my huddles"], timeout: 15).tap()
        }

        openTab("Profile")
        let plus = app.switches.matching(NSPredicate(format: "label BEGINSWITH 'Simulate: HuddlePals+'")).firstMatch
        scrollTo(plus, maxSwipes: 25)
        plus.switches.firstMatch.tap()
        XCTAssertEqual(plus.switches.firstMatch.value as? String, "0", "Plus has ended")

        openTab("Huddles")
        openHuddle("Fourth")
        waitFor(app.buttons["Huddle settings"]).tap()
        let paused = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'invites to this one are paused'")).firstMatch
        scrollTo(paused)
        XCTAssertTrue(paused.exists, "the keeper is told why")
        XCTAssertFalse(app.staticTexts["inviteCode"].exists, "no code that would fail")
        snapshot("invites paused")
        app.buttons["Get HuddlePals+"].tap()
        waitFor(paywallHeadline("Reopen invites with HuddlePals+"))
    }

    /// Deleting the account doesn't end Apple's billing: with Plus, the
    /// confirmation says so (App Review 5.1.1(v)).
    func testDeletingTheAccountWithPlusWarnsThatAppleKeepsBilling() {
        launchToShelf(arguments: ["-ui-testing-plus"])
        openTab("Profile")
        let delete = app.buttons["Delete account"]
        scrollTo(delete, maxSwipes: 25)
        delete.tap()
        let warning = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'keeps renewing after your account is deleted'")).firstMatch
        waitFor(warning, timeout: 10, "the billing warning")
        XCTAssertTrue(warning.label.contains("Settings › your name › Subscriptions"), warning.label)
        snapshot("delete with plus")
        // Close it without deleting. iOS 26 shows it as a popover with no
        // Cancel button: tap outside it, below.
        if app.buttons["Cancel"].exists {
            app.buttons["Cancel"].tap()
        } else {
            app.otherElements["PopoverDismissRegion"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
        }
        waitUntilGone(warning)
        XCTAssertTrue(app.buttons["Delete account"].exists, "still signed in")
    }

    /// The Crew is 4 people: full on the free plan, so its settings explain
    /// that instead of showing a code that would fail.
    func testAFullFreeHuddleExplainsItsInvite() {
        launchToShelf()
        openHuddle("The Crew")
        waitFor(app.buttons["Huddle settings"]).tap()
        let closed = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'full on the free plan'")).firstMatch
        scrollTo(closed)
        XCTAssertFalse(app.staticTexts["inviteCode"].exists, "no code that would fail")
        snapshot("invite paused")
        app.buttons["Get HuddlePals+"].tap()
        waitFor(paywallHeadline("Reopen invites with HuddlePals+"))
    }
}

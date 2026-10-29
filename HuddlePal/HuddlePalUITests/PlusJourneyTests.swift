import XCTest

/// The free plan and HuddlePals+, end to end in the seeded world: the
/// paywall shows what App Review asks of a subscription, and each place the
/// free plan holds something back leads to it.
final class PlusJourneyTests: HuddleUITestCase {
    private func paywallHeadline(_ text: String) -> XCUIElement {
        app.staticTexts[text]
    }

    /// Bought: the welcome stays up until Continue.
    private func continueFromWelcome(file: StaticString = #filePath, line: UInt = #line) {
        let welcome = waitFor(app.staticTexts["Welcome to HuddlePals+"], timeout: 10, "the welcome screen", file: file, line: line)
        XCTAssertFalse(app.buttons["Close"].exists, "the welcome closes with Continue", file: file, line: line)
        sleep(2)
        XCTAssertTrue(welcome.exists, "the welcome doesn't close by itself", file: file, line: line)
        app.buttons["welcomeContinue"].tap()
        waitUntilGone(welcome, timeout: 10, file: file, line: line)
    }

    /// Price, period, renewal terms, the Terms of Use / Terms / Privacy links
    /// and Restore Purchases (guideline 3.1.2); buying turns Plus on.
    func testThePaywallShowsWhatAppleAsksAndBuyingTurnsPlusOn() {
        launchToShelf()
        openProfile()
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
        waitUntilGone(terms, timeout: 10)
        snapshot("plus welcome")
        continueFromWelcome()
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

        app.buttons["Try it free for 1 week"].tap()
        continueFromWelcome()
        let opened = expectation(for: NSPredicate(format: "count == 0"), evaluatedWith: lockedTiles)
        wait(for: [opened], timeout: 10)
        // The same tile, where it was, now opens.
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: lockedFrame.midX, dy: lockedFrame.midY)).tap()
        waitFor(app.buttons["Send comment"], timeout: 10, "the day opens in full")
        XCTAssertFalse(app.buttons["Unlock your full archive"].exists)
    }

    /// Free: Video opens the paywall; after buying, Compose is on Video, the
    /// video camera a tap away.
    func testVideoOnTheFreePlanLeadsToPlusThenTheVideoCamera() {
        launchToShelf()
        openHuddle("The Crew")
        waitFor(app.buttons["Add today's memory"]).tap()
        waitFor(app.buttons["Take test photo"])
        app.buttons["Cancel"].firstMatch.tap()
        waitFor(app.buttons["Video · Plus"]).tap()
        waitFor(paywallHeadline("Post 6-second video drops with HuddlePals+"))
        app.buttons["Try it free for 1 week"].tap()
        continueFromWelcome()
        waitFor(app.staticTexts["Record today's video, up to 6 seconds"], timeout: 15)
        XCTAssertFalse(app.buttons["Record test video"].exists, "the camera waits for a tap")
        waitFor(app.buttons["Open camera"]).tap()
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

        openProfile()
        let plus = app.switches.matching(NSPredicate(format: "label BEGINSWITH 'Simulate: HuddlePals+'")).firstMatch
        scrollTo(plus, maxSwipes: 25)
        plus.switches.firstMatch.tap()
        XCTAssertEqual(plus.switches.firstMatch.value as? String, "0", "Plus has ended")

        backToShelf()
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
    /// Delete account page says so (App Review 5.1.1(v)).
    func testDeletingTheAccountWithPlusWarnsThatAppleKeepsBilling() {
        launchToShelf(arguments: ["-ui-testing-plus"])
        openDeleteAccount()
        let warning = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'keeps renewing after your account is deleted'")).firstMatch
        waitFor(warning, timeout: 10, "the billing warning")
        XCTAssertTrue(warning.label.contains("Settings › your name › Subscriptions"), warning.label)
        snapshot("delete with plus")
        // Leave without deleting.
        tapBack()
        waitUntilGone(warning)
        XCTAssertTrue(app.buttons["Delete account"].waitForExistence(timeout: 5), "still signed in")
    }

    /// This Apple Account already has Plus (here, another account's): the
    /// paywall puts Restore Purchases where buying was, and restoring says
    /// where the subscription is, in an alert that can't be missed.
    func testAnAppleAccountWithPlusIsOfferedRestoreNotBuying() {
        launchToShelf()
        openProfile()
        let elsewhere = app.switches.matching(NSPredicate(format: "label BEGINSWITH 'Simulate: subscription linked elsewhere'")).firstMatch
        scrollTo(elsewhere, maxSwipes: 25)
        elsewhere.switches.firstMatch.tap()
        // The Plan section is further up: back to the top of Profile.
        openProfile()
        let getPlus = app.buttons["Get HuddlePals+"]
        scrollTo(getPlus)
        getPlus.tap()

        waitFor(app.staticTexts["You already have HuddlePals+"], timeout: 10)
        XCTAssertFalse(app.buttons["Try it free for 1 week"].exists, "nothing to buy twice")
        XCTAssertFalse(app.staticTexts["renewalTerms"].exists)
        snapshot("paywall restore instead")
        app.buttons["restoreInstead"].tap()
        let alert = dialog("This Apple Account already has HuddlePals+")
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'linked to another HuddlePals account'")).firstMatch.exists)
        alert.buttons["OK"].tap()
        waitUntilGone(alert)
        waitFor(app.descendants(matching: .any)["paywallMessage"], timeout: 5, "and it stays said on the page")
    }

    /// After the first post opens a huddle, HuddlePals+ is introduced once;
    /// "Remind me later" asks for notifications, and Profile can turn the
    /// reminders off again.
    func testTheFirstPostIntroducesPlusOnceAndRemindersAreOptIn() {
        launchToShelf(arguments: ["-ui-testing-plus-intro"])
        openHuddle("The Crew")
        depositPhoto(caption: "First")
        waitFor(app.staticTexts["Your huddle is open"], timeout: 20, "the intro")
        snapshot("plus intro")
        waitFor(app.buttons["Remind me later"]).tap()
        answerSystemAlert("Allow", timeout: 5)
        waitUntilGone(app.staticTexts["Your huddle is open"], timeout: 10)
        waitFor(app.staticTexts["First"], timeout: 10)

        openProfile()
        let reminders = app.switches.matching(NSPredicate(format: "label BEGINSWITH 'HuddlePals+ reminders'")).firstMatch
        scrollTo(reminders)
        XCTAssertEqual(reminders.switches.firstMatch.value as? String, "1", "asked for on the intro")
        reminders.switches.firstMatch.tap()
        XCTAssertEqual(reminders.switches.firstMatch.value as? String, "0", "and off again")
    }

    /// See HuddlePals+ on the intro leads to the plans, in the same sheet.
    func testTheIntroLeadsToThePlans() {
        launchToShelf(arguments: ["-ui-testing-plus-intro"])
        openHuddle("The Crew")
        depositPhoto()
        waitFor(app.buttons["See HuddlePals+"], timeout: 20).tap()
        waitFor(paywallHeadline("More room for your huddles with HuddlePals+"))
        waitFor(app.staticTexts["renewalTerms"])
        app.buttons["Close"].tap()
        waitUntilGone(app.staticTexts["renewalTerms"])
        waitFor(app.buttons["Archive"], timeout: 10, "back in the huddle")
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

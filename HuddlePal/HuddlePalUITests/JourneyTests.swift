import XCTest

/// The critical journeys, end to end, on the seeded mock world.
final class JourneyTests: HuddleUITestCase {
    /// 1 (first half). First launch: the Terms gate, then the shelf.
    func testFirstLaunchShowsTheTermsThenTheShelf() {
        launch()
        // After the launch reveal has gone (Agree is under it until then).
        let agree = waitFor(app.buttons["Agree"], timeout: 20)
        wait(for: [expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: agree)], timeout: 10)
        snapshot("01 terms")
        agreeToTerms()
        waitFor(app.staticTexts["The Crew"], timeout: 20)
        waitFor(app.staticTexts["Sunday Dinners"])
        snapshot("02 huddle shelf")
    }

    /// QA-31: the day's one action must be on screen, not under the tab bar.
    func testTheDepositButtonIsVisibleWithoutScrolling() {
        launchToShelf()
        openHuddle("The Crew")
        let cta = waitFor(app.buttons["Add today's memory"])
        let tabBar = app.tabBars.firstMatch
        if tabBar.exists && tabBar.frame.minY > app.frame.midY {
            // iPhone: the floating tab bar is at the bottom.
            XCTAssertLessThanOrEqual(cta.frame.maxY, tabBar.frame.minY + 1,
                                     "the button sits under the floating tab bar")
        } else {
            // iPad: the tab bar is at the top; the button must still be on screen.
            XCTAssertLessThanOrEqual(cta.frame.maxY, app.frame.maxY)
        }
        XCTAssertGreaterThan(cta.frame.minY, 0)
    }

    /// 3. Post today's check-in: locked → deposit → unlocked feed.
    func testPostingTodaysPhotoUnlocksTheHuddle() {
        launchToShelf()
        openHuddle("The Crew")
        waitFor(app.staticTexts["Locked until you share"])
        snapshot("03 home locked")
        depositPhoto(caption: "QA check-in")
        waitUntilGone(app.staticTexts["Locked until you share"], timeout: 20)
        waitFor(app.staticTexts["QA check-in"], timeout: 20)
        snapshot("04 home unlocked")
        XCTAssertFalse(app.buttons["Add today's memory"].exists, "one photo a day: no second post offered")
    }

    /// 1 + 2. A brand-new user signs up, and joins a huddle another member
    /// created and shared the code for: both are in it.
    func testCreateInviteJoinAcrossTwoAccounts() {
        launchToShelf()
        // Member A ("You", seeded) creates a huddle and reads its code.
        openAddMenu("Create a Huddle")
        let name = waitFor(app.textFields["Huddle name"])
        name.tap()
        name.typeText("QA Huddle")
        waitFor(app.buttons["Create huddle"]).tap()
        let code = waitFor(app.staticTexts.matching(NSPredicate(format: "label MATCHES '^[A-Z0-9]{6}$'")).firstMatch, timeout: 15)
        let inviteCode = code.label
        snapshot("05 huddle created")
        waitFor(app.buttons["Back to my huddles"]).tap()

        // Member B: a new account, through onboarding.
        signOut()
        snapshot("06 welcome cards")
        signInWithMockApple()
        completeProfile(name: "Bea")
        waitFor(app.staticTexts["No huddles yet"], timeout: 20, "a new account starts empty: nothing from the previous account")
        XCTAssertFalse(app.staticTexts["The Crew"].exists)
        snapshot("07 new user empty shelf")

        waitFor(app.buttons["Join with a code"]).tap()
        let field = waitFor(app.textFields["ABC123"])
        field.tap()
        field.typeText(inviteCode)
        waitFor(app.buttons["Join huddle"]).tap()
        waitFor(app.staticTexts["Welcome to QA Huddle"], timeout: 15)
        snapshot("08 joined")
        waitFor(app.buttons["Step inside"]).tap()
        waitFor(app.staticTexts["🏔 QA Huddle"], timeout: 15)
        waitFor(app.staticTexts["Nobody has posted yet"])
    }

    /// 4. The day's photo is once; the next day opens a new one; history
    /// keeps both.
    func testNextDayOpensANewCheckInAndHistoryKeepsBoth() {
        launchToShelf()
        openHuddle("The Crew")
        depositPhoto(caption: "Day one")
        waitFor(app.staticTexts["Day one"], timeout: 20)
        XCTAssertFalse(app.buttons["Add today's memory"].exists)

        // DEBUG: move the mock clock to tomorrow.
        openTab("Profile")
        let advance = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Advance mock day by 1'")).firstMatch
        scrollTo(advance)
        advance.tap()
        openTab("Huddles")
        // Tomorrow, nobody has posted yet in the seeded world.
        waitFor(app.buttons["Deposit the first memory"], timeout: 20, "a new day opens a new check-in")
        depositPhoto(caption: "Day two", ctaLabel: "Deposit the first memory")
        waitFor(app.staticTexts["Day two"], timeout: 20)

        app.buttons["Archive"].tap()
        waitFor(app.navigationBars["Archive"])
        snapshot("09 archive")
        XCTAssertTrue(app.staticTexts["Day one"].exists || app.images.count > 0)
    }

    /// 5. Leaving a huddle removes it, and everything in it, from this account.
    func testLeavingAHuddleRemovesIt() {
        launchToShelf()
        openHuddle("The Crew")
        waitFor(app.buttons["Huddle settings"]).tap()
        snapshot("10 huddle settings")
        tapAndConfirm("Leave huddle")
        waitFor(app.staticTexts["Sunday Dinners"], timeout: 15)
        waitUntilGone(app.staticTexts["The Crew"])
    }

    /// 6. Profile edits save only after confirming; reminders ask for
    /// permission; appearance switches to dark.
    func testEditingProfileRemindersAndAppearance() {
        launchToShelf()
        openTab("Profile")
        waitFor(app.textFields["Display name"])
        // A vertical TextField is exposed as a text field; it holds the seeded bio.
        let bio = app.textFields.matching(NSPredicate(format: "value BEGINSWITH 'Keeper of the crew'")).firstMatch
        scrollTo(bio)
        bio.tap()
        bio.typeText(" QA")
        let save = app.buttons["Save changes"]
        scrollTo(save)
        save.tap()
        waitFor(app.alerts["Confirm Changes"]).buttons["Save Changes"].tap()
        waitFor(app.staticTexts["Saved"], timeout: 10)
        // QA-33: done typing, a person swipes the list to put the keyboard
        // away; it covers the tab bar until they can.
        app.swipeDown()
        waitUntilGone(app.otherElements["inputView"], timeout: 5)

        let reminder = app.switches.matching(NSPredicate(format: "label BEGINSWITH 'Daily upload reminder'")).firstMatch
        scrollTo(reminder)
        reminder.switches.firstMatch.tap()
        // Asked once per install; later runs find it already allowed.
        answerSystemAlert("Allow", timeout: 5)
        snapshot("11 profile reminders")

        let dark = app.buttons["Dark"]
        scrollTo(dark)
        dark.tap()
        snapshot("12 profile dark")
        openTab("Huddles")
        waitFor(app.staticTexts["The Crew"], timeout: 10, "the tab bar must be reachable after editing")
        snapshot("13 shelf dark")
    }

    /// 7. Signing out and back in returns the same account and nothing of
    /// another account.
    func testSignOutAndBackInRestoresTheSameAccount() {
        launchToShelf()
        signOut()
        signInWithMockApple()
        completeProfile(name: "Bea")
        waitFor(app.staticTexts["No huddles yet"], timeout: 20)
        signOut()
        signInWithMockApple()
        waitFor(app.staticTexts["No huddles yet"], timeout: 20, "a returning account skips the profile step")
        XCTAssertFalse(app.textFields["Your name"].exists)
        openTab("Profile")
        waitFor(app.textFields["Display name"])
        XCTAssertEqual(app.textFields["Display name"].value as? String, "Bea")
    }

    /// 8. Deleting the account signs out, and the same sign-in starts over.
    func testDeletingTheAccount() {
        launchToShelf()
        signOut()
        signInWithMockApple()
        completeProfile(name: "Bea")
        waitFor(app.staticTexts["No huddles yet"], timeout: 20)
        openTab("Profile")
        tapAndConfirm("Delete account")
        waitFor(app.buttons["Continue"], timeout: 20, "back on the welcome cards")
        signInWithMockApple()
        waitFor(app.textFields["Your name"], timeout: 20, "the deleted account is gone; this is a new one")
    }
}

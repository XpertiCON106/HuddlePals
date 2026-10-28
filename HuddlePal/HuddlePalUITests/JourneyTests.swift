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

    /// QA-31: the day's one action must be on screen without scrolling.
    func testTheDepositButtonIsVisibleWithoutScrolling() {
        launchToShelf()
        openHuddle("The Crew")
        let cta = waitFor(app.buttons["Add today's memory"])
        XCTAssertFalse(app.tabBars.firstMatch.exists, "no tab bar: the shelf is the main screen")
        XCTAssertTrue(cta.isHittable)
        XCTAssertLessThanOrEqual(cta.frame.maxY, app.frame.maxY)
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
        let code = waitFor(app.staticTexts["inviteCode"], timeout: 15)
        let inviteCode = code.label
        XCTAssertNotNil(inviteCode.range(of: "^([A-Z0-9]{4}-){7}[A-Z0-9]{4}$", options: .regularExpression), "a new-format code: \(inviteCode)")
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
        let field = waitFor(app.textFields["Invite code"])
        field.tap()
        field.typeText(inviteCode)
        waitFor(app.buttons["Join huddle"]).tap()
        waitFor(app.staticTexts["Welcome to QA Huddle"], timeout: 15)
        snapshot("08 joined")
        waitFor(app.buttons["Step inside"]).tap()
        waitFor(app.staticTexts["🏔 QA Huddle"], timeout: 15)
        waitFor(app.staticTexts["Nobody has posted yet"])

        // 5. A member can leave, and the huddle goes from their shelf.
        waitFor(app.buttons["Huddle settings"]).tap()
        scrollTo(app.buttons["Leave huddle"])
        XCTAssertFalse(app.buttons["Delete huddle"].exists, "only the keeper can delete it")
        tapAndConfirm("Leave huddle")
        waitFor(app.staticTexts["No huddles yet"], timeout: 15)
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
        openProfile()
        let advance = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Advance mock day by 1'")).firstMatch
        scrollTo(advance)
        advance.tap()
        backToShelf()
        openHuddle("The Crew")
        // Tomorrow, nobody has posted yet in the seeded world.
        waitFor(app.buttons["Deposit the first memory"], timeout: 20, "a new day opens a new check-in")
        depositPhoto(caption: "Day two", ctaLabel: "Deposit the first memory")
        waitFor(app.staticTexts["Day two"], timeout: 20)

        app.buttons["Archive"].tap()
        waitFor(app.navigationBars["Archive"])
        snapshot("09 archive")
        XCTAssertTrue(app.staticTexts["Day one"].exists || app.images.count > 0)
    }

    /// 5. A huddle's keeper can't leave it, only delete it.
    func testTheKeeperCanDeleteButNotLeave() {
        launchToShelf()
        openHuddle("The Crew")
        waitFor(app.buttons["Huddle settings"]).tap()
        snapshot("10 huddle settings")
        let delete = app.buttons["Delete huddle"]
        scrollTo(delete)
        XCTAssertTrue(delete.exists)
        XCTAssertFalse(app.buttons["Leave huddle"].exists, "the keeper can't leave")
    }

    /// 5b. Its keeper deletes a huddle: it's gone, for everyone.
    func testTheKeeperDeletesAHuddle() {
        launchToShelf()
        openHuddle("Sunday Dinners")
        waitFor(app.buttons["Huddle settings"]).tap()
        let delete = app.buttons["Delete huddle"]
        scrollTo(delete)
        snapshot("10b delete huddle")
        tapAndConfirm("Delete huddle")
        waitFor(app.staticTexts["The Crew"], timeout: 15)
        waitUntilGone(app.staticTexts["Sunday Dinners"])
    }

    /// 6. Profile edits save only after confirming; reminders ask for
    /// permission; appearance switches to dark.
    func testEditingProfileRemindersAndAppearance() {
        launchToShelf()
        openProfile()
        waitFor(app.textFields["Display name"])
        // A vertical TextField is exposed as a text field; it holds the seeded bio.
        let bio = app.textFields.matching(NSPredicate(format: "value BEGINSWITH 'Keeper of the crew'")).firstMatch
        scrollTo(bio)
        bio.tap()
        bio.typeText(" QA")
        let save = app.buttons["Save changes"]
        scrollTo(save)
        save.tap()
        dialog("Save your changes?").buttons["Save Changes"].tap()
        waitFor(app.staticTexts["Saved"], timeout: 10)
        // QA-33: done typing, a person swipes the list to put the keyboard
        // away.
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
        backToShelf()
        waitFor(app.staticTexts["The Crew"], timeout: 10, "Back must work after editing")
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
        openProfile()
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
        openDeleteAccount()
        snapshot("27 delete account")
        app.buttons["Delete my account"].tap()
        waitFor(app.buttons["Continue"], timeout: 20, "back on the welcome cards")
        signInWithMockApple()
        waitFor(app.textFields["Your name"], timeout: 20, "the deleted account is gone; this is a new one")
    }

    /// 9. App Review 5.1.1(i) and 1.2: the privacy policy, support and a
    /// contact address are one tap away in Profile → About.
    func testProfileLinksToThePrivacyPolicyAndSupport() {
        launchToShelf()
        openProfile()
        for title in ["Privacy Policy", "Help & Support", "Contact Us", "HuddlePals Website"] {
            // SwiftUI exposes a Link in a List row as a button.
            let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
            scrollTo(row)
            XCTAssertTrue(row.exists, "missing link: \(title)")
        }
        snapshot("25 profile about links")
    }

    /// 10. App Review 1.2: a member's profile can be reported from its menu,
    /// and the reporter is thanked.
    func testReportingAMembersProfile() {
        launchToShelf()
        openHuddle("The Crew")
        waitFor(app.buttons["Huddle settings"]).tap()
        waitFor(app.staticTexts["Members"])
        waitFor(app.buttons["Maya"]).tap()
        waitFor(app.buttons["More options"]).tap()
        waitFor(app.buttons["Report Maya"]).tap()
        waitFor(app.staticTexts["Thanks for reporting"], timeout: 10)
        snapshot("26 profile reported")
    }
}

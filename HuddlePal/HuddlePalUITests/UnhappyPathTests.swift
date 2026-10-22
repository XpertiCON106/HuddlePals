import XCTest

/// What happens when things don't go to plan.
final class UnhappyPathTests: HuddleUITestCase {
    func testAWrongInviteCodeSaysSo() {
        launchToShelf()
        openAddMenu("Join with a code")
        let field = waitFor(app.textFields["Invite code"])
        field.tap()
        field.typeText("ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ")
        waitFor(app.buttons["Join huddle"]).tap()
        waitFor(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'No huddle found'")).firstMatch, timeout: 10)
        snapshot("20 wrong invite code")
    }

    /// A 6-character code from before invites carried the huddle key.
    func testAnOldInviteCodeExplainsWhatToAskFor() {
        launchToShelf()
        openAddMenu("Join with a code")
        let field = waitFor(app.textFields["Invite code"])
        field.tap()
        field.typeText("CREW42")
        waitFor(app.buttons["Join huddle"]).tap()
        waitFor(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'older invite code'")).firstMatch, timeout: 10)
        snapshot("23 old invite code")
    }

    /// QA-16: an invite link tapped while signed out opens Join, filled in,
    /// once the person has signed in.
    func testAnInviteLinkOpenedWhileSignedOutSurvivesSignIn() {
        launchToShelf()
        signOut()
        // open(_:) may relaunch with these arguments: keep the signed-out state.
        app.launchArguments.removeAll { $0 == "-ui-testing-reset" }
        app.open(URL(string: "huddlepal://join/crew42")!)
        signInWithMockApple()
        completeProfile(name: "Bea")
        let field = waitFor(app.textFields["Invite code"], timeout: 20, "Join opens by itself")
        XCTAssertEqual(field.value as? String, "CREW42")
        snapshot("21 invite link after sign-in")
    }

    /// QA-11: with camera access refused, Compose explains and links to Settings.
    func testARefusedCameraExplainsAndOffersSettings() {
        launchToShelf(arguments: ["-ui-testing-camera-denied"])
        openHuddle("The Crew")
        waitFor(app.buttons["Add today's memory"]).tap()
        waitFor(app.staticTexts["Camera access is off"])
        waitFor(app.buttons["Open Settings"])
        snapshot("22 camera denied")
    }

    func testRefusingNotificationsShowsHowToTurnThemOn() {
        launchToShelf(arguments: ["-ui-testing-notifications-denied"])
        openTab("Profile")
        let reminder = app.switches.matching(NSPredicate(format: "label BEGINSWITH 'Daily upload reminder'")).firstMatch
        scrollTo(reminder)
        reminder.switches.firstMatch.tap()
        waitFor(app.staticTexts["Notifications are turned off"], timeout: 10)
        XCTAssertEqual(reminder.switches.firstMatch.value as? String, "0", "the reminder stays off when refused")
        waitFor(app.buttons["Open Settings"])
        snapshot("23 notifications denied")
    }

    /// QA-20: when Apple can't confirm the account, it can still be deleted,
    /// and the dialog says how to remove HuddlePals from Sign in with Apple.
    func testDeletingWhenAppleCantConfirmStillWorks() {
        launchToShelf(arguments: ["-ui-testing-apple-unavailable"])
        openTab("Profile")
        tapAndConfirm("Delete account")
        waitFor(app.staticTexts["Apple couldn't confirm it's you"], timeout: 10)
        snapshot("24 apple confirmation failed")
        waitFor(app.buttons["Delete account anyway"]).tap()
        waitFor(app.buttons["Continue"], timeout: 20, "back on the welcome cards")
    }

    func testDecliningTheTermsGoesNowhere() {
        launch()
        waitFor(app.buttons["Decline"], timeout: 20).tap()
        waitFor(app.buttons["Continue"])
        XCTAssertFalse(app.tabBars.firstMatch.exists, "nothing past the welcome cards without Agree")
    }
}

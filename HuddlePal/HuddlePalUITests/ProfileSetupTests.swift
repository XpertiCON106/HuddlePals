import XCTest

/// Age screening happens before authentication or profile collection.
/// Accounts from before birthdays are asked once, and
/// someone signed in can sign out from the Terms to use another account.
final class ProfileSetupTests: HuddleUITestCase {
    func testUnder13StopsBeforeSignInAndTheRefusalSurvivesRelaunch() {
        launchToShelf()
        signOut()
        openAgeScreen()
        XCTAssertFalse(app.buttons["Continue"].isEnabled, "no adult birthday preset")
        XCTAssertFalse(app.buttons["Continue with Apple"].exists)
        XCTAssertFalse(app.textFields["Your name"].exists)
        XCTAssertFalse(app.buttons["Add profile photos"].exists)
        snapshot("30 neutral birthday before sign-in")

        enterBirthday(year: Calendar.current.component(.year, from: .now) - 10)
        app.buttons["Continue"].tap()
        waitFor(app.staticTexts["HuddlePals is for people 13 or older."], timeout: 10)
        XCTAssertFalse(app.buttons["Continue with Apple"].exists, "authentication never starts")
        XCTAssertFalse(app.textFields["Your name"].exists)
        XCTAssertFalse(app.pickerWheels.firstMatch.exists, "no way to replace the rejected birthday")
        XCTAssertFalse(app.buttons["Open my huddle"].exists)
        snapshot("31 under 13")

        app.terminate()
        app.launchArguments.removeAll { $0 == "-ui-testing-reset" }
        app.launch()
        waitFor(app.staticTexts["HuddlePals is for people 13 or older."], timeout: 20)
        XCTAssertFalse(app.buttons["Continue with Apple"].exists)
        XCTAssertFalse(app.pickerWheels.firstMatch.exists)
    }

    func testAgeScreenRequiresAllDateComponentsBeforeSignIn() {
        launchToShelf()
        signOut()
        openAgeScreen()
        let next = app.buttons["Continue"]
        XCTAssertFalse(next.isEnabled)
        let wheels = app.pickerWheels
        waitFor(wheels.element(boundBy: 2))
        wheels.element(boundBy: 0).adjust(toPickerWheelValue: "1")
        XCTAssertFalse(next.isEnabled, "month alone is not a birthday")
        wheels.element(boundBy: 1).adjust(toPickerWheelValue: "1")
        XCTAssertFalse(next.isEnabled, "a year must be selected too")
        wheels.element(boundBy: 2).adjust(toPickerWheelValue: "1990")
        waitUntilEnabled(next)
        next.tap()
        waitFor(app.buttons["Continue with Apple"])
        XCTAssertFalse(app.textFields["Your name"].exists)
    }

    func testTheProfileUsesTheBirthdayAlreadySelectedBeforeSignIn() {
        launchToShelf()
        signOut()
        signInWithMockApple()
        waitFor(app.textFields["Your name"], timeout: 20)
        XCTAssertTrue(app.buttons["Add profile photos"].exists)
        XCTAssertTrue(app.textFields["A short bio (optional)"].exists)
        let birthday = app.descendants(matching: .any)["birthdayRow"]
        XCTAssertEqual(birthday.value as? String, "January 1, 1990")
        XCTAssertFalse(app.buttons["Birthday"].exists, "screened birthdays cannot be replaced on the profile step")
        snapshot("34 screened birthday on profile")
        completeProfile(name: "Kai")
        waitFor(app.navigationBars.buttons["Create or join a huddle"], timeout: 20)
    }

    func testAnAccountFromBeforeIsAskedForItsBirthday() {
        launch(arguments: ["-ui-testing-no-birthday"], termsAgreed: true)
        let question = waitFor(app.staticTexts["When's your birthday?"], timeout: 25, "asked first thing")
        XCTAssertTrue(app.staticTexts["Only you can see it. We ask everyone once."].exists)
        XCTAssertFalse(app.navigationBars.buttons["Create or join a huddle"].exists, "the app shell stays closed")
        XCTAssertFalse(app.buttons["Continue"].isEnabled, "no eligible birthday is assumed")
        snapshot("32 birthday for an account from before")
        enterBirthday()
        app.buttons["Continue"].tap()
        waitUntilGone(question, timeout: 10)
        waitFor(app.staticTexts["The Crew"], timeout: 10)

        openProfile()
        let birthday = app.descendants(matching: .any)["birthdayRow"]
        scrollTo(birthday)
        XCTAssertEqual(birthday.value as? String, "January 1, 1990", "Profile shows it, to its owner only")
        XCTAssertFalse(app.buttons["Birthday"].exists, "and it can't be changed there")
        birthday.tap()
        XCTAssertFalse(app.otherElements["appDialog"].waitForExistence(timeout: 2), "nothing opens")
    }

    func testSomeoneSignedInCanSignOutFromTheTerms() {
        // A first launch signs the seeded account in, with the Terms not yet agreed.
        launch()
        waitFor(app.buttons["Agree"], timeout: 20)
        let signedIn = waitFor(app.staticTexts["Signed in as You."])
        snapshot("33 terms signed in")
        tapAndConfirm("Sign out")
        waitUntilGone(signedIn, timeout: 10)
        waitFor(app.buttons["Continue"], timeout: 10, "back to the start, to sign in with any account")
        XCTAssertFalse(app.buttons["Agree"].exists, "the Terms come after signing in")
    }

    func testBlockedExistingAccountCanStillBeDeletedAfterRelaunch() {
        launch(arguments: ["-ui-testing-no-birthday"], termsAgreed: true)
        waitFor(app.staticTexts["When's your birthday?"], timeout: 25)
        enterBirthday(year: Calendar.current.component(.year, from: .now) - 10)
        app.buttons["Continue"].tap()
        waitFor(app.staticTexts["HuddlePals is for people 13 or older."])
        app.terminate()
        app.launchArguments.removeAll { $0 == "-ui-testing-reset" }
        app.launch()
        waitFor(app.buttons["Delete account"], timeout: 25).tap()
        let field = waitFor(app.textFields["deleteConfirmation"])
        field.tap()
        field.typeText("DELETE")
        waitUntilEnabled(app.buttons["Delete my account"])
        app.buttons["Delete my account"].tap()
        waitUntilGone(field, timeout: 20)
        waitFor(app.buttons["Back to welcome"])
        XCTAssertFalse(app.navigationBars.buttons["Create or join a huddle"].exists)
    }
}

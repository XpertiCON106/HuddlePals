import XCTest

/// Making a profile: a name, a birthday (private, 13 or older), photos, a
/// bio and a colour. Accounts from before birthdays are asked once, and
/// someone signed in can sign out from the Terms to use another account.
final class ProfileSetupTests: HuddleUITestCase {
    func testANewProfileNeedsABirthdayAndUnder13CantContinue() {
        launchToShelf()
        signOut()
        signInWithMockApple()
        let field = waitFor(app.textFields["Your name"], timeout: 20, "the profile step")
        field.tap()
        field.typeText("Kai")
        XCTAssertFalse(app.buttons["Open my huddle"].isEnabled, "not without a birthday")
        XCTAssertTrue(app.buttons["Add profile photos"].exists)
        XCTAssertTrue(app.textFields["A short bio (optional)"].exists)
        snapshot("30 make your profile")

        pickBirthday(year: Calendar.current.component(.year, from: .now) - 10)
        waitFor(app.staticTexts["HuddlePals is for people 13 or older."], timeout: 10)
        XCTAssertFalse(app.textFields["Your name"].exists, "nothing of the profile page, just the notice")
        XCTAssertFalse(app.buttons["Birthday"].exists, "and no way to change the age")
        XCTAssertFalse(app.buttons["Open my huddle"].exists)
        snapshot("31 under 13")
        app.buttons["Sign out"].tap()
        waitFor(app.buttons["Continue"], timeout: 20, "back to the start")
    }

    func testAnAccountFromBeforeIsAskedForItsBirthday() {
        launch(arguments: ["-ui-testing-no-birthday"], termsAgreed: true)
        let question = waitFor(app.staticTexts["When's your birthday?"], timeout: 25, "asked first thing")
        XCTAssertTrue(app.staticTexts["Only you can see it. We ask everyone once."].exists)
        snapshot("32 birthday for an account from before")
        app.buttons["Continue"].tap()
        waitUntilGone(question, timeout: 10)
        waitFor(app.staticTexts["The Crew"], timeout: 10)

        openProfile()
        let birthday = app.buttons["Birthday"]
        scrollTo(birthday)
        XCTAssertEqual(birthday.value as? String, "January 1, 2000", "Profile shows it, to its owner only")
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
}

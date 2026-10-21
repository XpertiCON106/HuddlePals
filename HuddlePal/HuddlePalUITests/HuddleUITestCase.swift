import XCTest

/// Shared plumbing for the UI journeys. Every test launches a fresh first-run
/// app (`-ui-testing` wipes its storage and forces the seeded mock world, so
/// no test can reach a live backend), with a stand-in camera because the
/// Simulator has none.
class HuddleUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-fake-camera"]
    }

    override func tearDownWithError() throws {
        if let run = testRun, run.failureCount > 0, let app {
            snapshot("failure")
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "accessibility tree at failure"
            tree.lifetime = .keepAlways
            add(tree)
        }
    }

    func launch(arguments: [String] = [], environment: [String: String] = [:]) {
        app.launchArguments += arguments
        app.launchEnvironment.merge(environment) { _, new in new }
        app.launch()
    }

    /// A screenshot kept in the result bundle (the QA report's screens).
    func snapshot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @discardableResult
    func waitFor(_ element: XCUIElement, timeout: TimeInterval = 15, _ message: String? = nil,
                 file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), message ?? "missing: \(element)", file: file, line: line)
        return element
    }

    func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval = 15,
                       file: StaticString = #filePath, line: UInt = #line) {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: timeout), .completed, "still there: \(element)", file: file, line: line)
    }

    func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval = 15,
                          file: StaticString = #filePath, line: UInt = #line) {
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: element)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: timeout), .completed, "never enabled: \(element)", file: file, line: line)
    }

    // MARK: Steps shared by journeys

    /// The Terms come first; Agree unlocks once the reader reaches the end.
    func agreeToTerms() {
        let agree = waitFor(app.buttons["Agree"], timeout: 20, "the Terms must be the first screen")
        let document = app.scrollViews.firstMatch
        var swipes = 0
        while !agree.isEnabled && swipes < 60 {
            document.swipeUp(velocity: .fast)
            swipes += 1
        }
        XCTAssertTrue(agree.isEnabled, "Agree never unlocked")
        agree.tap()
    }

    /// First launch lands on the seeded shelf, signed in as "You".
    func launchToShelf(arguments: [String] = [], environment: [String: String] = [:]) {
        launch(arguments: arguments, environment: environment)
        agreeToTerms()
        waitFor(app.staticTexts["The Crew"], timeout: 20, "the seeded shelf")
    }

    func openHuddle(_ name: String) {
        app.buttons.containing(.staticText, identifier: name).firstMatch.tap()
    }

    func openTab(_ name: String) {
        app.tabBars.buttons[name].tap()
    }

    /// Compose → stand-in camera → caption → confirm → post.
    func depositPhoto(caption: String? = nil, ctaLabel: String = "Add today's memory") {
        waitFor(app.buttons[ctaLabel]).tap()
        waitFor(app.buttons["Take test photo"]).tap()
        if let caption {
            let field = waitFor(app.textFields["Add a line… (optional)"])
            field.tap()
            field.typeText(caption)
        }
        let next = waitFor(app.buttons["Continue"])
        waitUntilEnabled(next)
        next.tap()
        waitFor(app.staticTexts["This is permanent"])
        let post = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Post'")).firstMatch
        waitFor(post).tap()
    }

    /// Profile → Sign out → confirm.
    func signOut() {
        openTab("Profile")
        let signOut = app.buttons["Sign out"]
        scrollTo(signOut)
        signOut.tap()
        waitFor(app.sheets.buttons["Sign out"].exists ? app.sheets.buttons["Sign out"] : app.buttons["Sign out"].firstMatch)
        if app.sheets.buttons["Sign out"].exists { app.sheets.buttons["Sign out"].tap() }
        else { app.buttons.matching(identifier: "Sign out").element(boundBy: 1).tap() }
    }

    /// Walks the welcome cards and signs in with the mock "Continue with
    /// Apple" (one fixed identity, distinct from the seeded "You").
    func signInWithMockApple() {
        let start = waitFor(app.buttons["Continue"], timeout: 20)
        start.tap()
        waitFor(app.buttons["Continue"]).tap()
        waitFor(app.buttons["Get started"]).tap()
        if app.buttons["Agree"].waitForExistence(timeout: 3) { agreeToTerms() }
        waitFor(app.buttons["Continue with Apple"]).tap()
    }

    func scrollTo(_ element: XCUIElement, in container: XCUIElement? = nil, maxSwipes: Int = 12) {
        let scroller = container ?? app.collectionViews.firstMatch
        var swipes = 0
        while !element.isHittable && swipes < maxSwipes {
            scroller.swipeUp()
            swipes += 1
        }
    }
}

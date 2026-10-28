import XCTest

/// Shared plumbing for the UI journeys. Every test launches a fresh first-run
/// app (`-ui-testing` forces the seeded mock world, so no test can reach a
/// live backend; `-ui-testing-reset` wipes its storage), with a stand-in
/// camera because the Simulator has none.
class HuddleUITestCase: XCTestCase {
    var app: XCUIApplication!
    /// The Terms' current version (TermsOfService.version). Tests other than
    /// the Terms journey start already agreed, so they don't spend a minute
    /// scrolling the document; if the version moves on, the Terms show and
    /// `launchToShelf` agrees as a person would.
    static let termsVersion = "2026-10-28"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-reset", "-ui-testing-fake-camera"]
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

    func launch(arguments: [String] = [], environment: [String: String] = [:], termsAgreed: Bool = false) {
        if termsAgreed {
            app.launchArguments += ["-huddlepal.terms.acceptedVersion", Self.termsVersion]
        }
        app.launchArguments += arguments
        app.launchEnvironment.merge(environment) { _, new in new }
        app.launch()
    }

    /// A screenshot kept in the result bundle, for checking screens by eye.
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
        launch(arguments: arguments, environment: environment, termsAgreed: true)
        let shelf = app.staticTexts["The Crew"]
        if !shelf.waitForExistence(timeout: 20), app.buttons["Agree"].exists {
            agreeToTerms()
        }
        waitFor(shelf, timeout: 20, "the seeded shelf")
    }

    func openHuddle(_ name: String) {
        app.buttons.containing(.staticText, identifier: name).firstMatch.tap()
    }

    /// Profile, from the shelf's top right (back on the shelf first).
    func openProfile() {
        backToShelf()
        waitFor(app.navigationBars.buttons["Profile"]).tap()
        waitFor(app.navigationBars["Profile"], timeout: 10, "Profile")
    }

    /// Back, one screen at a time, until the huddle shelf shows. Stops at a
    /// warning (an unsaved Profile), for the test to answer.
    func backToShelf(file: StaticString = #filePath, line: UInt = #line) {
        let shelf = app.navigationBars.buttons["Create or join a huddle"]
        for _ in 0..<5 {
            if isHittable(shelf, within: 2) || app.alerts.firstMatch.exists { return }
            app.navigationBars.buttons.firstMatch.tap()
        }
        XCTAssertTrue(isHittable(shelf, within: 5), "never got back to the shelf", file: file, line: line)
    }

    /// The top bar's Back.
    func tapBack() {
        app.navigationBars.buttons.firstMatch.tap()
    }

    func isHittable(_ element: XCUIElement, within timeout: TimeInterval) -> Bool {
        let hittable = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: element)
        return XCTWaiter.wait(for: [hittable], timeout: timeout) == .completed
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

    /// Taps `label` in the row, then the same-named button of the
    /// confirmation dialog it opens (the newest match).
    func tapAndConfirm(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = app.buttons[label]
        scrollTo(row)
        let rowFrame = row.frame
        row.tap()
        // The dialog's button: same label, somewhere else, and tappable
        // (the row underneath is covered by the dialog).
        let matches = app.buttons.matching(identifier: label)
        var confirm: XCUIElement?
        let found = expectation(for: NSPredicate { _, _ in
            for index in 0..<matches.count {
                let candidate = matches.element(boundBy: index)
                if candidate.frame != rowFrame && candidate.isHittable {
                    confirm = candidate
                    return true
                }
            }
            return false
        }, evaluatedWith: NSNull())
        XCTAssertEqual(XCTWaiter.wait(for: [found], timeout: 10), .completed, "no confirmation for \(label)", file: file, line: line)
        confirm?.tap()
    }

    /// Profile → Sign out → confirm.
    func signOut() {
        openProfile()
        tapAndConfirm("Sign out")
        waitFor(app.buttons["Continue"], timeout: 20, "back on the welcome cards")
    }

    /// Answers a system permission alert (notifications, …).
    func answerSystemAlert(_ button: String, timeout: TimeInterval = 10) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let choice = springboard.buttons[button]
        if choice.waitForExistence(timeout: timeout) { choice.tap() }
    }

    /// The onboarding profile step after a first sign-in.
    func completeProfile(name: String) {
        let field = waitFor(app.textFields["Your name"], timeout: 20, "the profile step")
        field.tap()
        field.typeText(name)
        waitFor(app.buttons["Open my huddle"]).tap()
    }

    /// The shelf's + menu.
    func openAddMenu(_ item: String) {
        waitFor(app.buttons["Create or join a huddle"]).tap()
        waitFor(app.buttons[item]).tap()
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

    /// Swipes the screen until `element` exists and can be tapped (lists
    /// create rows lazily, so off-screen rows don't exist yet).
    func scrollTo(_ element: XCUIElement, maxSwipes: Int = 15) {
        var swipes = 0
        while !(element.exists && element.isHittable) && swipes < maxSwipes {
            app.swipeUp()
            swipes += 1
        }
    }
}

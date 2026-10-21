import XCTest

/// The critical journeys, end to end, on the seeded mock world.
final class JourneyTests: HuddleUITestCase {
    /// 1 (first half). First launch: the Terms gate, then the shelf.
    func testFirstLaunchShowsTheTermsThenTheShelf() {
        launch()
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
        let tabBar = waitFor(app.tabBars.firstMatch)
        XCTAssertLessThanOrEqual(cta.frame.maxY, tabBar.frame.minY + 1,
                                 "the button sits under the floating tab bar")
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
}

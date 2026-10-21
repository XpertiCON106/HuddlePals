import XCTest

/// Launch time and scrolling a long history, measured on the seeded world.
final class PerformanceTests: HuddleUITestCase {
    func testLaunchTime() {
        // Terms already agreed, so each measured launch lands on the shelf.
        launchToShelf()
        app.terminate()
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
            let relaunch = XCUIApplication()
            // Mock only, state kept, Terms already agreed: launch to the shelf.
            relaunch.launchArguments = ["-ui-testing", "-huddlepal.terms.acceptedVersion", Self.termsVersion]
            relaunch.launch()
        }
    }

    func testScrollingTheArchive() {
        launchToShelf()
        openHuddle("The Crew")
        waitFor(app.buttons["Archive"]).tap()
        waitFor(app.navigationBars["Archive"])
        let list = app.scrollViews.firstMatch
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric, XCTMemoryMetric(application: app)], options: options) {
            list.swipeUp(velocity: .fast)
            list.swipeUp(velocity: .fast)
            list.swipeDown(velocity: .fast)
            list.swipeDown(velocity: .fast)
        }
    }
}

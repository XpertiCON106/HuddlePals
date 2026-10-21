import XCTest

/// The same screens under other time zones, text sizes and appearance.
final class EnvironmentMatrixTests: HuddleUITestCase {
    /// "Today" follows the device's zone: the date in the Home header, and the
    /// whole seeded day, belong to that zone's calendar day.
    private func assertHomeShowsToday(in zone: String, file: StaticString = #filePath, line: UInt = #line) {
        launchToShelf(environment: ["TZ": zone])
        openHuddle("The Crew")
        var style = Date.FormatStyle.dateTime.weekday(.wide).month().day()
        style.timeZone = TimeZone(identifier: zone)!
        style.locale = Locale(identifier: "en_US")
        let expected = Date.now.formatted(style)
        waitFor(app.staticTexts[expected], timeout: 15, "Home's date in \(zone) should read \(expected)", file: file, line: line)
        waitFor(app.staticTexts["Locked until you share"], file: file, line: line)
        snapshot("tz \(zone)")
    }

    func testTodayInTheFurthestAheadZone() { assertHomeShowsToday(in: "Pacific/Kiritimati") }   // UTC+14
    func testTodayInAFarBehindZone() { assertHomeShowsToday(in: "Pacific/Pago_Pago") }          // UTC-11
    func testTodayInAZoneWithAMissingMidnight() { assertHomeShowsToday(in: "America/Santiago") }

    func testLargestAccessibilityTextSize() {
        launchToShelf(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        snapshot("a11y XXXL shelf")
        openHuddle("The Crew")
        waitFor(app.buttons["Add today's memory"])
        snapshot("a11y XXXL home")
        openTab("Profile")
        snapshot("a11y XXXL profile")
    }

    func testDarkAppearance() {
        launchToShelf(arguments: ["-huddlepal.appearance", "dark"])
        snapshot("dark shelf")
        openHuddle("The Crew")
        waitFor(app.buttons["Add today's memory"])
        snapshot("dark home locked")
        depositPhoto()
        waitUntilGone(app.staticTexts["Locked until you share"], timeout: 20)
        snapshot("dark home unlocked")
    }
}

import XCTest

/// Profile edits must be saved or discarded before leaving Profile: tapping
/// another tab with unsaved changes shows the warning and keeps Profile on
/// screen, and Save or Discard then goes on to that tab.
final class UnsavedProfileTests: HuddleUITestCase {
    func testKeepEditingStaysAndDiscardRestoresThenLeaves() {
        let original = editDisplayName(adding: " QA")

        openTab("Huddles")
        var warning = waitFor(app.alerts["Unsaved Changes"])
        XCTAssertFalse(app.staticTexts["The Crew"].isHittable, "the shelf mustn't show behind the warning")
        warning.buttons["Keep Editing"].tap()
        waitUntilGone(warning)
        XCTAssertTrue(app.textFields["Display name"].isHittable, "still on Profile")
        XCTAssertEqual(app.textFields["Display name"].value as? String, original + " QA", "the edit is kept")

        openTab("Huddles")
        warning = waitFor(app.alerts["Unsaved Changes"])
        warning.buttons["Discard Changes"].tap()
        waitFor(app.staticTexts["The Crew"], timeout: 10, "Discard goes on to the tab that was tapped")

        openTab("Profile")
        XCTAssertEqual(waitFor(app.textFields["Display name"]).value as? String, original, "the edit is gone")
    }

    func testSaveFromTheWarningSavesThenLeaves() {
        let original = editDisplayName(adding: " QA")

        openTab("Huddles")
        waitFor(app.alerts["Unsaved Changes"]).buttons["Save Changes"].tap()
        waitFor(app.staticTexts["The Crew"], timeout: 10, "Save goes on to the tab that was tapped")

        openTab("Profile")
        XCTAssertEqual(waitFor(app.textFields["Display name"]).value as? String, original + " QA", "the edit was saved")
        openTab("Huddles")
        waitFor(app.staticTexts["The Crew"], timeout: 10, "nothing unsaved now: no warning")
        XCTAssertFalse(app.alerts["Unsaved Changes"].exists)
    }

    /// Opens Profile and types onto the end of the display name. Returns the
    /// name before the edit.
    private func editDisplayName(adding suffix: String) -> String {
        launchToShelf()
        openTab("Profile")
        let field = waitFor(app.textFields["Display name"])
        let original = field.value as? String ?? ""
        field.tap()
        field.typeText(suffix)
        // Put the keyboard away: it covers the tab bar.
        app.swipeDown()
        waitUntilGone(app.otherElements["inputView"], timeout: 5)
        return original
    }
}

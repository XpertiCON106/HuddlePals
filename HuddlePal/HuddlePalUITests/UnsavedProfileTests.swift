import XCTest

/// Profile edits must be saved or discarded before leaving Profile: Back
/// with unsaved changes shows the warning and keeps Profile on screen, a
/// swipe from the edge doesn't leave either, and Save or Discard then goes
/// back to the shelf.
final class UnsavedProfileTests: HuddleUITestCase {
    func testKeepEditingStaysAndDiscardRestoresThenLeaves() {
        let original = editDisplayName(adding: " QA")

        tapBack()
        var warning = dialog("Unsaved Changes")
        XCTAssertFalse(app.staticTexts["The Crew"].isHittable, "the shelf mustn't show behind the warning")
        warning.buttons["Keep Editing"].tap()
        waitUntilGone(warning)
        XCTAssertTrue(app.textFields["Display name"].isHittable, "still on Profile")
        XCTAssertEqual(app.textFields["Display name"].value as? String, original + " QA", "the edit is kept")

        tapBack()
        warning = dialog("Unsaved Changes")
        warning.buttons["Discard Changes"].tap()
        waitFor(app.staticTexts["The Crew"], timeout: 10, "Discard goes on back to the shelf")

        openProfile()
        XCTAssertEqual(waitFor(app.textFields["Display name"]).value as? String, original, "the edit is gone")
    }

    func testSaveFromTheWarningSavesThenLeaves() {
        let original = editDisplayName(adding: " QA")

        tapBack()
        dialog("Unsaved Changes").buttons["Save Changes"].tap()
        waitFor(app.staticTexts["The Crew"], timeout: 10, "Save goes on back to the shelf")

        openProfile()
        XCTAssertEqual(waitFor(app.textFields["Display name"]).value as? String, original + " QA", "the edit was saved")
        tapBack()
        waitFor(app.staticTexts["The Crew"], timeout: 10, "nothing unsaved now: no warning")
        XCTAssertFalse(app.otherElements["appDialog"].exists)
    }

    /// A swipe from the left edge would leave without asking: it's off
    /// while there are unsaved changes.
    func testSwipingBackDoesntLeaveUnsavedChanges() {
        _ = editDisplayName(adding: " QA")
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        XCTAssertTrue(app.textFields["Display name"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["Display name"].isHittable, "still on Profile")
        XCTAssertFalse(app.staticTexts["The Crew"].isHittable)
    }

    /// Opens Profile and types onto the end of the display name. Returns the
    /// name before the edit.
    private func editDisplayName(adding suffix: String) -> String {
        launchToShelf()
        openProfile()
        let field = waitFor(app.textFields["Display name"])
        let original = field.value as? String ?? ""
        field.tap()
        field.typeText(suffix)
        // Put the keyboard away.
        app.swipeDown()
        waitUntilGone(app.otherElements["inputView"], timeout: 5)
        return original
    }
}

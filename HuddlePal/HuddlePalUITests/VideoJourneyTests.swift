import XCTest

/// Video drops end to end in the seeded world: the seeded clip plays in its
/// detail screen, and someone with Plus records one with the stand-in camera
/// (`-ui-testing-fake-camera`) and sees it loop in the feed. Screenshots are
/// kept in the result bundle, since a playing picture can't be asserted.
final class VideoJourneyTests: HuddleUITestCase {
    /// Maya's post yesterday is a video: its tile in the archive is badged,
    /// and its detail screen plays it.
    func testTheSeededVideoPlaysInItsDetailScreen() {
        launchToShelf()
        openHuddle("The Crew")
        waitFor(app.buttons["Archive"]).tap()
        waitFor(app.navigationBars["Archive"])
        let tile = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Video'")).firstMatch
        waitFor(tile, timeout: 20, "the video's tile carries its badge")
        snapshot("video archive tile")
        tile.tap()

        let player = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Video by Maya'")).firstMatch
        waitFor(player, timeout: 20, "the detail screen shows the video")
        // Long enough for the clip to start looping from memory.
        sleep(2)
        snapshot("video detail playing")
    }

    /// With Plus (Profile → DEBUG), Compose offers Video; the stand-in camera
    /// "records" a clip, it previews looping, posts, and loops in the feed.
    func testAPlusMemberPostsAVideoAndItLoopsInTheFeed() {
        launchToShelf()
        openProfile()
        let plus = app.switches.matching(NSPredicate(format: "label BEGINSWITH 'Simulate: HuddlePals+'")).firstMatch
        scrollTo(plus)
        plus.switches.firstMatch.tap()
        XCTAssertEqual(plus.switches.firstMatch.value as? String, "1", "Plus is on")
        backToShelf()
        openHuddle("The Crew")

        waitFor(app.buttons["Add today's memory"]).tap()
        // The photo camera opens first; switch to video instead.
        waitFor(app.buttons["Take test photo"])
        app.buttons["Cancel"].firstMatch.tap()
        waitFor(app.buttons["Video"]).tap()
        waitFor(app.buttons["Record test video"], timeout: 15).tap()
        waitFor(app.otherElements.matching(NSPredicate(format: "label BEGINSWITH 'Your video'")).firstMatch, timeout: 20)
        sleep(1)
        snapshot("compose video preview")

        // A 9:16 recording, as a phone makes: the buttons stay on screen.
        let next = waitFor(app.buttons["Continue"])
        waitUntilEnabled(next)
        XCTAssertTrue(next.isHittable, "Continue on screen")
        XCTAssertLessThanOrEqual(next.frame.maxY, app.frame.maxY)
        next.tap()
        waitFor(app.staticTexts["This is permanent"])
        let post = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Post'")).firstMatch
        waitFor(post)
        snapshot("compose video confirm")
        XCTAssertTrue(post.isHittable, "Post on screen")
        XCTAssertLessThanOrEqual(post.frame.maxY, app.frame.maxY)
        post.tap()

        let mine = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Video by You'")).firstMatch
        waitFor(mine, timeout: 25, "the posted video is in today's feed")
        sleep(2)
        snapshot("feed video looping")
    }
}

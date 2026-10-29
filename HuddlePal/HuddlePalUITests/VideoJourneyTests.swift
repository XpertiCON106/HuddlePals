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

        // A tap pauses it, with a play button on it; another tap plays it.
        player.tap()
        let paused = expectation(for: NSPredicate(format: "value == 'Paused'"), evaluatedWith: player)
        wait(for: [paused], timeout: 5)
        snapshot("video detail paused")
        player.tap()
        let playing = expectation(for: NSPredicate(format: "value != 'Paused'"), evaluatedWith: player)
        wait(for: [playing], timeout: 5)
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
        // Switching keeps the camera closed until it's tapped.
        XCTAssertFalse(app.buttons["Record test video"].waitForExistence(timeout: 2), "the switch didn't open the camera")
        waitFor(app.buttons["Open camera"]).tap()
        waitFor(app.buttons["Record test video"], timeout: 15).tap()
        waitFor(app.otherElements.matching(NSPredicate(format: "label BEGINSWITH 'Your video'")).firstMatch, timeout: 20)
        sleep(1)
        snapshot("compose video preview")

        // It plays with its sound on, pauses, and trims: the start dragged
        // up to the end keeps the shortest part, a second.
        XCTAssertTrue(waitFor(app.buttons["Mute"]).exists, "the sound is on")
        waitFor(app.buttons["Pause"]).tap()
        waitFor(app.buttons["Play"], timeout: 5, "paused")
        let start = waitFor(app.otherElements["Start of the clip"], timeout: 10)
        let end = waitFor(app.otherElements["End of the clip"])
        start.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: end.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        waitFor(app.otherElements["Your video, 1 seconds"], timeout: 10, "a second kept")
        waitFor(app.buttons["Pause"], timeout: 5, "the kept part plays")
        snapshot("compose video trimmed")

        // A 9:16 recording, as a phone makes: the buttons stay on screen.
        let next = waitFor(app.buttons["Continue"])
        waitUntilEnabled(next)
        XCTAssertTrue(next.isHittable, "Continue on screen")
        XCTAssertLessThanOrEqual(next.frame.maxY, app.frame.maxY)
        next.tap()
        waitFor(app.staticTexts["This is permanent"], timeout: 15)
        waitFor(app.otherElements["Your video, 1 seconds"], timeout: 10, "posted as trimmed")
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

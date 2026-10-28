import XCTest
@testable import HuddlePal

/// The huddle spinner's movement: once round every 2.4 seconds, pulling in
/// over the first half and spreading out over the second.
final class HuddleSpinnerTests: XCTestCase {
    func testItTurnsOnceRoundEveryTurn() {
        let turn = HuddleSpinner.turn
        XCTAssertEqual(HuddleSpinner.rotation(at: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(HuddleSpinner.rotation(at: turn / 2), .pi, accuracy: 1e-9)
        XCTAssertEqual(HuddleSpinner.rotation(at: turn - 1e-6), 2 * .pi, accuracy: 1e-4)
        XCTAssertEqual(HuddleSpinner.rotation(at: 3 * turn + 0.5), HuddleSpinner.rotation(at: 0.5), accuracy: 1e-9)
        // Always moving on, never back.
        var last = -1.0
        for step in 0..<240 {
            let angle = HuddleSpinner.rotation(at: Double(step) * turn / 240)
            XCTAssertGreaterThan(angle, last)
            last = angle
        }
    }

    func testTheyHuddleThenSpreadOutAgain() {
        let turn = HuddleSpinner.turn
        XCTAssertEqual(HuddleSpinner.gather(at: 0), 1, accuracy: 1e-9, "spread out")
        XCTAssertEqual(HuddleSpinner.gather(at: turn / 2), 0.42, accuracy: 1e-9, "huddled")
        XCTAssertEqual(HuddleSpinner.gather(at: turn - 1e-6), 1, accuracy: 1e-4, "spread out again")
        for step in 0..<240 {
            let gather = HuddleSpinner.gather(at: Double(step) * turn / 240)
            XCTAssertTrue((0.42...1).contains(gather), "\(gather)")
        }
    }
}

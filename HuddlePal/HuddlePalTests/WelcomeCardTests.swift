import XCTest
@testable import HuddlePal

/// The welcome cards: the first card's day goes from 1 to 7 and starts
/// again, and the cards say what they show without slogans.
final class WelcomeCardTests: XCTestCase {
    func testTheDayGoesUpToSevenThenStartsAgain() {
        let day = DayGoesByScene.day
        let snap = DayGoesByScene.snapAt
        XCTAssertEqual(DayGoesByScene.dayNumber(at: 0), 1)
        XCTAssertEqual(DayGoesByScene.dayNumber(at: snap), 2, "each snap is a new day")
        XCTAssertEqual(DayGoesByScene.dayNumber(at: 5 * day + snap), 7)
        XCTAssertEqual(DayGoesByScene.dayNumber(at: 6 * day + snap - 0.01), 7)
        XCTAssertEqual(DayGoesByScene.dayNumber(at: 6 * day + snap), 1, "after day 7, day 1 again")
        let shown = Set(stride(from: 0, to: 30 * day, by: 0.5).map(DayGoesByScene.dayNumber(at:)))
        XCTAssertEqual(shown, Set(1...7))
    }

    func testTheLockedCardJustSaysWhatHappens() {
        let locked = OnboardingViewModel.cards[1]
        XCTAssertEqual(locked.message, "Today's photos stay blurred until you deposit your own.")
    }
}

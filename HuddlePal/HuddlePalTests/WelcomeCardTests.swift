import XCTest
@testable import HuddlePal

/// The welcome cards: the first card's day goes from 1 to 7 and starts
/// again, and the cards say what they show without slogans.
@MainActor
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

    /// Away on another card, the day stands still: back on it, it carries
    /// on from where it was, not ahead by the time away.
    func testTheDayStandsStillWhileItsCardIsAway() {
        var clock = PausableClock()
        let now = Date()
        clock.pause(at: now)
        let before = clock.time(at: now)
        clock.resume(at: now.addingTimeInterval(100))
        XCTAssertEqual(clock.time(at: now.addingTimeInterval(103)), before + 3, accuracy: 0.001)
        clock.pause(at: now.addingTimeInterval(105))
        XCTAssertEqual(clock.time(at: now.addingTimeInterval(500)), before + 5, accuracy: 0.001)
    }

    func testTheLockedCardJustSaysWhatHappens() {
        let locked = OnboardingViewModel.cards[1]
        XCTAssertEqual(locked.message, "Today's photos stay blurred until you deposit your own.")
    }
}

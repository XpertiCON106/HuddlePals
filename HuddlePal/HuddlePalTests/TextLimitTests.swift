import XCTest

@testable import HuddlePal

/// QA-17: every text limit is applied the way the database checks it
/// (`char_length`, code points), so anything the app accepts the server
/// accepts too.
@MainActor
final class TextLimitTests: XCTestCase {
    func testServerLengthCountsCodePointsNotCharacters() {
        XCTAssertEqual("abc".serverLength, 3)
        XCTAssertEqual("❤️".count, 1)
        XCTAssertEqual("❤️".serverLength, 2, "heart + variation selector")
        XCTAssertEqual("👨‍👩‍👧‍👦".serverLength, 7, "four people joined by three zero-width joiners")
    }

    func testPrefixKeepsWholeCharactersWithinTheLimit() {
        XCTAssertEqual("hello".prefix(serverLength: 3), "hel")
        XCTAssertEqual("a❤️b".prefix(serverLength: 2), "a", "never half a heart")
        XCTAssertEqual("a❤️b".prefix(serverLength: 3), "a❤️")
        XCTAssertEqual("👨‍👩‍👧‍👦👨‍👩‍👧‍👦".prefix(serverLength: 10), "👨‍👩‍👧‍👦")
        XCTAssertEqual("short".prefix(serverLength: 100), "short")
    }

    func testCaptionsAndBiosFitTheDatabaseEvenWhenEmojiHeavy() {
        let hearts = String(repeating: "❤️", count: 80) // 80 characters, 160 code points
        let caption = HuddleEngine.sanitizedCaption(hearts)
        XCTAssertLessThanOrEqual(caption?.serverLength ?? 0, HuddleEngine.captionLimit)
        XCTAssertEqual(caption?.count, 40)
        let bio = AuthValidation.sanitizedBio(String(repeating: "👨‍👩‍👧‍👦", count: 40))
        XCTAssertLessThanOrEqual(bio?.serverLength ?? 0, AuthValidation.bioLimit)
    }

    func testHuddleNamesOverTheServerLimitCannotBeCreated() {
        let viewModel = CreateHuddleViewModel(deps: AppDependencies.makeMock(inMemory: true))
        viewModel.name = String(repeating: "a", count: 60)
        XCTAssertTrue(viewModel.canCreate)
        viewModel.name = String(repeating: "a", count: 61)
        XCTAssertFalse(viewModel.canCreate, "the server refuses names over 60 with a generic error")
        viewModel.name = String(repeating: "❤️", count: 31) // 31 characters, 62 code points
        XCTAssertFalse(viewModel.canCreate)
    }

    func testOnboardingNamesOverTheServerLimitCannotBeSaved() {
        let viewModel = OnboardingViewModel(deps: AppDependencies.makeMock(inMemory: true))
        viewModel.displayName = String(repeating: "a", count: 40)
        XCTAssertTrue(viewModel.canCompleteProfile)
        viewModel.displayName = String(repeating: "a", count: 41)
        XCTAssertFalse(viewModel.canCompleteProfile)
    }
}

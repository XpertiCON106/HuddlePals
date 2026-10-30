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
        XCTAssertEqual(AuthValidation.bioLimit, 30)
        XCTAssertEqual(AuthValidation.sanitizedBio(String(repeating: "a", count: 60))?.count, 30)
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

    func testOnboardingNamesOverTenCharactersCannotBeSaved() {
        let viewModel = OnboardingViewModel(deps: AppDependencies.makeMock(inMemory: true))
        viewModel.birthdayPicked(Birthday(year: 1990, month: 1, day: 1))
        XCTAssertEqual(AuthValidation.displayNameLimit, 10)
        viewModel.displayName = String(repeating: "a", count: 10)
        XCTAssertTrue(viewModel.canCompleteProfile)
        viewModel.displayName = String(repeating: "a", count: 11)
        XCTAssertFalse(viewModel.canCompleteProfile)
    }

    /// A cut that ends on a space is trimmed, so the same bio always comes
    /// out the same: opening Profile with a longer bio changes nothing.
    func testACutBioComesOutTheSameEveryTime() async throws {
        let long = "Keeper of the crew. One photo at a time." // 30 characters in is a space
        let once = AuthValidation.sanitizedBio(long)
        XCTAssertEqual(once, "Keeper of the crew. One photo")
        XCTAssertEqual(AuthValidation.sanitizedBio(once), once)

        let deps = AppDependencies.makeMock(inMemory: true)
        let user = try await deps.auth.completeProfile(displayName: "Sam", avatarColorHex: "E5484D", birthday: Birthday(year: 1990, month: 1, day: 1))
        user.bio = long
        deps.session.currentUser = user
        let profile = ProfileViewModel(deps: deps)
        await profile.loadInitialState()
        XCTAssertEqual(profile.bio, "Keeper of the crew. One photo")
        XCTAssertFalse(profile.hasUnsavedChanges, "opening Profile changes nothing")
    }

    /// A name saved before the limit keeps working: the rest of the profile
    /// still saves, until the name itself is edited.
    func testAnOlderLongerNameStaysUntilItsEdited() async throws {
        let deps = AppDependencies.makeMock(inMemory: true)
        deps.session.currentUser = try await deps.auth.completeProfile(displayName: "Alexandria Q", avatarColorHex: "E5484D", birthday: Birthday(year: 1990, month: 1, day: 1))
        let profile = ProfileViewModel(deps: deps)
        await profile.loadInitialState()
        XCTAssertEqual(profile.displayName, "Alexandria Q", "shown as it is")
        XCTAssertFalse(profile.hasUnsavedChanges, "nothing changed by opening Profile")
        XCTAssertTrue(profile.isDraftValid)
        profile.displayName = "Alexandria Qu"
        XCTAssertFalse(profile.isDraftValid, "an edit must fit the limit")
        profile.displayName = "Alexandria"
        XCTAssertTrue(profile.isDraftValid)
    }
}

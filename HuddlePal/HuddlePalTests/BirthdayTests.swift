import XCTest

@testable import HuddlePal

/// Birthdays: the Terms' minimum age (13), asked when a profile is made and
/// once of accounts from before, and kept to their owner. Also: a huddle
/// deleted while it's open says so instead of loading.
@MainActor
final class BirthdayTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)

    override func tearDown() async throws {
        // The mock keeps its session in the standard defaults: leave it as found.
        UserDefaults.standard.removeObject(forKey: "huddlepal.mock.signedOutExplicitly")
        UserDefaults.standard.removeObject(forKey: "huddlepal.mock.currentUserID")
        try await super.tearDown()
    }

    private func noon(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private var twelveYearsAgo: Birthday {
        Birthday(date: Calendar.current.date(byAdding: .year, value: -12, to: .now)!)
    }

    // MARK: The rule

    func testAgeCountsWholeYearsAndTurnsOnTheDay() {
        let birthday = Birthday(year: 2013, month: 10, day: 29)
        XCTAssertEqual(birthday.age(on: noon(2026, 10, 28), calendar: calendar), 12)
        XCTAssertFalse(birthday.isOldEnough(on: noon(2026, 10, 28), calendar: calendar))
        XCTAssertEqual(birthday.age(on: noon(2026, 10, 29), calendar: calendar), 13)
        XCTAssertTrue(birthday.isOldEnough(on: noon(2026, 10, 29), calendar: calendar))
        XCTAssertEqual(Birthday.minimumAge, 13, "the Terms' 2.1")
    }

    func testADateRoundTripsAsPostgresWritesIt() {
        let birthday = Birthday(year: 1995, month: 6, day: 4)
        XCTAssertEqual(birthday.isoDate, "1995-06-04")
        XCTAssertEqual(Birthday(isoDate: "1995-06-04"), birthday)
        XCTAssertNil(Birthday(isoDate: "1995-13-04"))
        XCTAssertNil(Birthday(isoDate: "June 4"))
        XCTAssertEqual(Birthday(date: birthday.date(in: calendar), calendar: calendar), birthday)
    }

    // MARK: Making a profile

    private func profileStep() -> (AppDependencies, OnboardingViewModel) {
        let deps = AppDependencies.makeMock(inMemory: true)
        let onboarding = OnboardingViewModel(deps: deps)
        onboarding.displayName = "Bea"
        return (deps, onboarding)
    }

    func testAProfileIsMadeWithItsBirthdayPhotoAndBio() async throws {
        let (deps, onboarding) = profileStep()
        XCTAssertFalse(onboarding.canCompleteProfile, "not without a birthday")
        onboarding.birthdayPicked(Birthday(year: 1990, month: 1, day: 1))
        onboarding.bio = "Hello there"
        onboarding.addPhotoData(PlaceholderImageGenerator.jpegData(seed: 7))
        XCTAssertTrue(onboarding.canCompleteProfile)

        await onboarding.completeProfile()

        let user = try XCTUnwrap(deps.session.currentUser)
        XCTAssertEqual(user.displayName, "Bea")
        XCTAssertEqual(user.bio, "Hello there")
        XCTAssertEqual(user.profilePhotoPaths.count, 1, "the photo is saved with the profile")
        let saved = try await deps.auth.birthday()
        XCTAssertEqual(saved, Birthday(year: 1990, month: 1, day: 1))
    }

    func testUnder13StopsThereAndTheAgeCantBeChangedToGetPast() {
        let (_, onboarding) = profileStep()
        onboarding.birthdayPicked(twelveYearsAgo)
        XCTAssertTrue(onboarding.isUnderage)
        XCTAssertFalse(onboarding.canCompleteProfile)
        onboarding.birthdayPicked(Birthday(year: 1990, month: 1, day: 1))
        XCTAssertTrue(onboarding.isUnderage, "the age stays as given")
        XCTAssertEqual(onboarding.birthday, twelveYearsAgo)
    }

    func testTheServiceRefusesUnder13Too() async throws {
        let deps = AppDependencies.makeMock(inMemory: true)
        _ = try await deps.auth.completeProfile(displayName: "Kid", avatarColorHex: "E5484D")
        do {
            try await deps.auth.saveBirthday(twelveYearsAgo)
            XCTFail("saved a birthday under 13")
        } catch AuthError.underMinimumAge {
            // As the server's rule does.
        }
        let saved = try await deps.auth.birthday()
        XCTAssertNil(saved)
    }

    // MARK: Accounts from before

    func testAnAccountWithoutABirthdayIsAskedUntilItGivesOne() async throws {
        let deps = AppDependencies.makeMock(inMemory: true)
        deps.session.currentUser = try await deps.auth.completeProfile(displayName: "Old", avatarColorHex: "E5484D")
        await deps.checkBirthday()
        XCTAssertTrue(deps.session.needsBirthday)

        try await deps.auth.saveBirthday(Birthday(year: 1990, month: 5, day: 5))
        await deps.checkBirthday()
        XCTAssertFalse(deps.session.needsBirthday)

        deps.session.needsBirthday = true
        await deps.endSession()
        XCTAssertFalse(deps.session.needsBirthday, "nobody signed in, nothing to ask")
    }

    // MARK: Profile

    /// Profile shows the birthday given at sign-up; there's no changing it there.
    func testProfileShowsTheBirthdayGivenAtSignUp() async throws {
        let deps = AppDependencies.makeMock(inMemory: true)
        deps.session.currentUser = try await deps.auth.completeProfile(displayName: "Pat", avatarColorHex: "E5484D")
        let profile = ProfileViewModel(deps: deps)
        await profile.loadBirthday()
        XCTAssertNil(profile.birthday)

        try await deps.auth.saveBirthday(Birthday(year: 1991, month: 2, day: 3))
        await profile.loadBirthday()
        XCTAssertEqual(profile.birthday, Birthday(year: 1991, month: 2, day: 3))
    }

    // MARK: A huddle deleted while it's open

    func testAHuddleThisAccountIsNoLongerInSaysSoInsteadOfLoading() async throws {
        let deps = AppDependencies.makeMock(inMemory: true)
        try await deps.seeder.regenerate()
        guard case .signedIn(let you) = try await deps.auth.currentState() else {
            throw XCTSkip("expected the seeded user to be signed in")
        }
        deps.session.currentUser = you
        let huddles = try await deps.huddleService.huddles(for: you)
        let crew = try XCTUnwrap(huddles.first { $0.inviteCode == SeedDataService.crewInviteCode })
        let home = HuddleHomeViewModel(deps: deps, huddle: crew)
        await home.refresh()
        XCTAssertFalse(home.wasDeleted)
        XCTAssertFalse(home.todayDeposits.isEmpty)

        // Its keeper deleted it on another phone: this account's membership is gone.
        let mine = try XCTUnwrap(crew.memberships.first { $0.user?.id == you.id })
        deps.modelContainer.mainContext.delete(mine)
        try deps.modelContainer.mainContext.save()
        await home.refresh()
        XCTAssertTrue(home.wasDeleted)
    }
}

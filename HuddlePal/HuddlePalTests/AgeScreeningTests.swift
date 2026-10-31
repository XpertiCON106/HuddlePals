import XCTest

@testable import HuddlePal

@MainActor
final class AgeScreeningTests: XCTestCase {
    private let calendar = Birthday.eligibilityCalendar

    private func instant(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "AgeScreeningTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    func testNewScreenHasNoAdultBirthdayAndRejectsImpossibleOrFutureDates() {
        let screen = AgeScreening(defaults: nil)
        let now = instant(2026, 10, 29)
        XCTAssertNil(screen.birthday)
        XCTAssertFalse(screen.hasEligibleBirthday(at: now))
        for date in [Birthday(year: 2025, month: 2, day: 29), Birthday(year: 0, month: 1, day: 1),
                     Birthday(year: 2026, month: 13, day: 1), Birthday(year: 2026, month: 10, day: 30)] {
            XCTAssertFalse(screen.submit(date, now: now))
            XCTAssertNil(screen.birthday)
            XCTAssertNil(screen.retryOn, "invalid input must not create an age refusal")
        }
        XCTAssertNil(Birthday(isoDate: "1995-06-04T00:00:00Z"))
        XCTAssertNil(Birthday(isoDate: "1995-6-04"))
        XCTAssertNil(Birthday(isoDate: "2013-02-29"))
        XCTAssertNotNil(Birthday(isoDate: "2000-02-29"))
        XCTAssertEqual(calendar.identifier, .gregorian)
        XCTAssertEqual(calendar.timeZone.secondsFromGMT(), 0)
    }

    func testRejectedBirthdayIsNotRetainedAndRelaunchCannotChangeTheAnswer() {
        withDefaults { defaults in
            let now = instant(2026, 10, 29)
            let screen = AgeScreening(defaults: defaults)
            XCTAssertFalse(screen.submit(Birthday(year: 2013, month: 10, day: 30), now: now))
            XCTAssertNil(screen.birthday)
            XCTAssertNil(defaults.string(forKey: "huddlepal.age.pendingBirthday"))
            XCTAssertEqual(screen.retryOn, Birthday(year: 2026, month: 10, day: 30))

            screen.clearPendingBirthday()
            let reopened = AgeScreening(defaults: defaults)
            XCTAssertTrue(reopened.isBlocked(at: now))
            XCTAssertFalse(reopened.submit(Birthday(year: 1990, month: 1, day: 1), now: now))
            XCTAssertNil(reopened.birthday)
            XCTAssertEqual(reopened.retryOn, screen.retryOn)
        }
    }

    func testRefusalExpiresAtTheUTCThirteenthBirthdayIncludingLeapDay() {
        let screen = AgeScreening(defaults: nil)
        let birthday = Birthday(year: 2013, month: 10, day: 30)
        XCTAssertFalse(screen.submit(birthday, now: instant(2026, 10, 29)))
        let boundary = instant(2026, 10, 30)
        XCTAssertTrue(screen.isBlocked(at: boundary.addingTimeInterval(-1)))
        XCTAssertFalse(screen.isBlocked(at: boundary))
        XCTAssertTrue(screen.submit(birthday, now: boundary))

        let leapScreen = AgeScreening(defaults: nil)
        let leapBirthday = Birthday(year: 2012, month: 2, day: 29)
        XCTAssertFalse(leapScreen.submit(leapBirthday, now: instant(2025, 2, 28)))
        XCTAssertEqual(leapScreen.retryOn, Birthday(year: 2025, month: 3, day: 1))
        XCTAssertTrue(leapScreen.isBlocked(at: instant(2025, 3, 1).addingTimeInterval(-1)))
        XCTAssertTrue(leapScreen.submit(leapBirthday, now: instant(2025, 3, 1)))
    }

    func testEligibleBirthdayResumesAcrossRelaunchAndClearsAfterRecording() {
        withDefaults { defaults in
            let screen = AgeScreening(defaults: defaults)
            let birthday = Birthday(year: 1990, month: 1, day: 1)
            XCTAssertTrue(screen.submit(birthday))
            XCTAssertEqual(AgeScreening(defaults: defaults).birthday, birthday)
            screen.clearPendingBirthday()
            XCTAssertNil(AgeScreening(defaults: defaults).birthday)
        }
    }

    func testWelcomeRequiresAgeBeforeAnyDirectAuthenticationCall() async {
        let auth = AgeGateAuthSpy()
        let deps = dependencies(auth: auth)
        let onboarding = OnboardingViewModel(deps: deps)
        XCTAssertNil(onboarding.birthday)
        onboarding.pageIndex = OnboardingViewModel.cards.count - 1
        onboarding.advanceWelcome()
        XCTAssertEqual(onboarding.step, .age)

        onboarding.step = .method
        await onboarding.mockAppleSignIn()
        onboarding.emailInput = "person@example.test"
        await onboarding.sendCode()
        onboarding.displayName = "Pat"
        await onboarding.completeProfile()
        XCTAssertEqual(auth.authenticationCalls, 0)
        XCTAssertEqual(auth.profileCalls, 0)
        XCTAssertEqual(onboarding.step, .age)
        XCTAssertNil(deps.session.currentUser)

        onboarding.continueAfterAgeCheck(Birthday(year: 1990, month: 1, day: 1))
        XCTAssertEqual(onboarding.step, .method)
        await onboarding.mockAppleSignIn()
        XCTAssertEqual(auth.authenticationCalls, 1)
    }

    func testBootstrapKeepsLegacyAccountPendingAndLookupFailureCannotActivateIt() async {
        let auth = AgeGateAuthSpy()
        auth.state = .needsBirthday(auth.user)
        let deps = dependencies(auth: auth)
        await RootViewModel(deps: deps).bootstrap()
        XCTAssertNil(deps.session.currentUser)
        XCTAssertEqual(deps.session.pendingBirthdayUser?.id, auth.user.id)

        let failedAuth = AgeGateAuthSpy()
        failedAuth.stateError = URLError(.notConnectedToInternet)
        let failedDeps = dependencies(auth: failedAuth)
        let root = RootViewModel(deps: failedDeps)
        await root.bootstrap()
        XCTAssertNil(failedDeps.session.currentUser)
        XCTAssertNotNil(root.bootstrapError)
    }

    func testLegacyBirthdaySaveWaitsForConfirmedAuthState() async {
        let auth = AgeGateAuthSpy()
        let deps = dependencies(auth: auth)
        deps.session.pendingBirthdayUser = auth.user
        let gate = BirthdayCheckViewModel(deps: deps)
        XCTAssertNil(gate.birthday)
        XCTAssertFalse(gate.canContinue)
        gate.birthday = Birthday(year: 1990, month: 1, day: 1)
        auth.stateError = URLError(.notConnectedToInternet)
        await gate.save()
        XCTAssertEqual(auth.events, ["save", "state"])
        XCTAssertNil(deps.session.currentUser)
        XCTAssertEqual(deps.session.pendingBirthdayUser?.id, auth.user.id)
        XCTAssertNotNil(gate.errorMessage)

        auth.stateError = nil
        auth.state = .signedIn(auth.user)
        await gate.save()
        XCTAssertEqual(deps.session.currentUser?.id, auth.user.id)
        XCTAssertNil(deps.session.pendingBirthdayUser)
        XCTAssertNil(deps.ageScreening.birthday)
    }

    func testAStoredIneligibleBirthdayBlocksEntryButKeepsAccountDeletion() async {
        let auth = AgeGateAuthSpy()
        auth.state = .ageRestricted(auth.user)
        let deps = dependencies(auth: auth)
        let root = RootViewModel(deps: deps)
        await root.bootstrap()
        XCTAssertNil(root.bootstrapError)
        XCTAssertNil(deps.session.currentUser)
        XCTAssertEqual(deps.session.pendingBirthdayUser?.id, auth.user.id)
        XCTAssertTrue(deps.session.hasIneligibleBirthday)

        let gate = BirthdayCheckViewModel(deps: deps)
        XCTAssertTrue(gate.isUnderage, "the existing blocked-account UI offers sign-out and deletion")
        gate.birthday = Birthday(year: 1990, month: 1, day: 1)
        XCTAssertFalse(gate.canContinue, "a recorded birthday cannot be replaced")
        await gate.save()
        XCTAssertEqual(auth.events, ["state"])

        let deletion = DeleteAccountViewModel(deps: deps)
        deletion.confirmation = "DELETE"
        let deleted = await deletion.delete()
        XCTAssertTrue(deleted)
        XCTAssertEqual(auth.events, ["state", "delete"])
        XCTAssertNil(deps.session.pendingBirthdayUser)
        XCTAssertFalse(deps.session.hasIneligibleBirthday)
        XCTAssertNil(deps.session.currentUser)
    }

    func testSigningInWithAStoredIneligibleBirthdayKeepsTheAccountPending() async {
        let auth = AgeGateAuthSpy()
        auth.state = .ageRestricted(auth.user)
        let deps = dependencies(auth: auth)
        let onboarding = OnboardingViewModel(deps: deps)
        onboarding.continueAfterAgeCheck(Birthday(year: 1990, month: 1, day: 1))
        await onboarding.mockAppleSignIn()

        XCTAssertNil(deps.session.currentUser)
        XCTAssertEqual(deps.session.pendingBirthdayUser?.id, auth.user.id)
        XCTAssertTrue(deps.session.hasIneligibleBirthday)
        XCTAssertTrue(BirthdayCheckViewModel(deps: deps).isUnderage)
    }

    func testPasswordSignInWaitsForTheAgeCheckAndKeepsAnIneligibleAccountPending() async {
        let auth = AgeGateAuthSpy()
        auth.state = .ageRestricted(auth.user)
        let deps = dependencies(auth: auth)
        let onboarding = OnboardingViewModel(deps: deps)
        onboarding.emailInput = "review@example.test"
        onboarding.passwordInput = "secret"
        onboarding.showPasswordSignIn()
        await onboarding.signInWithPassword()
        XCTAssertEqual(onboarding.step, .age)
        XCTAssertEqual(auth.authenticationCalls, 0, "nothing is sent before the birthday")

        onboarding.continueAfterAgeCheck(Birthday(year: 1990, month: 1, day: 1))
        onboarding.showPasswordSignIn()
        XCTAssertEqual(onboarding.step, .password)
        await onboarding.signInWithPassword()
        XCTAssertEqual(auth.authenticationCalls, 1)
        XCTAssertNil(deps.session.currentUser)
        XCTAssertEqual(deps.session.pendingBirthdayUser?.id, auth.user.id)
        XCTAssertTrue(deps.session.hasIneligibleBirthday)
    }

    func testFailedBirthdaySaveKeepsThePendingAccountOutsideTheApp() async {
        let auth = AgeGateAuthSpy()
        auth.saveError = URLError(.notConnectedToInternet)
        auth.state = .signedIn(auth.user)
        let deps = dependencies(auth: auth)
        deps.session.pendingBirthdayUser = auth.user
        let gate = BirthdayCheckViewModel(deps: deps)
        gate.birthday = Birthday(year: 1990, month: 1, day: 1)
        await gate.save()
        XCTAssertEqual(auth.events, ["save"])
        XCTAssertNil(deps.session.currentUser)
        XCTAssertEqual(deps.session.pendingBirthdayUser?.id, auth.user.id)
        XCTAssertNotNil(gate.errorMessage)
    }

    func testLateBirthdayConfirmationCannotReviveASignedOutSession() async {
        let auth = AgeGateAuthSpy()
        auth.state = .signedIn(auth.user)
        let deps = dependencies(auth: auth)
        deps.session.pendingBirthdayUser = auth.user
        let gate = BirthdayCheckViewModel(deps: deps)
        gate.birthday = Birthday(year: 1990, month: 1, day: 1)
        var resumeState: CheckedContinuation<Void, Never>?
        auth.beforeState = { await withCheckedContinuation { resumeState = $0 } }
        let saving = Task { await gate.save() }
        while resumeState == nil { await Task.yield() }
        await deps.endSession()
        resumeState?.resume()
        await saving.value
        XCTAssertNil(deps.session.currentUser)
        XCTAssertNil(deps.session.pendingBirthdayUser)
    }

    func testBlockedLegacyAccountKeepsDeletionAccessAfterRelaunchWithoutNetwork() async {
        let auth = AgeGateAuthSpy()
        auth.storedSession = true
        let deps = dependencies(auth: auth)
        let calendar = Birthday.eligibilityCalendar
        let recent = calendar.date(byAdding: .year, value: -10, to: .now)!
        XCTAssertFalse(deps.ageScreening.submit(Birthday(date: recent, calendar: calendar)))
        await RootViewModel(deps: deps).bootstrap()
        let onboarding = OnboardingViewModel(deps: deps)
        XCTAssertEqual(onboarding.step, .age)
        XCTAssertTrue(onboarding.isSignedIn, "the existing account still offers deletion")
        XCTAssertNil(deps.session.currentUser)
        XCTAssertEqual(auth.events, [], "only local session presence is needed")
    }

    private func dependencies(auth: AgeGateAuthSpy) -> AppDependencies {
        let base = AppDependencies.makeMock(inMemory: true)
        return AppDependencies(
            isLive: true, modelContainer: base.modelContainer, engine: base.engine,
            dateProvider: base.dateProvider, session: base.session, debug: base.debug,
            terms: base.terms, ageScreening: AgeScreening(defaults: nil), auth: auth,
            appleReauth: base.appleReauth, huddleService: base.huddleService,
            depositService: base.depositService, mediaService: base.mediaService,
            moderationService: base.moderationService, plus: base.plus,
            seeder: base.seeder, reminders: base.reminders, push: base.push
        )
    }
}

@MainActor
private final class AgeGateAuthSpy: AuthServiceProtocol {
    let user = User(displayName: "Pat", avatarColorHex: "E5484D")
    var state: AuthSessionState = .needsProfile(suggestedName: nil)
    var stateError: Error?
    var saveError: Error?
    var authenticationCalls = 0
    var profileCalls = 0
    var events: [String] = []
    var storedSession = false
    var beforeState: (() async -> Void)?

    func hasStoredSession() async -> Bool { storedSession }

    func currentState() async throws -> AuthSessionState {
        events.append("state")
        await beforeState?()
        if let stateError { throw stateError }
        return state
    }
    func requestCode(to destination: OTPDestination) async throws { authenticationCalls += 1 }
    func codeLength(for destination: OTPDestination) -> Int { 6 }
    func verifyCode(_ code: String, for destination: OTPDestination) async throws -> AuthSessionState {
        authenticationCalls += 1
        return state
    }
    func signInWithApple(idToken: String, nonce: String, suggestedName: String?) async throws -> AuthSessionState {
        authenticationCalls += 1
        return state
    }
    func signInWithPassword(email: String, password: String) async throws -> AuthSessionState {
        authenticationCalls += 1
        return state
    }
    func completeProfile(displayName: String, avatarColorHex: String, birthday: Birthday) async throws -> User {
        profileCalls += 1
        return user
    }
    func updateProfile(user: User, displayName: String, avatarColorHex: String, bio: String?, photoPaths: [String]) async throws {}
    func birthday() async throws -> Birthday? { nil }
    func saveBirthday(_ birthday: Birthday) async throws {
        events.append("save")
        if let saveError { throw saveError }
    }
    func signOut() async throws {}
    func deleteAccount(appleAuthorizationCode: String?) async throws { events.append("delete") }
    func removeLocalData() throws {}
}

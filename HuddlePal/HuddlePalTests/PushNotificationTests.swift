import Foundation
import SwiftData
import UserNotifications
import XCTest

@testable import HuddlePal

/// The device side of activity notifications (`PushCoordinator`): asking
/// only once a huddle exists, registering this device's token for the
/// signed-in account and removing it on sign-out or when turned off, and a
/// tap opening the huddle it's about. The server side is in
/// supabase/tests (push.test.mjs, send-push.test.mjs).
@MainActor
final class PushNotificationTests: XCTestCase {
    /// Stands in for iOS: what the person answers, and what was asked.
    final class FakeRegistrar: PushRegistering {
        var status: UNAuthorizationStatus = .notDetermined
        var grants = true
        private(set) var prompts = 0
        private(set) var registrations = 0

        func authorizationStatus() async -> UNAuthorizationStatus { status }

        func requestAuthorization() async -> Bool {
            prompts += 1
            status = grants ? .authorized : .denied
            return grants
        }

        func registerForRemoteNotifications() { registrations += 1 }
    }

    private static let defaultsKeys = ["huddlepal.push.enabled", "huddlepal.push.token"]
    private let deviceToken = Data((0..<32).map { UInt8($0 * 7 % 256) })
    private var session: AppSession!
    private var registrar: FakeRegistrar!
    private var tokens: MockPushTokenService!
    private var push: PushCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        Self.defaultsKeys.forEach(UserDefaults.standard.removeObject(forKey:))
        session = AppSession()
        session.currentUser = User(displayName: "Ada", avatarColorHex: "E5484D")
        registrar = FakeRegistrar()
        tokens = MockPushTokenService()
        push = PushCoordinator(registrar: registrar, tokens: tokens, session: session, environment: .sandbox)
    }

    override func tearDown() async throws {
        Self.defaultsKeys.forEach(UserDefaults.standard.removeObject(forKey:))
        StubURLProtocol.reset()
        KeychainStore.delete(key: LiveStub.sessionKey)
        try await super.tearDown()
    }

    private var hexToken: String { PushCoordinator.hex(deviceToken) }

    // MARK: Token and environment

    func testTheDeviceTokenIsSentAsLowercaseHex() {
        XCTAssertEqual(PushCoordinator.hex(Data([0x00, 0x0F, 0xA0, 0xFF])), "000fa0ff")
        XCTAssertNotNil(hexToken.range(of: "^[0-9a-f]{64}$", options: .regularExpression), "device_tokens.token's format")
    }

    func testTheEnvironmentComesFromTheBuildsProvisioningProfile() {
        func profile(_ value: String) -> Data {
            Data("garbage<plist><dict><key>Entitlements</key><dict><key>aps-environment</key>\n\t\t<string>\(value)</string></dict></dict></plist>".utf8)
        }
        XCTAssertEqual(PushEnvironment.from(provisioningProfile: profile("development")), .sandbox)
        XCTAssertEqual(PushEnvironment.from(provisioningProfile: profile("production")), .production)
        XCTAssertEqual(PushEnvironment.from(provisioningProfile: nil), .production, "App Store and TestFlight builds carry no profile")
        XCTAssertEqual(PushEnvironment.from(provisioningProfile: Data("<key>get-task-allow</key>".utf8)), .production)
        XCTAssertEqual(PushEnvironment.current, .sandbox, "the Simulator gets sandbox tokens")
    }

    // MARK: When to ask

    func testLaunchingNeverAsks() async {
        await push.refresh()
        XCTAssertEqual(registrar.prompts, 0)
        XCTAssertEqual(registrar.registrations, 0, "nothing to register without permission")
    }

    func testTheFirstHuddleAsksOnceThenThisDeviceIsRegistered() async {
        await push.huddleJoined()
        XCTAssertEqual(registrar.prompts, 1)
        XCTAssertEqual(registrar.registrations, 1)
        XCTAssertTrue(push.isOn)

        await push.didRegister(deviceToken: deviceToken)
        XCTAssertEqual(tokens.registered, [hexToken: .sandbox])

        await push.huddleJoined()
        XCTAssertEqual(registrar.prompts, 1, "asked once")
    }

    func testARefusalIsntAskedAgainAndShowsInSettings() async {
        registrar.grants = false
        await push.huddleJoined()
        await push.huddleJoined()
        XCTAssertEqual(registrar.prompts, 1)
        XCTAssertEqual(registrar.registrations, 0)
        XCTAssertFalse(push.isOn)
        XCTAssertTrue(push.permissionDenied, "Profile shows the Open Settings note")
    }

    func testAlreadyAllowedRegistersOnEveryLaunch() async {
        registrar.status = .authorized
        await push.refresh()
        XCTAssertEqual(registrar.registrations, 1)
        XCTAssertEqual(registrar.prompts, 0)
    }

    func testSignedOutNothingIsRegisteredOrSent() async {
        registrar.status = .authorized
        session.currentUser = nil
        await push.refresh()
        await push.didRegister(deviceToken: deviceToken)
        XCTAssertEqual(registrar.registrations, 0)
        XCTAssertTrue(tokens.registered.isEmpty)
    }

    // MARK: The toggle

    func testTurningNotificationsOffRemovesThisDeviceAndKeepsItOff() async {
        registrar.status = .authorized
        await push.refresh()
        await push.didRegister(deviceToken: deviceToken)
        XCTAssertFalse(tokens.registered.isEmpty)

        await push.setEnabled(false)
        XCTAssertTrue(tokens.registered.isEmpty)
        XCTAssertFalse(push.isOn)

        await push.refresh()
        await push.didRegister(deviceToken: deviceToken)
        XCTAssertEqual(registrar.registrations, 1, "not registered again while off")
        XCTAssertTrue(tokens.registered.isEmpty)
        XCTAssertFalse(PushSettings().isEnabled, "remembered across launches")
    }

    func testTurningThemOnAsksIfNeverAskedAndRegisters() async {
        await push.setEnabled(false)
        await push.setEnabled(true)
        XCTAssertEqual(registrar.prompts, 1)
        XCTAssertEqual(registrar.registrations, 1)
        XCTAssertTrue(push.isOn)
    }

    // MARK: Signing out

    func testSigningOutRemovesThisDevicesTokenWhileStillSignedIn() async throws {
        let base = AppDependencies.makeMock(inMemory: true)
        let auth = SignOutOrderAuth(tokens: tokens)
        registrar.status = .authorized
        let deps = AppDependencies(
            modelContainer: base.modelContainer, engine: base.engine, dateProvider: base.dateProvider,
            session: session, debug: base.debug, auth: auth, appleReauth: base.appleReauth,
            huddleService: base.huddleService, depositService: base.depositService, mediaService: base.mediaService,
            moderationService: base.moderationService, seeder: base.seeder, reminders: base.reminders, push: push
        )
        await push.didRegister(deviceToken: deviceToken)

        await ProfileViewModel(deps: deps).signOut()

        XCTAssertTrue(tokens.registered.isEmpty)
        XCTAssertEqual(auth.tokensLeftAtSignOut, 0, "removed before the session ended")
        XCTAssertNil(session.currentUser)
    }

    func testEndingTheSessionForgetsAPendingNotification() async {
        let deps = AppDependencies.makeMock(inMemory: true)
        deps.session.pendingHuddleID = UUID()
        await deps.endSession()
        XCTAssertNil(deps.session.pendingHuddleID)
    }

    // MARK: Asking after the first huddle

    func testCreatingAHuddleAsksForPermission() async throws {
        let deps = AppDependencies.makeMock(inMemory: true, pushRegistrar: registrar)
        try await deps.seeder.regenerate()
        guard case .signedIn(let user) = try await deps.auth.currentState() else { return XCTFail("seeded user") }
        deps.session.currentUser = user
        let create = CreateHuddleViewModel(deps: deps)
        create.name = "Book club"

        await create.create()

        XCTAssertNotNil(create.inviteCode, "the new huddle's code is ready to share")
        XCTAssertEqual(registrar.prompts, 1)
    }

    func testJoiningAHuddleAsksForPermission() async throws {
        let deps = AppDependencies.makeMock(inMemory: true, pushRegistrar: registrar)
        try await deps.seeder.regenerate()
        // The Crew is full on the free plan (4 people): its keeper has Plus here.
        if case .signedIn(let keeper) = try await deps.auth.currentState() { deps.mockPlans?.setPlus(true, for: keeper.id) }
        let newcomer = User(displayName: "Newcomer", avatarColorHex: "46A758")
        deps.modelContainer.mainContext.insert(newcomer)
        deps.session.currentUser = newcomer
        let join = JoinHuddleViewModel(deps: deps)
        join.code = try XCTUnwrap(InviteCode(SeedDataService.crewInviteCode)).displayed

        await join.join()

        XCTAssertNotNil(join.joinedHuddle)
        XCTAssertEqual(registrar.prompts, 1)
    }

    func testAFailedJoinDoesntAsk() async throws {
        let deps = AppDependencies.makeMock(inMemory: true, pushRegistrar: registrar)
        try await deps.seeder.regenerate()
        deps.session.currentUser = User(displayName: "Newcomer", avatarColorHex: "46A758")
        let join = JoinHuddleViewModel(deps: deps)
        join.code = InviteCode.generate().displayed

        await join.join()

        XCTAssertNotNil(join.errorMessage)
        XCTAssertEqual(registrar.prompts, 0)
    }

    // MARK: Tapping a notification

    func testATappedNotificationOpensItsHuddle() async throws {
        let deps = AppDependencies.makeMock(inMemory: true, pushRegistrar: registrar)
        try await deps.seeder.regenerate()
        guard case .signedIn(let user) = try await deps.auth.currentState() else { return XCTFail("seeded user") }
        deps.session.currentUser = user
        let huddles = try await deps.huddleService.huddles(for: user)
        let crew = try XCTUnwrap(huddles.first { $0.name == "The Crew" })

        deps.push.notificationTapped(huddleID: crew.id.uuidString.lowercased())
        XCTAssertEqual(deps.session.pendingHuddleID, crew.id)

        let shelf = HuddleListViewModel(deps: deps)
        let opened = await shelf.takeNotifiedHuddle()
        XCTAssertEqual(opened?.id, crew.id, "loaded the shelf, then found it")
        XCTAssertNil(deps.session.pendingHuddleID, "opened once")
        let router = AppRouter()
        router.openHuddle(try XCTUnwrap(opened))
        XCTAssertEqual(router.huddlesPath, [.huddleHome(crew)])
    }

    func testATapForAHuddleYouLeftOpensNothing() async throws {
        let deps = AppDependencies.makeMock(inMemory: true, pushRegistrar: registrar)
        try await deps.seeder.regenerate()
        guard case .signedIn(let user) = try await deps.auth.currentState() else { return XCTFail("seeded user") }
        deps.session.currentUser = user
        deps.session.pendingHuddleID = UUID()

        let opened = await HuddleListViewModel(deps: deps).takeNotifiedHuddle()

        XCTAssertNil(opened)
        XCTAssertNil(deps.session.pendingHuddleID, "dropped, not retried forever")
    }

    func testAPayloadWithoutAHuddleIsIgnored() {
        push.notificationTapped(huddleID: nil)
        push.notificationTapped(huddleID: "not-a-uuid")
        XCTAssertNil(session.pendingHuddleID)
    }

    // MARK: Live registration

    func testLiveRegistrationUpsertsThisDeviceForTheSignedInUser() async throws {
        let userID = UUID()
        let client = try await LiveStub.signedInClient(userID: userID)
        StubURLProtocol.respond { _ in .init(body: Data("[]".utf8)) }
        let service = LivePushTokenService(client: client)

        try await service.register(token: hexToken, environment: .production)
        try await service.unregister(token: hexToken)

        let (upsert, delete) = (StubURLProtocol.requests[0], StubURLProtocol.requests[1])
        XCTAssertEqual(upsert.httpMethod, "POST")
        XCTAssertEqual(upsert.url?.path, "/rest/v1/device_tokens")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(upsert.url), resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "on_conflict", value: "user_id,token")])
        XCTAssertTrue(upsert.value(forHTTPHeaderField: "Prefer")?.contains("resolution=merge-duplicates") ?? false, "re-registering refreshes the row")
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(upsert.httpBody)) as? [String: String]
        XCTAssertEqual(body, ["user_id": userID.uuidString, "token": hexToken, "environment": "production"])

        XCTAssertEqual(delete.httpMethod, "DELETE")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(delete.url), resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "token", value: "eq.\(hexToken)")])
    }
}

/// Signs out like the mock, noting how many device tokens were still
/// registered at that moment.
@MainActor
private final class SignOutOrderAuth: AuthServiceProtocol {
    private let tokens: MockPushTokenService
    private(set) var tokensLeftAtSignOut: Int?

    init(tokens: MockPushTokenService) { self.tokens = tokens }

    func currentState() async throws -> AuthSessionState { .signedOut }
    func codeLength(for destination: OTPDestination) -> Int { 6 }
    func requestCode(to destination: OTPDestination) async throws {}
    func verifyCode(_ code: String, for destination: OTPDestination) async throws -> AuthSessionState { .signedOut }
    func signInWithApple(idToken: String, nonce: String, suggestedName: String?) async throws -> AuthSessionState { .signedOut }
    func completeProfile(displayName: String, avatarColorHex: String) async throws -> User { throw AuthError.notAuthenticated }
    func updateProfile(user: User, displayName: String, avatarColorHex: String, bio: String?, photoPaths: [String]) async throws {}
    func birthday() async throws -> Birthday? { nil }
    func saveBirthday(_ birthday: Birthday) async throws {}
    func signOut() async throws { tokensLeftAtSignOut = tokens.registered.count }
    func deleteAccount(appleAuthorizationCode: String?) async throws {}
    func removeLocalData() throws {}
}

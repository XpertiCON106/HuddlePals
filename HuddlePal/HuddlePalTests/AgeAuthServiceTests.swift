import Foundation
import SwiftData
import XCTest

@testable import HuddlePal

/// Authentication tokens alone cannot activate an app session or publish
/// an encryption identity before the server confirms an eligible birthday.
@MainActor
final class AgeAuthServiceTests: XCTestCase {
    private var container: ModelContainer!
    private var store: SupabaseStore!
    private var identity: InMemoryIdentityStore!
    private var userID: UUID!

    override func setUp() async throws {
        try await super.setUp()
        container = try LiveStub.inMemoryContainer()
        store = SupabaseStore(context: container.mainContext)
        identity = InMemoryIdentityStore()
        userID = UUID()
    }

    override func tearDown() async throws {
        StubURLProtocol.reset()
        KeychainStore.delete(key: LiveStub.sessionKey)
        try await super.tearDown()
    }

    private func service(_ client: SupabaseClient) -> LiveAuthService {
        let keyring = LivePhotoKeyring(
            client: client, session: AppSession(), identityStore: identity,
            verifiedKeys: InMemoryVerifiedKeys()
        )
        return LiveAuthService(
            client: client, store: store, keyring: keyring,
            media: LiveMediaService(client: client, keyring: keyring), config: LiveStub.config
        )
    }

    private var profile: [[String: Any]] {
        [["id": userID.uuidString, "display_name": "Ada", "avatar_color_hex": "E5484D"]]
    }

    private func noIdentityWasPublished() {
        XCTAssertNil(identity.load(for: userID))
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.url?.path.contains("user_keys") == true })
    }

    func testStoredSessionCheckNeedsNoNetworkOrEligibilityAssumption() async throws {
        let client = try await LiveStub.signedInClient(userID: userID, expiresIn: 0)
        StubURLProtocol.respond { _ in
            XCTFail("credential presence must not refresh tokens or fetch profile data")
            return .init(error: URLError(.notConnectedToInternet))
        }
        let auth = service(client)

        let hasSession = await auth.hasStoredSession()

        XCTAssertTrue(hasSession, "an expired stored token still permits offering account deletion")
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
        noIdentityWasPublished()
        await client.signOut()
        StubURLProtocol.respond { _ in
            XCTFail("checking a signed-out account must not make requests either")
            return .init()
        }
        let signedOut = await auth.hasStoredSession()
        XCTAssertFalse(signedOut)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testAProfileWithoutABirthdayNeedsScreeningBeforeIdentityPublication() async throws {
        let client = try await LiveStub.signedInClient(userID: userID)
        let rows = profile
        StubURLProtocol.respond { request in
            .init(body: LiveStub.json(request.url?.path.hasSuffix("/profiles") == true ? rows : []))
        }

        guard case .needsBirthday(let user) = try await service(client).currentState() else {
            return XCTFail("a legacy profile cannot open the app before supplying its birthday")
        }
        XCTAssertEqual(user.id, userID)
        noIdentityWasPublished()
    }

    func testAFailedBirthdayReadNeverFallsBackToTheCachedProfile() async throws {
        let client = try await LiveStub.signedInClient(userID: userID)
        let rows = profile
        StubURLProtocol.respond { request in
            if request.url?.path.hasSuffix("/profiles") == true { return .init(body: LiveStub.json(rows)) }
            return .init(error: URLError(.notConnectedToInternet))
        }

        do {
            _ = try await service(client).currentState()
            XCTFail("unconfirmed eligibility must stay closed")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }
        XCTAssertNotNil(try store.user(id: userID), "the profile really was cached before the lookup failed")
        noIdentityWasPublished()
    }

    func testAStoredIneligibleBirthdayKeepsDeletionAccessWithoutPublishingAnIdentity() async throws {
        let client = try await LiveStub.signedInClient(userID: userID)
        let rows = profile
        let id = userID.uuidString
        let birthday = Birthday(date: .now, calendar: Birthday.eligibilityCalendar).isoDate
        StubURLProtocol.respond { request in
            if request.url?.path.hasSuffix("/profiles") == true { return .init(body: LiveStub.json(rows)) }
            return .init(body: LiveStub.json([["user_id": id, "birth_date": birthday]]))
        }

        guard case .ageRestricted(let user) = try await service(client).currentState() else {
            return XCTFail("a stored ineligible birthday must keep the authenticated deletion path")
        }
        XCTAssertEqual(user.id, userID)
        noIdentityWasPublished()
    }

    func testAnEligibleBirthdayIsConfirmedBeforeIdentityPublication() async throws {
        let client = try await LiveStub.signedInClient(userID: userID)
        let rows = profile
        let id = userID.uuidString
        StubURLProtocol.respond { request in
            if request.url?.path.hasSuffix("/profiles") == true { return .init(body: LiveStub.json(rows)) }
            if request.url?.path.hasSuffix("/profile_birthdates") == true {
                return .init(body: LiveStub.json([["user_id": id, "birth_date": "1990-01-01"]]))
            }
            return .init()
        }

        guard case .signedIn(let user) = try await service(client).currentState() else {
            return XCTFail("the confirmed account can open the app")
        }
        XCTAssertEqual(user.id, userID)
        XCTAssertNotNil(identity.load(for: userID))
        let paths = StubURLProtocol.requests.compactMap { $0.url?.path }
        let birthdayRead = try XCTUnwrap(paths.firstIndex { $0.hasSuffix("/profile_birthdates") })
        let keyRequest = try XCTUnwrap(paths.firstIndex { $0.hasSuffix("/user_keys") })
        XCTAssertLessThan(birthdayRead, keyRequest)
    }

    func testANewAccountDoesNotPublishAnIdentityBeforeMakingAnEligibleProfile() async throws {
        let client = try await LiveStub.signedInClient(userID: userID)
        StubURLProtocol.respond { _ in .init() }

        guard case .needsProfile = try await service(client).currentState() else {
            return XCTFail("a new account still needs its profile")
        }
        noIdentityWasPublished()
    }

    func testProfileActivationSendsTheBirthdayInTheAtomicRPC() async throws {
        let client = try await LiveStub.signedInClient(userID: userID)
        let rows = profile
        StubURLProtocol.respond { request in
            .init(body: LiveStub.json(request.url?.path.hasSuffix("/rpc/complete_profile") == true ? rows : []))
        }

        let user = try await service(client).completeProfile(
            displayName: " Ada ", avatarColorHex: "E5484D", birthday: Birthday(year: 1990, month: 1, day: 1)
        )

        XCTAssertEqual(user.id, userID)
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/rest/v1/rpc/complete_profile")
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: String],
            ["p_display_name": "Ada", "p_avatar_color_hex": "E5484D", "p_birth_date": "1990-01-01"]
        )
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.url?.path.hasSuffix("/profile_birthdates") == true })
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.url?.path.hasSuffix("/profiles") == true })
    }

    func testAnUnderageActivationMakesNoRequestAndPublishesNoIdentity() async throws {
        let client = try await LiveStub.signedInClient(userID: userID)
        StubURLProtocol.respond { _ in
            XCTFail("no data should be uploaded for an underage activation")
            return .init()
        }
        let underage = Birthday(date: .now, calendar: Birthday.eligibilityCalendar)
        do {
            _ = try await service(client).completeProfile(displayName: "Kid", avatarColorHex: "E5484D", birthday: underage)
            XCTFail("underage profiles must be rejected")
        } catch AuthError.underMinimumAge {}
        noIdentityWasPublished()
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testLegacyBirthdayUsesTheImmutableSaveRPCAndMapsItsRefusal() async throws {
        let client = try await LiveStub.signedInClient(userID: userID)
        StubURLProtocol.respond { _ in LiveStub.postgrestError("birthday_immutable") }

        do {
            try await service(client).saveBirthday(Birthday(year: 1990, month: 1, day: 1))
            XCTFail("the birthday cannot be replaced")
        } catch AuthError.birthdayImmutable {}

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/rest/v1/rpc/save_birthday")
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: String],
            ["p_birth_date": "1990-01-01"]
        )
        noIdentityWasPublished()
    }
}

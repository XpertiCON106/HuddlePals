import Foundation
import SwiftData
import XCTest

@testable import HuddlePal

/// The live services over a stubbed HTTP layer (`StubURLProtocol`): what the
/// app does with the server's answers, without a server.
@MainActor
final class LiveServiceTests: XCTestCase {
    private var container: ModelContainer!
    private var store: SupabaseStore!
    private var session: AppSession!
    private var me: User!

    override func setUp() async throws {
        try await super.setUp()
        container = try LiveStub.inMemoryContainer()
        store = SupabaseStore(context: container.mainContext)
        session = AppSession()
        me = User(displayName: "Me", avatarColorHex: "E5484D")
        container.mainContext.insert(me)
    }

    override func tearDown() async throws {
        StubURLProtocol.reset()
        KeychainStore.delete(key: LiveStub.sessionKey)
        try await super.tearDown()
    }

    private func huddleService(_ client: SupabaseClient) -> LiveHuddleService {
        LiveHuddleService(
            client: client, store: store, engine: HuddleEngine(), dateProvider: AppDateProvider(),
            keyring: LivePhotoKeyring(client: client, session: session, identityStore: InMemoryIdentityStore())
        )
    }

    // MARK: Sync completeness (QA-08)

    /// PostgREST as Supabase runs it: honours limit/offset and cuts every
    /// response at max-rows (1000 by default) whatever the client asked for.
    private func postgrest(table: String, rows: [[String: Any]], maxRows: Int = 1000) -> (URLRequest) -> StubURLProtocol.Reply {
        { request in
            let url = request.url!
            guard url.path.hasSuffix("/rest/v1/\(table)") else { return .init() }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func int(_ name: String) -> Int? { items.first { $0.name == name }?.value.flatMap(Int.init) }
            let offset = int("offset") ?? 0
            let limit = min(int("limit") ?? .max, maxRows)
            return .init(body: LiveStub.json(Array(rows.dropFirst(offset).prefix(limit))))
        }
    }

    private func depositRows(count: Int, huddleID: UUID) -> [[String: Any]] {
        (0..<count).map { _ in
            let id = UUID()
            return [
                "id": id.uuidString, "huddle_id": huddleID.uuidString, "author_id": me.id.uuidString,
                "storage_path": "\(huddleID.uuidString)/\(id.uuidString).jpg", "day_key": "2026-06-01",
                "created_at": "2026-06-01T09:00:00Z", "wrapped_photo_key": String(repeating: "A", count: 80),
                "enc_version": 1,
            ]
        }
    }

    func testOpeningAHuddleSyncsItsWholeHistoryPastTheServerRowCap() async throws {
        let client = try await LiveStub.signedInClient(userID: me.id)
        let huddleID = UUID()
        let huddle = try store.apply(HuddleDTO(
            id: huddleID, name: "Big", emoji: "🏔", inviteCode: "BIG123", notificationHour: 19, streakCount: 0
        ))
        // 8 members × ~150 days of check-ins.
        let rows = depositRows(count: 1203, huddleID: huddleID)
        StubURLProtocol.respond(with: postgrest(table: "deposits", rows: rows))
        let service = LiveDepositService(
            client: client, store: store,
            keyring: LivePhotoKeyring(client: client, session: session, identityStore: InMemoryIdentityStore())
        )

        let synced = try await service.deposits(in: huddle)

        XCTAssertEqual(synced.count, 1203, "rows past the server's 1000-row cap must not be dropped (and then pruned locally)")
        XCTAssertEqual(Set(synced.map(\.id.uuidString)), Set(rows.map { $0["id"] as! String }))
    }

    func testReactionAndCommentReadsStayUnderGatewayURLLimits() async throws {
        let client = try await LiveStub.signedInClient(userID: me.id)
        let huddleID = UUID()
        let huddle = try store.apply(HuddleDTO(
            id: huddleID, name: "Big", emoji: "🏔", inviteCode: "BIG123", notificationHour: 19, streakCount: 0
        ))
        StubURLProtocol.respond(with: postgrest(table: "deposits", rows: depositRows(count: 450, huddleID: huddleID)))
        let service = LiveDepositService(
            client: client, store: store,
            keyring: LivePhotoKeyring(client: client, session: session, identityStore: InMemoryIdentityStore())
        )

        _ = try await service.deposits(in: huddle)

        let longest = StubURLProtocol.requests.map { $0.url!.absoluteString.utf8.count }.max() ?? 0
        XCTAssertLessThan(longest, 8_000, "a request line this long is refused by common gateways (414)")
        let reactionReads = StubURLProtocol.requests.filter { $0.url!.path.hasSuffix("/reactions") }
        XCTAssertEqual(reactionReads.count, 5, "450 deposit ids → 5 chunks of ≤100")
    }

    // MARK: Launching offline (QA-12)

    private func authService(_ client: SupabaseClient) -> LiveAuthService {
        let keyring = LivePhotoKeyring(client: client, session: session, identityStore: InMemoryIdentityStore())
        return LiveAuthService(
            client: client, store: store, keyring: keyring,
            media: LiveMediaService(client: client, keyring: keyring), config: LiveStub.config
        )
    }

    func testLaunchingOfflineKeepsTheStoredSessionSignedIn() async throws {
        let client = try await LiveStub.signedInClient(userID: me.id)
        StubURLProtocol.respond { _ in .init(error: URLError(.notConnectedToInternet)) }
        guard case .signedIn(let user) = try await authService(client).currentState() else {
            return XCTFail("an offline launch must not look like being signed out")
        }
        XCTAssertEqual(user.id, me.id)
    }

    func testLaunchingOfflineWithAnExpiredTokenKeepsTheSessionToo() async throws {
        let client = try await LiveStub.signedInClient(userID: me.id, expiresIn: 0)
        StubURLProtocol.respond { _ in .init(error: URLError(.timedOut)) }
        guard case .signedIn = try await authService(client).currentState() else {
            return XCTFail("the refresh couldn't run; the session is still good")
        }
        XCTAssertNotNil(KeychainStore.load(key: LiveStub.sessionKey), "the stored session survives")
    }

    func testARevokedSessionStillSignsOut() async throws {
        let client = try await LiveStub.signedInClient(userID: me.id, expiresIn: 0)
        StubURLProtocol.respond { _ in .init(status: 400, body: LiveStub.json(["error": "invalid_grant", "error_description": "Refresh Token Not Found"])) }
        guard case .signedOut = try await authService(client).currentState() else {
            return XCTFail("a refused refresh token means signed out")
        }
    }

    // MARK: The server ending the session (QA-13)

    func testARefusedRefreshEndsTheSessionInTheApp() async throws {
        let ended = expectation(description: "the app is told the session ended")
        let client = try await LiveStub.signedInClient(userID: me.id, expiresIn: 0) { ended.fulfill() }
        StubURLProtocol.respond { _ in
            .init(status: 400, body: LiveStub.json(["error": "invalid_grant", "error_description": "Refresh Token Not Found"]))
        }
        let session = try await client.validSession()
        XCTAssertNil(session)
        await fulfillment(of: [ended], timeout: 2)
    }

    func testARateLimitedRefreshKeepsTheSession() async throws {
        let client = try await LiveStub.signedInClient(userID: me.id, expiresIn: 0) {
            XCTFail("a rate limit says nothing about the session")
        }
        StubURLProtocol.respond { _ in .init(status: 429, body: LiveStub.json(["msg": "Request rate limit reached"])) }
        do {
            _ = try await client.validSession()
            XCTFail("the refresh failed; it should throw, not return a session")
        } catch SupabaseClient.ClientError.http(let status, _) {
            XCTAssertEqual(status, 429)
        }
        let stillSignedIn = await client.currentUserID
        XCTAssertEqual(stillSignedIn, me.id)
        XCTAssertNotNil(KeychainStore.load(key: LiveStub.sessionKey))
    }

    func testEndingTheSessionReturnsTheAppToSignIn() async {
        let deps = AppDependencies.makeMock(inMemory: true)
        deps.session.currentUser = me
        deps.session.needsProfileSetup = true
        deps.session.pendingInviteCode = "CREW42"
        deps.session.blockedUserIDs = [UUID()]
        await deps.endSession()
        XCTAssertNil(deps.session.currentUser)
        XCTAssertFalse(deps.session.needsProfileSetup)
        XCTAssertNil(deps.session.pendingInviteCode)
        XCTAssertTrue(deps.session.blockedUserIDs.isEmpty)
    }

    // MARK: Joining (QA-02)

    func testTooManyWrongInviteCodesSaysSoInsteadOfAGenericError() async throws {
        let client = try await LiveStub.signedInClient(userID: me.id)
        StubURLProtocol.respond { _ in LiveStub.postgrestError("too_many_attempts") }
        do {
            _ = try await huddleService(client).joinHuddle(inviteCode: "ABCDEF", user: me)
            XCTFail("expected a refusal")
        } catch HuddleServiceError.tooManyAttempts {
            XCTAssertNotNil(HuddleServiceError.tooManyAttempts.errorDescription)
        }
    }

    func testAnUnknownCodeIsReportedAsNotFound() async throws {
        let client = try await LiveStub.signedInClient(userID: me.id)
        // The server answers an unknown code with no row (it records the miss).
        StubURLProtocol.respond { _ in .init(body: Data("[]".utf8)) }
        do {
            _ = try await huddleService(client).joinHuddle(inviteCode: "ZZZZZZ", user: me)
            XCTFail("expected a refusal")
        } catch HuddleServiceError.inviteCodeNotFound {}
        // Servers still running the old function raise instead.
        StubURLProtocol.respond { _ in LiveStub.postgrestError("invite_code_not_found") }
        do {
            _ = try await huddleService(client).joinHuddle(inviteCode: "ZZZZZZ", user: me)
            XCTFail("expected a refusal")
        } catch HuddleServiceError.inviteCodeNotFound {}
    }
}

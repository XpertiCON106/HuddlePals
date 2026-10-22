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

    // MARK: Account deletion (QA-20)

    func testDeletingTheAccountSendsApplesCodeToTheServer() async throws {
        let client = try await LiveStub.signedInClient(userID: me.id)
        StubURLProtocol.respond { _ in .init(body: Data(#"{"ok":true}"#.utf8)) }

        try await authService(client).deleteAccount(appleAuthorizationCode: "c0de")

        let call = try XCTUnwrap(StubURLProtocol.requests.first { $0.url!.path.hasSuffix("/functions/v1/delete-account") })
        XCTAssertEqual(call.httpMethod, "POST")
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(call.httpBody)) as? [String: String]
        XCTAssertEqual(body, ["authorization_code": "c0de"])
        let userID = await client.currentUserID
        XCTAssertNil(userID, "signed out on this device afterwards")
    }

    func testDeletingWithoutApplesConfirmationSendsNoCode() async throws {
        let client = try await LiveStub.signedInClient(userID: me.id)
        StubURLProtocol.respond { _ in .init(body: Data(#"{"ok":true}"#.utf8)) }

        try await authService(client).deleteAccount(appleAuthorizationCode: nil)

        let call = try XCTUnwrap(StubURLProtocol.requests.first { $0.url!.path.hasSuffix("/functions/v1/delete-account") })
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(call.httpBody)) as? [String: String]
        XCTAssertEqual(body, [:])
    }

    func testAFailedServerDeletionKeepsTheSessionAndShowsNoServerDetail() async throws {
        let client = try await LiveStub.signedInClient(userID: me.id)
        StubURLProtocol.respond { _ in .init(status: 500, body: Data(#"{"error":"delete_failed"}"#.utf8)) }

        do {
            try await authService(client).deleteAccount(appleAuthorizationCode: "c0de")
            XCTFail("a failed deletion must not look like success")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Something went wrong. Please try again.")
        }
        let userID = await client.currentUserID
        XCTAssertEqual(userID, me.id, "still signed in: the account still exists")
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

    // MARK: Re-adding reactions and blocks (QA-23)

    func testReactionsAndBlocksLeaveExistingRowsAlone() async throws {
        let client = try await LiveStub.signedInClient(userID: me.id)
        session.currentUser = me
        let huddle = try store.apply(HuddleDTO(
            id: UUID(), name: "Family", emoji: "🏔", inviteCode: "FAM123", notificationHour: 19, streakCount: 0
        ))
        let deposit = Deposit(huddle: huddle, author: me, localImagePath: "Media/x/y.jpg", dayKey: "2026-10-20")
        container.mainContext.insert(deposit)
        let other = User(displayName: "Other", avatarColorHex: "0091FF")
        container.mainContext.insert(other)
        // The server already has these rows: DO NOTHING returns none.
        StubURLProtocol.respond { _ in .init(body: Data("[]".utf8)) }
        let keyring = LivePhotoKeyring(client: client, session: session, identityStore: InMemoryIdentityStore())

        try await LiveDepositService(client: client, store: store, keyring: keyring).toggleReaction("🔥", on: deposit, by: me)
        try await LiveModerationService(client: client, session: session, keyring: keyring).block(other)

        let writes = StubURLProtocol.requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(writes.count, 2)
        for request in writes {
            let prefer = request.value(forHTTPHeaderField: "Prefer") ?? ""
            XCTAssertTrue(prefer.contains("resolution=ignore-duplicates"), "\(request.url!.path): \(prefer)")
        }
    }

    // MARK: Reporting comments and profiles (App Review 1.2)

    func testReportingACommentOrAProfileDisclosesNoPhotoKey() async throws {
        let client = try await LiveStub.signedInClient(userID: me.id)
        session.currentUser = me
        let huddle = try store.apply(HuddleDTO(
            id: UUID(), name: "Family", emoji: "🏔", inviteCode: "FAM123", notificationHour: 19, streakCount: 0
        ))
        let other = User(displayName: "Other", avatarColorHex: "0091FF")
        container.mainContext.insert(other)
        let deposit = Deposit(huddle: huddle, author: other, localImagePath: "Media/x/y.jpg", dayKey: "2026-10-20")
        container.mainContext.insert(deposit)
        let comment = Comment(deposit: deposit, user: other, text: String(repeating: "🙂", count: 400))
        container.mainContext.insert(comment)
        StubURLProtocol.respond { _ in .init(body: Data("[]".utf8)) }
        let keyring = LivePhotoKeyring(client: client, session: session, identityStore: InMemoryIdentityStore())
        let moderation = LiveModerationService(client: client, session: session, keyring: keyring)

        try await moderation.report(comment: comment)
        try await moderation.report(user: other)

        let bodies = try StubURLProtocol.requests.filter { $0.url!.path.hasSuffix("/rest/v1/reports") }.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap($0.httpBody)) as? [String: String])
        }
        XCTAssertEqual(bodies.count, 2)
        let commentReason = try XCTUnwrap(bodies[0]["reason"])
        XCTAssertTrue(commentReason.hasPrefix("Comment \(comment.id.uuidString.lowercased()): 🙂"), "names the comment")
        XCTAssertEqual(commentReason.serverLength, 300, "fits reports.reason (≤ 300)")
        XCTAssertEqual(bodies[0]["deposit_id"], deposit.id.uuidString)
        XCTAssertEqual(bodies[0]["reported_user_id"], other.id.uuidString)
        XCTAssertNil(bodies[0]["photo_key"], "a comment report opens no photo")
        XCTAssertEqual(bodies[1], [
            "reporter_id": me.id.uuidString, "reported_user_id": other.id.uuidString, "reason": "Profile",
        ])
    }

    // MARK: Joining (QA-02)

    func testTooManyWrongInviteCodesSaysSoInsteadOfAGenericError() async throws {
        let client = try await LiveStub.signedInClient(userID: me.id)
        StubURLProtocol.respond { _ in LiveStub.postgrestError("too_many_attempts") }
        do {
            _ = try await huddleService(client).joinHuddle(inviteCode: InviteCode.generate().displayed, user: me)
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
            _ = try await huddleService(client).joinHuddle(inviteCode: InviteCode.generate().displayed, user: me)
            XCTFail("expected a refusal")
        } catch HuddleServiceError.inviteCodeNotFound {}
        // Servers still running the old function raise instead.
        StubURLProtocol.respond { _ in LiveStub.postgrestError("invite_code_not_found") }
        do {
            _ = try await huddleService(client).joinHuddle(inviteCode: InviteCode.generate().displayed, user: me)
            XCTFail("expected a refusal")
        } catch HuddleServiceError.inviteCodeNotFound {}
    }

    func testAnOldCodeIsExplainedWithoutAskingTheServer() async throws {
        let client = try await LiveStub.signedInClient(userID: me.id)
        StubURLProtocol.respond { _ in .init(body: Data("[]".utf8)) }
        do {
            _ = try await huddleService(client).joinHuddle(inviteCode: "crew42", user: me)
            XCTFail("expected a refusal")
        } catch HuddleServiceError.inviteCodeOutdated {}
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "no request, so no recorded miss")
    }

    func testRefusalsFromTheRedeemFunctionMapToTheirOwnMessages() async throws {
        let client = try await LiveStub.signedInClient(userID: me.id)
        let cases: [(String, HuddleServiceError)] = [
            ("already_member", .alreadyMember), ("huddle_full", .huddleFull), ("blocked", .cannotJoin),
        ]
        for (raised, expected) in cases {
            StubURLProtocol.respond { _ in LiveStub.postgrestError(raised) }
            do {
                _ = try await huddleService(client).joinHuddle(inviteCode: InviteCode.generate().displayed, user: me)
                XCTFail("expected \(raised)")
            } catch let error as HuddleServiceError {
                XCTAssertEqual(error.errorDescription, expected.errorDescription, raised)
            }
        }
    }
}

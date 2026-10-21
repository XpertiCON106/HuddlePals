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

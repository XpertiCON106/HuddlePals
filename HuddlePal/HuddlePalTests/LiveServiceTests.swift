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

import SwiftData
import XCTest

@testable import HuddlePal

/// A keeper deletes their huddle: everyone is removed at once, and the
/// huddle, its deposits and their files leave the device with the next
/// shelf refresh, after its screens have closed. Offline on the mock stack,
/// and live against a stubbed delete-huddle function.
@MainActor
final class HuddleDeletionTests: XCTestCase {
    private var deps: AppDependencies!
    private var you: User!

    override func setUp() async throws {
        try await super.setUp()
        deps = AppDependencies.makeMock(inMemory: true)
        try await deps.seeder.regenerate()
        guard case .signedIn(let user) = try await deps.auth.currentState() else {
            throw XCTSkip("expected the seeded user to be signed in")
        }
        you = user
        deps.session.currentUser = user
    }

    override func tearDown() async throws {
        StubURLProtocol.reset()
        KeychainStore.delete(key: LiveStub.sessionKey)
        try await super.tearDown()
    }

    private var context: ModelContext { deps.modelContainer.mainContext }

    private func crew() throws -> Huddle {
        try XCTUnwrap(you.memberships.compactMap(\.huddle).first { $0.inviteCode == SeedDataService.crewInviteCode })
    }

    private func onDisk(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: MockMediaService().imageURL(for: relativePath).path)
    }

    // MARK: Offline

    func testTheKeeperDeletesAHuddleForEveryoneWithItsPhotosAndVideos() async throws {
        let huddle = try crew()
        let huddleID = huddle.id
        let maya = try XCTUnwrap(huddle.members.first { $0.displayName == "Maya" })
        let files = huddle.deposits.flatMap { [$0.localImagePath] + [$0.localVideoPath].compactMap { $0 } }
        XCTAssertTrue(files.contains { $0.hasSuffix(".mp4") }, "the seeded video too")
        XCTAssertTrue(files.allSatisfy(onDisk))
        let depositsElsewhere = try context.fetch(FetchDescriptor<Deposit>()).count - huddle.deposits.count

        let settings = HuddleSettingsViewModel(deps: deps, huddle: huddle)
        XCTAssertTrue(settings.isKeeper)
        await settings.deleteHuddle()

        XCTAssertTrue(settings.didDelete)
        XCTAssertNil(settings.errorMessage)
        XCTAssertTrue(huddle.memberships.isEmpty, "everyone is removed at once")
        XCTAssertFalse(maya.memberships.contains { $0.huddle?.id == huddleID })

        // The shelf, once the huddle's screens have closed.
        let shelf = try await deps.huddleService.huddles(for: you)
        XCTAssertEqual(shelf.map(\.name), ["Sunday Dinners"])
        XCTAssertFalse(try context.fetch(FetchDescriptor<Huddle>()).contains { $0.id == huddleID })
        XCTAssertEqual(try context.fetch(FetchDescriptor<Deposit>()).count, depositsElsewhere, "only its own deposits go")
        XCTAssertFalse(files.contains(where: onDisk), "and their files")
    }

    func testOnlyTheKeeperCanDeleteIt() async throws {
        let huddle = try crew()
        let maya = try XCTUnwrap(huddle.members.first { $0.displayName == "Maya" })
        deps.session.currentUser = maya
        let settings = HuddleSettingsViewModel(deps: deps, huddle: huddle)
        XCTAssertFalse(settings.isKeeper, "no Delete button for a member")
        await settings.deleteHuddle()
        XCTAssertFalse(settings.didDelete)

        do {
            try await deps.huddleService.deleteHuddle(huddle, by: maya)
            XCTFail("only the keeper")
        } catch HuddleServiceError.notKeeper {}
        XCTAssertEqual(huddle.memberships.count, 4)
    }

    func testDeletingFreesAPlaceAmongTheHuddlesYouKeep() async throws {
        _ = try await deps.huddleService.createHuddle(name: "Third", emoji: "🧪", keeper: you)
        let settings = HuddleSettingsViewModel(deps: deps, huddle: try crew())
        await settings.deleteHuddle()
        _ = try await deps.huddleService.huddles(for: you)
        let fourth = CreateHuddleViewModel(deps: deps)
        XCTAssertNil(fourth.limitReached, "2 kept of the free plan's 3")
    }

    // MARK: Live

    private struct Live {
        let service: LiveHuddleService
        let huddle: Huddle
        let me: User
        let friend: User
        let container: ModelContainer
    }

    /// Me (keeper) and Friend in one huddle with one cached photo, against
    /// a stubbed server that answers delete-huddle with `deleteStatus`.
    private func live(deleteStatus: Int = 200) async throws -> Live {
        let container = try LiveStub.inMemoryContainer()
        let store = SupabaseStore(context: container.mainContext)
        let me = User(displayName: "Me", avatarColorHex: "E5484D")
        let friend = User(displayName: "Friend", avatarColorHex: "0091FF")
        container.mainContext.insert(me)
        container.mainContext.insert(friend)
        let huddleID = UUID()
        let huddle = try store.apply(HuddleDTO(
            id: huddleID, name: "Family", emoji: "🏔", inviteCode: "FAM123", notificationHour: 19, streakCount: 0
        ))
        try store.applyMemberships([
            MembershipDTO(id: UUID(), userId: me.id, huddleId: huddleID, role: "keeper", skipTokensRemaining: 2),
            MembershipDTO(id: UUID(), userId: friend.id, huddleId: huddleID, role: "member", skipTokensRemaining: 2),
        ], to: huddle)
        let cached = try await MockMediaService().saveImageData(
            Data([1, 2, 3]), preferredName: "\(huddleID.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
        )
        container.mainContext.insert(Deposit(huddle: huddle, author: friend, localImagePath: cached, dayKey: "2026-10-20"))
        try store.save()

        let client = try await LiveStub.signedInClient(userID: me.id)
        StubURLProtocol.respond { request in
            if request.url!.path.hasSuffix("/functions/v1/delete-huddle") {
                return deleteStatus == 200
                    ? .init(body: LiveStub.json(["deleted": true]))
                    : .init(status: deleteStatus, body: LiveStub.json(["error": deleteStatus == 403 ? "not_keeper" : "huddle_not_found"]))
            }
            // memberships for the shelf: none left.
            return .init(body: Data("[]".utf8))
        }
        let session = AppSession()
        session.currentUser = me
        let service = LiveHuddleService(
            client: client, store: store, engine: HuddleEngine(), dateProvider: AppDateProvider(),
            keyring: LivePhotoKeyring(client: client, session: session, identityStore: InMemoryIdentityStore())
        )
        return Live(service: service, huddle: huddle, me: me, friend: friend, container: container)
    }

    func testLiveDeletionAsksTheServerThenTheNextRefreshClearsTheDevice() async throws {
        let world = try await live()
        let huddleID = world.huddle.id
        let file = try XCTUnwrap(world.huddle.deposits.first?.localImagePath)
        XCTAssertTrue(onDisk(file))

        try await world.service.deleteHuddle(world.huddle, by: world.me)

        let request = try XCTUnwrap(StubURLProtocol.requests.first { $0.url!.path.hasSuffix("/functions/v1/delete-huddle") })
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["huddle_id": huddleID.uuidString.lowercased()], "the lowercase id its Storage folder uses")
        XCTAssertTrue(world.huddle.memberships.isEmpty)

        let shelf = try await world.service.huddles(for: world.me)
        XCTAssertTrue(shelf.isEmpty)
        XCTAssertTrue(try world.container.mainContext.fetch(FetchDescriptor<Huddle>()).isEmpty)
        XCTAssertTrue(try world.container.mainContext.fetch(FetchDescriptor<Deposit>()).isEmpty)
        XCTAssertFalse(onDisk(file), "its cached files go too")
    }

    func testLiveAMemberIsntAskedAndTheServerHasTheLastWord() async throws {
        let refused = try await live(deleteStatus: 403)
        do {
            try await refused.service.deleteHuddle(refused.huddle, by: refused.friend)
            XCTFail("only the keeper")
        } catch HuddleServiceError.notKeeper {}
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "a member never asks")
        do {
            try await refused.service.deleteHuddle(refused.huddle, by: refused.me)
            XCTFail("the server says no")
        } catch HuddleServiceError.notKeeper {}
        XCTAssertEqual(refused.huddle.memberships.count, 2, "nothing removed here")

        StubURLProtocol.reset()
        let gone = try await live(deleteStatus: 404)
        try await gone.service.deleteHuddle(gone.huddle, by: gone.me)
        XCTAssertTrue(gone.huddle.memberships.isEmpty, "already deleted from another device: gone here too")
    }
}

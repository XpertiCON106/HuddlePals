import Foundation
import SwiftData
import XCTest

@testable import HuddlePal

/// `SupabaseStore` reconciliation, no network: PostgREST rows go in as DTOs
/// (or raw JSON), SwiftData comes out. Focus: "Former member" rows — a
/// deleted account nulls `author_id` / `user_id`, and a member who left keeps
/// their id while RLS hides their profile. Neither may drop a photo.
/// (Huddles are never named by type here — the module shares the name.)
@MainActor
final class LiveSyncTests: XCTestCase {
    /// Held for the test's lifetime: a ModelContext traps once its container
    /// is deallocated.
    private var container: ModelContainer!
    private var context: ModelContext!
    private var store: SupabaseStore!
    private var huddleID: UUID!
    private var me: User!
    private var friend: User!

    private let today = "2026-10-19"

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer(
            for: Schema(HuddleSchema.models),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        context = container.mainContext
        store = SupabaseStore(context: context)

        me = User(displayName: "Me", avatarColorHex: "E5484D")
        friend = User(displayName: "Friend", avatarColorHex: "0091FF")
        context.insert(me)
        context.insert(friend)

        huddleID = UUID()
        try store.apply(HuddleDTO(
            id: huddleID, name: "Sync", emoji: "🏔", inviteCode: "SYNC42",
            notificationHour: 19, streakCount: 0
        ))
        try store.save()
    }

    // MARK: Helpers

    private func depositDTO(_ id: UUID = UUID(), author: UUID?, day: String? = nil) -> DepositDTO {
        DepositDTO(
            id: id, huddleId: huddleID, authorId: author,
            storagePath: "\(huddleID.uuidString)/\(id.uuidString).jpg",
            caption: nil, dayKey: day ?? today
        )
    }

    private func commentDTO(on deposit: UUID, by user: UUID?) -> CommentDTO {
        CommentDTO(id: UUID(), depositId: deposit, userId: user, body: "hi")
    }

    // MARK: Writes still on their way

    /// A sync while a reaction or comment is uploading keeps it, doesn't
    /// count a reaction twice, and doesn't bring back one just taken back.
    func testASyncKeepsWhatsOnItsWayAndLeavesWhatWasTakenBack() throws {
        let huddle = try XCTUnwrap(store.huddle(id: huddleID))
        let dto = depositDTO(author: friend.id)
        try store.applyDeposits([dto], reactions: [], comments: [], to: huddle)
        let deposit = try XCTUnwrap(huddle.deposits.first)

        let comment = store.insertCommentLocally(id: UUID(), text: "on its way", createdAt: .now, deposit: deposit, user: me)
        let fire = store.insertReactionLocally(id: UUID(), emoji: "🔥", createdAt: .now, deposit: deposit, user: me)
        store.pendingIDs = [comment.id, fire.id]
        let takenBack = ReactionDTO(id: UUID(), depositId: dto.id, userId: me.id, emoji: "❤️")
        store.withdrawnIDs = [takenBack.id]
        // The server has a 🔥 from me already, under its own id.
        let serverFire = ReactionDTO(id: UUID(), depositId: dto.id, userId: me.id, emoji: "🔥")

        try store.applyDeposits([dto], reactions: [takenBack, serverFire], comments: [], to: huddle)
        try store.save()
        XCTAssertEqual(deposit.comments.map(\.text), ["on its way"])
        XCTAssertEqual(deposit.reactions.map(\.emoji), ["🔥"])

        // Sent: the server's word again.
        store.pendingIDs = []
        store.withdrawnIDs = []
        try store.applyDeposits([dto], reactions: [], comments: [], to: huddle)
        try store.save()
        XCTAssertTrue(deposit.comments.isEmpty)
        XCTAssertTrue(deposit.reactions.isEmpty)
    }

    // MARK: Decoding

    func testNullAuthorRowsDecodeAndAreKeptAsFormerMember() throws {
        let depositID = UUID()
        let json = """
        {
          "deposits": [{
            "id": "\(depositID)", "huddle_id": "\(huddleID!)", "author_id": null,
            "storage_path": "\(huddleID!)/a.jpg", "caption": null, "day_key": "\(today)"
          }],
          "comments": [{
            "id": "\(UUID())", "deposit_id": "\(depositID)", "user_id": null, "body": "still here"
          }]
        }
        """
        struct Payload: Decodable {
            let deposits: [DepositDTO]
            let comments: [CommentDTO]
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = try decoder.decode(Payload.self, from: Data(json.utf8))
        XCTAssertNil(payload.deposits.first?.authorId)
        XCTAssertNil(payload.comments.first?.userId)

        let huddle = try XCTUnwrap(store.huddle(id: huddleID))
        try store.applyDeposits(payload.deposits, reactions: [], comments: payload.comments, to: huddle)
        try store.save()

        let deposit = try XCTUnwrap(huddle.deposits.first)
        XCTAssertEqual(deposit.id, depositID, "a deleted author's photo is permanent")
        XCTAssertNil(deposit.author, "rendered as Former member")
        XCTAssertNil(deposit.snapshot, "author-less rows never count toward anyone's gate")
        XCTAssertEqual(deposit.comments.count, 1)
        XCTAssertNil(deposit.comments.first?.user)
    }

    // MARK: Reconciliation

    func testDepartedMembersPhotoAndReactionAreKept() throws {
        let departed = UUID() // id survives, profile unreadable → no local User
        let deposit = depositDTO(author: departed)
        let reaction = ReactionDTO(id: UUID(), depositId: deposit.id, userId: departed, emoji: "🔥")
        let huddle = try XCTUnwrap(store.huddle(id: huddleID))

        try store.applyDeposits([deposit], reactions: [reaction], comments: [], to: huddle)
        try store.save()

        XCTAssertEqual(huddle.deposits.count, 1, "a member who left keeps their photo in the huddle")
        XCTAssertNil(huddle.deposits.first?.author)
        XCTAssertEqual(huddle.deposits.first?.reactions.count, 1, "reaction counts stay honest")
    }

    func testKnownAuthorsStillResolve() throws {
        let deposit = depositDTO(author: friend.id)
        let huddle = try XCTUnwrap(store.huddle(id: huddleID))

        try store.applyDeposits(
            [deposit], reactions: [], comments: [commentDTO(on: deposit.id, by: me.id)], to: huddle
        )
        try store.save()

        XCTAssertEqual(huddle.deposits.first?.author?.id, friend.id)
        XCTAssertEqual(huddle.deposits.first?.comments.first?.user?.id, me.id)
    }

    func testDeletedAccountClearsAuthorOnRowsAlreadySynced() throws {
        let depositID = UUID()
        let comment = commentDTO(on: depositID, by: friend.id)
        let huddle = try XCTUnwrap(store.huddle(id: huddleID))
        try store.applyDeposits(
            [depositDTO(depositID, author: friend.id)], reactions: [], comments: [comment], to: huddle
        )
        try store.save()
        XCTAssertEqual(huddle.deposits.first?.author?.id, friend.id)

        // Friend deletes their account: the server nulls both ids.
        let nulledComment = CommentDTO(id: comment.id, depositId: depositID, userId: nil, body: comment.body)
        try store.applyDeposits(
            [depositDTO(depositID, author: nil)], reactions: [], comments: [nulledComment], to: huddle
        )
        try store.save()

        let deposit = try XCTUnwrap(huddle.deposits.first)
        XCTAssertEqual(deposit.id, depositID, "same row, not a replacement")
        XCTAssertNil(deposit.author, "the cached profile no longer labels their photo")
        XCTAssertEqual(deposit.comments.count, 1)
        XCTAssertNil(deposit.comments.first?.user)
    }

    func testOwnNewDepositNeverSweepsAwayFormerMemberRows() throws {
        let huddle = try XCTUnwrap(store.huddle(id: huddleID))
        let formerMember = depositDTO(author: nil)
        try store.applyDeposits([formerMember], reactions: [], comments: [], to: huddle)
        try store.save()

        // My own deposit for the same day arrives back from the insert.
        try store.applyDeposit(depositDTO(author: me.id), to: huddle, author: me)
        try store.save()

        XCTAssertEqual(huddle.deposits.count, 2)
        XCTAssertTrue(huddle.deposits.contains { $0.id == formerMember.id && $0.author == nil })
        XCTAssertTrue(huddle.deposits.contains { $0.author?.id == me.id })
    }

    func testMembershipJoinDaySyncsFromTheServer() throws {
        let huddle = try XCTUnwrap(store.huddle(id: huddleID))
        let dto = MembershipDTO(
            id: UUID(), userId: friend.id, huddleId: huddleID,
            role: "member", skipTokensRemaining: 2, joinedDayKey: "2026-10-18"
        )
        try store.applyMemberships([dto], to: huddle)
        try store.save()

        XCTAssertEqual(huddle.memberships.first?.joinedDayKey, "2026-10-18")
        XCTAssertEqual(huddle.memberJoinDayKeys(using: HuddleEngine())[friend.id], "2026-10-18")
    }

    func testMissingUserIDsReportsOnlyUncachedProfiles() throws {
        let stranger = UUID()
        let missing = try store.missingUserIDs(in: [me.id, friend.id, stranger])
        XCTAssertEqual(missing, [stranger])
    }

    // MARK: Video drops and keepers (migration 013)

    func testAVideoRowDecodesAndKeepsItsClipNextToItsPoster() throws {
        let depositID = UUID()
        let name = "\(huddleID!)/\(depositID)"
        let json = """
        [{
          "id": "\(depositID)", "huddle_id": "\(huddleID!)", "author_id": "\(friend.id)",
          "storage_path": "\(name).jpg", "caption": null, "day_key": "\(today)",
          "media_type": "video", "video_path": "\(name).mp4", "duration_ms": 5800,
          "wrapped_photo_key": "\(String(repeating: "A", count: 80))", "enc_version": 1
        }]
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let rows = try decoder.decode([DepositDTO].self, from: Data(json.utf8))
        let huddle = try XCTUnwrap(store.huddle(id: huddleID))
        try store.applyDeposits(rows, reactions: [], comments: [], to: huddle)
        try store.save()

        let deposit = try XCTUnwrap(huddle.deposits.first)
        XCTAssertEqual(deposit.mediaType, .video)
        XCTAssertTrue(deposit.isVideo)
        XCTAssertEqual(deposit.localImagePath, "Media/\(name).jpg", "the poster, where a photo would be")
        XCTAssertEqual(deposit.localVideoPath, "Media/\(name).mp4")
        XCTAssertEqual(deposit.durationMs, 5800)
        XCTAssertNotNil(deposit.wrappedPhotoKey, "one key for poster and clip")
    }

    func testRowsFromBeforeVideosOrOfAnUnknownKindAreShownAsPhotos() throws {
        let huddle = try XCTUnwrap(store.huddle(id: huddleID))
        var oldServer = depositDTO(author: friend.id)
        oldServer.mediaType = nil
        var unknown = depositDTO(author: me.id, day: "2026-10-18")
        unknown.mediaType = "hologram"
        unknown.videoPath = "\(huddleID!)/x.mp4"
        var clipless = depositDTO(author: friend.id, day: "2026-10-17")
        clipless.mediaType = "video"
        try store.applyDeposits([oldServer, unknown, clipless], reactions: [], comments: [], to: huddle)
        try store.save()

        XCTAssertEqual(huddle.deposits.count, 3)
        XCTAssertTrue(huddle.deposits.allSatisfy { $0.mediaType == .photo && $0.localVideoPath == nil && !$0.isVideo })
    }

    func testAResyncUpdatesAnExistingRowsMedia() throws {
        let huddle = try XCTUnwrap(store.huddle(id: huddleID))
        var dto = depositDTO(author: friend.id)
        try store.applyDeposits([dto], reactions: [], comments: [], to: huddle)
        dto.mediaType = "video"
        dto.videoPath = dto.storagePath.replacingOccurrences(of: ".jpg", with: ".mp4")
        dto.durationMs = 3000
        try store.applyDeposits([dto], reactions: [], comments: [], to: huddle)
        XCTAssertTrue(try XCTUnwrap(huddle.deposits.first).isVideo)

        try store.applyDeposit(depositDTO(dto.id, author: me.id), to: huddle, author: me)
        XCTAssertFalse(try XCTUnwrap(huddle.deposits.first).isVideo, "the single-row upsert applies the media too")
    }

    func testKeeperSinceSyncsFromTheServer() throws {
        let huddle = try XCTUnwrap(store.huddle(id: huddleID))
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        let joined = since.addingTimeInterval(-86_400)
        var dto = MembershipDTO(
            id: UUID(), userId: friend.id, huddleId: huddleID,
            role: "keeper", skipTokensRemaining: 2, joinedAt: joined, keeperSince: since
        )
        try store.applyMemberships([dto], to: huddle)
        XCTAssertEqual(huddle.memberships.first?.keeperSince, since)
        XCTAssertEqual(huddle.memberships.first?.keptSince, since)

        dto.keeperSince = nil // a server from before migration 013
        try store.applyMemberships([dto], to: huddle)
        XCTAssertNil(huddle.memberships.first?.keeperSince)
        XCTAssertEqual(huddle.memberships.first?.keptSince, joined, "falls back to the join, as the server backfilled")
    }
}

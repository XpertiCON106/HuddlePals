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
}

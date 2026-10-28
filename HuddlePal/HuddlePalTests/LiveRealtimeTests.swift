import Foundation
import SwiftData
import XCTest

@testable import HuddlePal

/// Live updates over Supabase Realtime: the socket it opens, the channel it
/// joins, the changes it reads, and the huddle each is passed on as.
@MainActor
final class LiveRealtimeTests: XCTestCase {
    private var container: ModelContainer!
    private var store: SupabaseStore!
    private var session: AppSession!

    override func setUp() async throws {
        try await super.setUp()
        container = try LiveStub.inMemoryContainer()
        store = SupabaseStore(context: container.mainContext)
        session = AppSession()
    }

    override func tearDown() async throws {
        StubURLProtocol.reset()
        KeychainStore.delete(key: LiveStub.sessionKey)
        try await super.tearDown()
    }

    func testItOpensTheProjectsRealtimeSocket() throws {
        let url = try XCTUnwrap(LiveRealtime.socketURL(for: BackendConfig(url: URL(string: "https://abc.supabase.co")!, anonKey: "anon")))
        XCTAssertEqual(url.absoluteString, "wss://abc.supabase.co/realtime/v1/websocket?apikey=anon&vsn=1.0.0")
    }

    func testItJoinsForEveryChangeToDepositsCommentsAndReactionsWithItsToken() throws {
        let join = LiveRealtime.joinMessage(token: "jwt", ref: "1")
        XCTAssertEqual(join["event"] as? String, "phx_join")
        XCTAssertEqual(join["topic"] as? String, LiveRealtime.topic)
        let payload = try XCTUnwrap(join["payload"] as? [String: Any])
        XCTAssertEqual(payload["access_token"] as? String, "jwt", "Realtime checks RLS as this account")
        let config = try XCTUnwrap(payload["config"] as? [String: Any])
        let changes = try XCTUnwrap(config["postgres_changes"] as? [[String: String]])
        XCTAssertEqual(changes.map { $0["table"] }, ["deposits", "comments", "reactions"])
        XCTAssertTrue(changes.allSatisfy { $0["event"] == "*" && $0["schema"] == "public" })
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: join))
    }

    func testItReadsChangesAndNothingElse() {
        let me = UUID(), deposit = UUID(), huddle = UUID()
        let comment = """
        {"event":"postgres_changes","topic":"\(LiveRealtime.topic)","ref":null,"payload":{"ids":[1],"data":{
        "schema":"public","table":"comments","type":"INSERT","commit_timestamp":"2026-10-28T12:00:00Z",
        "record":{"id":"\(UUID())","deposit_id":"\(deposit)","user_id":"\(me)","body":"hi"},"old_record":{}}}}
        """
        XCTAssertEqual(LiveRealtime.change(in: comment), .init(table: "comments", actorID: me, huddleID: nil, depositID: deposit))

        let post = """
        {"event":"postgres_changes","topic":"\(LiveRealtime.topic)","payload":{"data":{"table":"deposits","type":"INSERT",
        "record":{"id":"\(UUID())","huddle_id":"\(huddle)","author_id":"\(me)"}}}}
        """
        XCTAssertEqual(LiveRealtime.change(in: post), .init(table: "deposits", actorID: me, huddleID: huddle, depositID: nil))

        let takenBack = """
        {"event":"postgres_changes","topic":"\(LiveRealtime.topic)","payload":{"data":{"table":"reactions","type":"DELETE",
        "record":{},"old_record":{"id":"\(UUID())"}}}}
        """
        XCTAssertEqual(LiveRealtime.change(in: takenBack), .init(table: "reactions", actorID: nil, huddleID: nil, depositID: nil),
                       "a delete says only which row: the huddle isn't known")

        for other in [
            #"{"event":"phx_reply","topic":"phoenix","payload":{"status":"ok","response":{}},"ref":"2"}"#,
            #"{"event":"system","topic":"realtime:huddlepals","payload":{"status":"ok"}}"#,
            #"{"event":"postgres_changes","payload":{"data":{"table":"profiles","record":{}}}}"#,
            "not json",
        ] {
            XCTAssertNil(LiveRealtime.change(in: other), other)
        }
        XCTAssertTrue(LiveRealtime.isJoinReply(#"{"event":"phx_reply","topic":"realtime:huddlepals","payload":{"status":"ok","response":{"postgres_changes":[]}},"ref":"1"}"#))
        XCTAssertFalse(LiveRealtime.isJoinReply(#"{"event":"phx_reply","topic":"realtime:huddlepals","payload":{"status":"error","response":{}},"ref":"1"}"#))
    }

    /// A comment arrives as the huddle its photo is in; this account's own
    /// changes don't come back to it.
    func testAChangeGoesOutAsItsHuddleUnlessItsYourOwn() async throws {
        let me = User(displayName: "Me", avatarColorHex: "E5484D")
        container.mainContext.insert(me)
        session.currentUser = me
        let huddle = try store.apply(HuddleDTO(
            id: UUID(), name: "Family", emoji: "🏔", inviteCode: "FAM123", notificationHour: 19, streakCount: 0
        ))
        let deposit = Deposit(huddle: huddle, author: me, localImagePath: "Media/x/y.jpg", dayKey: "2026-10-20")
        container.mainContext.insert(deposit)
        try store.save()
        let client = try await LiveStub.signedInClient(userID: me.id)
        let realtime = LiveRealtime(config: LiveStub.config, client: client, store: store, session: session)
        var heard = realtime.changes().makeAsyncIterator()

        realtime.deliver(.init(table: "comments", actorID: me.id, huddleID: nil, depositID: deposit.id))
        realtime.deliver(.init(table: "comments", actorID: UUID(), huddleID: nil, depositID: deposit.id))
        let first = await heard.next()
        XCTAssertEqual(first, huddle.id, "a friend's comment, as its huddle; mine was skipped")

        realtime.deliver(.init(table: "reactions", actorID: nil, huddleID: nil, depositID: nil))
        let second = await heard.next()
        XCTAssertEqual(second, .some(nil), "somewhere: every open huddle refreshes")
    }
}

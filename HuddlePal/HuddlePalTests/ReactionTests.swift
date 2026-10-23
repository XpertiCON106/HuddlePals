import Foundation
import XCTest

@testable import HuddlePal

/// Reacting shows at once: the count and your highlight change on the tap,
/// not after the server answers (and not only once the photo is reopened).
@MainActor
final class ReactionTests: XCTestCase {
    private var deps: AppDependencies!
    private var reactions: HeldReactionService!

    override func setUp() async throws {
        try await super.setUp()
        let base = AppDependencies.makeMock(inMemory: true)
        try await base.seeder.regenerate()
        guard case .signedIn(let user) = try await base.auth.currentState() else {
            throw XCTSkip("expected the seeded user to be signed in")
        }
        base.session.currentUser = user
        reactions = HeldReactionService(inner: base.depositService)
        deps = AppDependencies(
            modelContainer: base.modelContainer, engine: base.engine, dateProvider: base.dateProvider,
            session: base.session, debug: base.debug, auth: base.auth, appleReauth: base.appleReauth, huddleService: base.huddleService,
            depositService: reactions, mediaService: base.mediaService, moderationService: base.moderationService,
            seeder: base.seeder, reminders: base.reminders
        )
    }

    /// A photo in the seeded crew, and an emoji the signed-in user hasn't used on it.
    private func photo() async throws -> (DepositDetailViewModel, String) {
        let huddles = try await deps.huddleService.huddles(for: deps.session.currentUser!)
        let crew = try XCTUnwrap(huddles.first { $0.inviteCode == SeedDataService.crewInviteCode })
        let deposits = try await deps.depositService.deposits(in: crew)
        let deposit = try XCTUnwrap(deposits.first)
        let detail = DepositDetailViewModel(deps: deps, deposit: deposit)
        let emoji = try XCTUnwrap(DepositDetailViewModel.reactionEmojis.first { !detail.currentUserReacted(with: $0) })
        return (detail, emoji)
    }

    func testATapShowsAtOnceWhileTheServerIsStillAnswering() async throws {
        let (detail, emoji) = try await photo()
        let before = detail.reactionCount(for: emoji)
        reactions.holdNext = true

        let tap = Task { await detail.toggleReaction(emoji) }
        while !reactions.isHolding { await Task.yield() }

        XCTAssertEqual(detail.reactionCount(for: emoji), before + 1, "counted on the tap")
        XCTAssertTrue(detail.currentUserReacted(with: emoji))
        reactions.release()
        await tap.value
        XCTAssertEqual(detail.reactionCount(for: emoji), before + 1, "counted once, not again when stored")
    }

    func testTappingAgainTakesItBackAtOnce() async throws {
        let (detail, emoji) = try await photo()
        let before = detail.reactionCount(for: emoji)
        await detail.toggleReaction(emoji)
        reactions.holdNext = true

        let tap = Task { await detail.toggleReaction(emoji) }
        while !reactions.isHolding { await Task.yield() }

        XCTAssertEqual(detail.reactionCount(for: emoji), before)
        XCTAssertFalse(detail.currentUserReacted(with: emoji))
        reactions.release()
        await tap.value
        XCTAssertEqual(detail.reactionCount(for: emoji), before)
    }

    func testAReactionThatDidntReachTheServerGoesBack() async throws {
        let (detail, emoji) = try await photo()
        let before = detail.reactionCount(for: emoji)
        reactions.failNext = true

        await detail.toggleReaction(emoji)

        XCTAssertEqual(detail.reactionCount(for: emoji), before)
        XCTAssertFalse(detail.currentUserReacted(with: emoji))
        XCTAssertNotNil(detail.errorMessage)
    }

    func testASecondTapWaitsForTheFirst() async throws {
        let (detail, emoji) = try await photo()
        let before = detail.reactionCount(for: emoji)
        reactions.holdNext = true

        let first = Task { await detail.toggleReaction(emoji) }
        while !reactions.isHolding { await Task.yield() }
        await detail.toggleReaction(emoji)
        XCTAssertEqual(reactions.calls, 1, "ignored while the first is on its way")
        reactions.release()
        await first.value

        XCTAssertEqual(detail.reactionCount(for: emoji), before + 1)
    }
}

/// The mock deposit service, with a reaction toggle that can be held mid-flight
/// or made to fail.
@MainActor
final class HeldReactionService: DepositServiceProtocol {
    private let inner: any DepositServiceProtocol
    var holdNext = false
    var failNext = false
    private(set) var calls = 0
    private var held: CheckedContinuation<Void, Never>?

    init(inner: any DepositServiceProtocol) { self.inner = inner }

    var isHolding: Bool { held != nil }

    func release() {
        held?.resume()
        held = nil
    }

    func toggleReaction(_ emoji: String, on deposit: Deposit, by user: User) async throws {
        calls += 1
        if holdNext {
            holdNext = false
            await withCheckedContinuation { held = $0 }
        }
        if failNext {
            failNext = false
            throw URLError(.notConnectedToInternet)
        }
        try await inner.toggleReaction(emoji, on: deposit, by: user)
    }

    func deposits(in huddle: Huddle) async throws -> [Deposit] {
        try await inner.deposits(in: huddle)
    }

    func createDeposit(
        in huddle: Huddle, author: User, localImagePath: String,
        wrappedPhotoKey: String?, caption: String?, dayKey: String
    ) async throws -> Deposit {
        try await inner.createDeposit(
            in: huddle, author: author, localImagePath: localImagePath,
            wrappedPhotoKey: wrappedPhotoKey, caption: caption, dayKey: dayKey
        )
    }

    func depositorIDs(in huddles: [Huddle], dayKey: String) async throws -> [UUID: Set<UUID>] {
        try await inner.depositorIDs(in: huddles, dayKey: dayKey)
    }

    func addComment(_ text: String, to deposit: Deposit, by user: User) async throws -> Comment {
        try await inner.addComment(text, to: deposit, by: user)
    }
}

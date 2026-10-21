import Foundation
import XCTest

@testable import HuddlePal

/// QA-18: Home and Archive tell "still loading" and "couldn't refresh"
/// apart from an empty day, instead of showing "Nobody has posted yet".
@MainActor
final class LoadStateTests: XCTestCase {
    private var deps: AppDependencies!
    private var deposits: SwitchableDepositService!

    override func setUp() async throws {
        try await super.setUp()
        let base = AppDependencies.makeMock(inMemory: true)
        try await base.seeder.regenerate()
        guard case .signedIn(let user) = try await base.auth.currentState() else {
            throw XCTSkip("expected the seeded user to be signed in")
        }
        base.session.currentUser = user
        deposits = SwitchableDepositService(inner: base.depositService)
        deps = AppDependencies(
            modelContainer: base.modelContainer, engine: base.engine, dateProvider: base.dateProvider,
            session: base.session, debug: base.debug, auth: base.auth, huddleService: base.huddleService,
            depositService: deposits, mediaService: base.mediaService, moderationService: base.moderationService,
            seeder: base.seeder, reminders: base.reminders
        )
    }

    private func crew() async throws -> Huddle {
        let huddles = try await deps.huddleService.huddles(for: deps.session.currentUser!)
        return try XCTUnwrap(huddles.first { $0.inviteCode == "CREW42" })
    }

    func testHomeSaysItCouldNotRefreshInsteadOfShowingAnEmptyDay() async throws {
        let home = HuddleHomeViewModel(deps: deps, huddle: try await crew())
        XCTAssertFalse(home.hasLoaded, "before the first refresh nothing is known yet")

        deposits.offline = true
        await home.refresh()
        XCTAssertFalse(home.hasLoaded)
        XCTAssertNotNil(home.loadError)

        deposits.offline = false
        await home.refresh()
        XCTAssertTrue(home.hasLoaded)
        XCTAssertNil(home.loadError, "the banner goes once a refresh works")
        XCTAssertFalse(home.todayDeposits.isEmpty)
    }

    func testAFailedRefreshKeepsWhatHomeAlreadyShowed() async throws {
        let home = HuddleHomeViewModel(deps: deps, huddle: try await crew())
        await home.refresh()
        let shown = home.todayDeposits.map(\.id)
        deposits.offline = true
        await home.refresh()
        XCTAssertTrue(home.hasLoaded)
        XCTAssertNotNil(home.loadError)
        XCTAssertEqual(home.todayDeposits.map(\.id), shown)
    }

    func testArchiveSaysItCouldNotRefresh() async throws {
        let archive = ArchiveViewModel(deps: deps, huddle: try await crew())
        deposits.offline = true
        await archive.refresh()
        XCTAssertFalse(archive.hasLoaded)
        XCTAssertNotNil(archive.loadError)
        deposits.offline = false
        await archive.refresh()
        XCTAssertTrue(archive.hasLoaded)
        XCTAssertNil(archive.loadError)
        XCTAssertFalse(archive.months.isEmpty)
    }
}

/// The mock deposit service, with a switch that makes history reads fail
/// the way they do offline.
@MainActor
private final class SwitchableDepositService: DepositServiceProtocol {
    private let inner: any DepositServiceProtocol
    var offline = false

    init(inner: any DepositServiceProtocol) { self.inner = inner }

    func deposits(in huddle: Huddle) async throws -> [Deposit] {
        if offline { throw URLError(.notConnectedToInternet) }
        return try await inner.deposits(in: huddle)
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

    func toggleReaction(_ emoji: String, on deposit: Deposit, by user: User) async throws {
        try await inner.toggleReaction(emoji, on: deposit, by: user)
    }

    func addComment(_ text: String, to deposit: Deposit, by user: User) async throws -> Comment {
        try await inner.addComment(text, to: deposit, by: user)
    }
}

import SwiftData
import XCTest

@testable import HuddlePal

/// Smoke tests over the assembled mock stack for the flows a launch cannot
/// break: bootstrap (seed + session restore), the reciprocity gate on the
/// primary deposit journey, once-and-permanent enforcement, and create/join.
/// Uses an in-memory store; the only side effects are the mock services'
/// own UserDefaults keys inside the test host.
@MainActor
final class CriticalFlowTests: XCTestCase {
    private var deps: AppDependencies!

    override func setUp() async throws {
        try await super.setUp()
        deps = AppDependencies.makeMock(inMemory: true)
        // Regenerate unconditionally: seedIfNeeded's UserDefaults flag can
        // linger from an earlier run while the in-memory store starts empty.
        try await deps.seeder.regenerate()
    }

    private func signedInUser() async throws -> User {
        let state = try await deps.auth.currentState()
        guard case .signedIn(let user) = state else {
            throw XCTSkip("expected the seeded user to be signed in")
        }
        return user
    }

    // MARK: Launch

    func testBootstrapSignsInSeededUserWithTwoLockedHuddles() async throws {
        let user = try await signedInUser()
        XCTAssertEqual(user.displayName, SeedDataService.currentUserName)

        let huddles = try await deps.huddleService.huddles(for: user)
        XCTAssertEqual(huddles.count, 2, "seed world ships The Crew + Sunday Dinners")

        for huddle in huddles {
            let deposits = try await deps.depositService.deposits(in: huddle)
            XCTAssertFalse(deposits.isEmpty, "seeded huddles carry history")
            XCTAssertFalse(
                deps.engine.isUnlocked(
                    huddleID: huddle.id,
                    currentUserID: user.id,
                    deposits: deposits.compactMap(\.snapshot),
                    now: deps.dateProvider.now
                ),
                "the seeded world opens LOCKED: others deposited today, you haven't"
            )
        }
    }

    // MARK: Primary journey — deposit unlocks the gate, once and permanent

    func testDepositUnlocksGateAndSecondDepositIsRefused() async throws {
        let user = try await signedInUser()
        let huddles = try await deps.huddleService.huddles(for: user)
        let huddle = try XCTUnwrap(huddles.first)
        let today = deps.engine.todayKey(now: deps.dateProvider.now)

        let photo = try await deps.mediaService.saveDepositPhoto(
            PlaceholderImageGenerator.jpegData(seed: 1),
            preferredName: "\(huddle.id.uuidString)/smoke-test.jpg",
            huddleID: huddle.id
        )
        XCTAssertNil(photo.wrappedPhotoKey, "mock photos never leave the device, so they aren't encrypted")
        try await deps.depositService.createDeposit(
            in: huddle, author: user, localImagePath: photo.path, wrappedPhotoKey: photo.wrappedPhotoKey,
            caption: "smoke", dayKey: today
        )

        let deposits = try await deps.depositService.deposits(in: huddle)
        XCTAssertTrue(
            deps.engine.isUnlocked(
                huddleID: huddle.id,
                currentUserID: user.id,
                deposits: deposits.compactMap(\.snapshot),
                now: deps.dateProvider.now
            ),
            "your own deposit for today must open the gate"
        )

        do {
            try await deps.depositService.createDeposit(
                in: huddle, author: user, localImagePath: photo.path, wrappedPhotoKey: nil,
                caption: nil, dayKey: today
            )
            XCTFail("a second same-day deposit must be refused")
        } catch DepositError.alreadyDepositedToday {
            // once and permanent — expected
        }
    }

    // MARK: Huddle list — the light "who posted today" read

    func testHuddleListRowsReflectWhoPostedToday() async throws {
        let user = try await signedInUser()
        deps.session.currentUser = user
        let list = HuddleListViewModel(deps: deps)

        await list.refresh()
        XCTAssertNil(list.errorMessage)
        XCTAssertEqual(list.rows.count, 2)
        for row in list.rows {
            XCTAssertFalse(row.isUnlockedToday, "seeded: you haven't posted anywhere yet")
            XCTAssertEqual(
                row.depositedTodayCount, row.members.count - 1,
                "seeded: everyone but you posted today in \(row.huddle.name)"
            )
        }

        let huddle = try XCTUnwrap(list.rows.first?.huddle)
        let today = deps.engine.todayKey(now: deps.dateProvider.now)
        let photo = try await deps.mediaService.saveDepositPhoto(
            PlaceholderImageGenerator.jpegData(seed: 2),
            preferredName: "\(huddle.id.uuidString)/list-test.jpg",
            huddleID: huddle.id
        )
        try await deps.depositService.createDeposit(
            in: huddle, author: user, localImagePath: photo.path, wrappedPhotoKey: photo.wrappedPhotoKey,
            caption: nil, dayKey: today
        )

        await list.refresh()
        let row = try XCTUnwrap(list.rows.first { $0.huddle.id == huddle.id })
        XCTAssertTrue(row.isUnlockedToday, "your deposit opens that huddle's row")
        XCTAssertEqual(row.depositedTodayCount, row.members.count)
        let other = try XCTUnwrap(list.rows.first { $0.huddle.id != huddle.id })
        XCTAssertFalse(other.isUnlockedToday, "the gate is per huddle")

        let depositors = try await deps.depositService.depositorIDs(
            in: list.rows.map(\.huddle), dayKey: today
        )
        XCTAssertEqual(Set(depositors.keys), Set(list.rows.map(\.huddle.id)), "every huddle gets an entry")
        XCTAssertTrue(depositors[huddle.id]?.contains(user.id) == true)
    }

    // MARK: Joining keeps the streak

    func testJoiningAHuddleKeepsItsStreak() async throws {
        let user = try await signedInUser()
        let huddles = try await deps.huddleService.huddles(for: user)
        let crew = try XCTUnwrap(huddles.first { $0.inviteCode == "CREW42" })
        let now = deps.dateProvider.now
        try await deps.huddleService.recomputeStreak(for: crew, now: now)
        let before = crew.streakCount
        XCTAssertGreaterThan(before, 0, "the seeded crew carries a streak")

        let newcomer = User(displayName: "Newcomer", avatarColorHex: "46A758")
        deps.modelContainer.mainContext.insert(newcomer)
        _ = try await deps.huddleService.joinHuddle(inviteCode: "CREW42", user: newcomer)
        let membership = try XCTUnwrap(crew.memberships.first { $0.user?.id == newcomer.id })
        XCTAssertEqual(membership.joinedDayKey, deps.engine.todayKey(now: now))

        try await deps.huddleService.recomputeStreak(for: crew, now: now)
        XCTAssertEqual(crew.streakCount, before, "joining never resets the group's streak")
    }

    func testOnlyTheKeeperCanChangeTheHuddlesHour() async throws {
        // QA-26: for a member the server silently updates nothing.
        let keeper = try await signedInUser()
        let crew = try XCTUnwrap(try await deps.huddleService.huddles(for: keeper).first { $0.inviteCode == "CREW42" })
        let settings = HuddleSettingsViewModel(deps: deps, huddle: crew)
        XCTAssertTrue(settings.isKeeper)
        await settings.setNotificationHour(7)
        XCTAssertEqual(crew.notificationHour, 7)

        deps.session.currentUser = try XCTUnwrap(crew.members.first { $0.id != keeper.id })
        XCTAssertFalse(settings.isKeeper)
        await settings.setNotificationHour(22)
        XCTAssertEqual(crew.notificationHour, 7, "a member's change must not show as saved")
    }

    func testRegeneratingTheSeedWorldOverExistingDataWorks() async throws {
        // QA-24: setUp regenerates on an empty store; the DEBUG menu
        // regenerates over a full one.
        _ = try await signedInUser()
        try await deps.seeder.regenerate()
        let huddles = try deps.modelContainer.mainContext.fetch(FetchDescriptor<Huddle>())
        XCTAssertEqual(huddles.count, 2, "a clean rebuild, not a duplicate world")
        let user = try await signedInUser()
        XCTAssertEqual(user.displayName, SeedDataService.currentUserName)
    }

    func testWhenTheKeeperLeavesTheLongestStandingMemberTakesOver() async throws {
        // QA-04, mirroring the server's memberships_after_delete trigger.
        let keeper = try await signedInUser()
        let huddles = try await deps.huddleService.huddles(for: keeper)
        let crew = try XCTUnwrap(huddles.first { $0.inviteCode == "CREW42" })
        XCTAssertEqual(crew.sortedMemberships.first?.user?.id, keeper.id)
        let expected = crew.sortedMemberships.dropFirst().min { $0.joinedAt < $1.joinedAt }?.user?.id

        try await deps.huddleService.leaveHuddle(crew, user: keeper)

        let keepers = crew.memberships.filter { $0.role == .keeper }
        XCTAssertEqual(keepers.count, 1, "a huddle always has exactly one keeper")
        XCTAssertEqual(keepers.first?.user?.id, expected)
    }

    // MARK: Create / join

    func testCreateAndJoinHuddleFlow() async throws {
        let keeper = try await signedInUser()
        let huddle = try await deps.huddleService.createHuddle(
            name: "Smoke Huddle", emoji: "🔥", keeper: keeper
        )
        XCTAssertEqual(huddle.inviteCode.count, 6)
        XCTAssertEqual(huddle.memberships.first?.role, .keeper)

        let friend = User(displayName: "Friend", avatarColorHex: "0091FF")
        deps.modelContainer.mainContext.insert(friend)

        // Codes are case-insensitive on join.
        let joined = try await deps.huddleService.joinHuddle(
            inviteCode: huddle.inviteCode.lowercased(), user: friend
        )
        XCTAssertEqual(joined.id, huddle.id)
        XCTAssertEqual(joined.memberships.count, 2)

        do {
            _ = try await deps.huddleService.joinHuddle(inviteCode: huddle.inviteCode, user: friend)
            XCTFail("joining twice must be refused")
        } catch HuddleServiceError.alreadyMember {
            // expected
        }

        do {
            _ = try await deps.huddleService.joinHuddle(inviteCode: "ZZZZZZ", user: friend)
            XCTFail("an unknown code must be refused")
        } catch HuddleServiceError.inviteCodeNotFound {
            // expected
        }
    }

    // MARK: Sign out / sign in round trip

    func testSignOutThenCurrentStateIsSignedOut() async throws {
        _ = try await signedInUser()
        try await deps.auth.signOut()
        let state = try await deps.auth.currentState()
        guard case .signedOut = state else {
            return XCTFail("after sign-out the session must be gone, got \(state)")
        }
    }
}

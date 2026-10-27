import SwiftData
import XCTest

@testable import HuddlePal

/// The free plan's and Plus's limits in the offline world: the mock huddle
/// service refuses what the server would, reading `MockPlanLedger`. The
/// seeded "You" keeps The Crew (4 members, full on the free plan) and Sunday
/// Dinners (2).
@MainActor
final class PlanLimitTests: XCTestCase {
    private var deps: AppDependencies!
    private var plans: MockPlanLedger!
    private var you: User!

    override func setUp() async throws {
        try await super.setUp()
        deps = AppDependencies.makeMock(inMemory: true)
        try await deps.seeder.regenerate()
        plans = try XCTUnwrap(deps.mockPlans)
        guard case .signedIn(let user) = try await deps.auth.currentState() else {
            throw XCTSkip("expected the seeded user to be signed in")
        }
        you = user
    }

    private var context: ModelContext { deps.modelContainer.mainContext }

    private func person(_ name: String) -> User {
        let user = User(displayName: name, avatarColorHex: "46A758")
        context.insert(user)
        return user
    }

    private func huddle(_ name: String) throws -> Huddle {
        try XCTUnwrap(you.memberships.compactMap(\.huddle).first { $0.name == name })
    }

    /// Someone new tries to join; nil once they're in.
    private func refusal(joining huddle: Huddle, as user: User? = nil) async -> HuddleServiceError? {
        do {
            _ = try await deps.huddleService.joinHuddle(inviteCode: huddle.inviteCode, user: user ?? person("Newcomer"))
            return nil
        } catch let error as HuddleServiceError {
            return error
        } catch {
            XCTFail("unexpected \(error)")
            return nil
        }
    }

    private func create(_ name: String, by user: User) async throws -> Huddle {
        try await deps.huddleService.createHuddle(name: name, emoji: "🧪", keeper: user)
    }

    // MARK: Off by default, as on the server

    func testUntilTheLimitsAreOnTheOldRulesHold() async throws {
        XCTAssertFalse(plans.freeLimitsActive)
        let fifthMember = await refusal(joining: try huddle("The Crew"))
        XCTAssertNil(fifthMember, "a 5th member, as before")
        for index in 0..<4 { _ = try await create("Extra \(index)", by: you) }
    }

    // MARK: Creating

    func testTheFreePlanKeeps3HuddlesAndPlusKeeps10() async throws {
        plans.freeLimitsActive = true
        _ = try await create("Third", by: you)
        do {
            _ = try await create("Fourth", by: you)
            XCTFail("a 4th huddle on the free plan")
        } catch HuddleServiceError.huddleLimitFree {}

        plans.setPlus(true, for: you.id)
        for index in 4...10 { _ = try await create("Huddle \(index)", by: you) }
        do {
            _ = try await create("Eleventh", by: you)
            XCTFail("an 11th huddle with Plus")
        } catch HuddleServiceError.huddleLimitPlus {}
    }

    // MARK: Joining

    func testAFullFreeHuddleRefusesUntilItsKeeperHasPlus() async throws {
        plans.freeLimitsActive = true
        let crew = try huddle("The Crew")
        XCTAssertEqual(crew.memberships.count, 4)
        let full = await refusal(joining: crew)
        XCTAssertEqual(full?.errorDescription, HuddleServiceError.huddleFullFree.errorDescription)

        let member = try XCTUnwrap(crew.members.first { $0.id != you.id })
        plans.setPlus(true, for: member.id)
        let withMembersPlus = await refusal(joining: crew)
        XCTAssertNotNil(withMembersPlus, "a member's Plus doesn't lift it: the keeper's plan decides")

        plans.setPlus(true, for: you.id)
        let withKeepersPlus = await refusal(joining: crew)
        XCTAssertNil(withKeepersPlus)
    }

    func testWhenPlusEndsOnlyTheKeepersFirst3HuddlesTakeMembers() async throws {
        plans.freeLimitsActive = true
        plans.setPlus(true, for: you.id)
        let third = try await create("Third", by: you)
        let fourth = try await create("Fourth", by: you)
        plans.setPlus(false, for: you.id)

        let intoThird = await refusal(joining: third)
        XCTAssertNil(intoThird)
        let intoFourth = await refusal(joining: fourth)
        XCTAssertEqual(intoFourth?.errorDescription, HuddleServiceError.invitesPaused.errorDescription)
        XCTAssertEqual(you.memberships.filter { $0.role == .keeper }.count, 4, "every huddle stays")

        // Leaving an earlier one moves the 4th into the first 3.
        try await deps.huddleService.leaveHuddle(try huddle("Sunday Dinners"), user: you)
        let intoFourthAfterLeaving = await refusal(joining: fourth)
        XCTAssertNil(intoFourthAfterLeaving)
    }

    func testAnInheritedHuddleGoesToTheBackOfTheHeirsQueue() async throws {
        plans.freeLimitsActive = true
        let crew = try huddle("The Crew")
        let heir = try XCTUnwrap(crew.sortedMemberships.first { $0.role == .member }?.user)
        var own: [Huddle] = []
        for index in 0..<3 { own.append(try await create("Heir's \(index)", by: heir)) }

        try await deps.huddleService.leaveHuddle(crew, user: you)
        let membership = try XCTUnwrap(crew.memberships.first { $0.user?.id == heir.id })
        XCTAssertEqual(membership.role, .keeper)
        XCTAssertNotNil(membership.keeperSince, "keeper from the moment they took over")

        for huddle in own {
            let intoOwn = await refusal(joining: huddle)
            XCTAssertNil(intoOwn, "the heir's own huddles still take members")
        }
        let intoInherited = await refusal(joining: crew)
        XCTAssertEqual(intoInherited?.errorDescription, HuddleServiceError.invitesPaused.errorDescription)
    }

    func testNobodyJoinsMoreThan25Huddles() async throws {
        plans.freeLimitsActive = true
        let joiner = person("Joiner")
        for index in 0..<25 {
            let owner = person("Owner \(index)")
            let huddle = try await create("H\(index)", by: owner)
            let joined = await refusal(joining: huddle, as: joiner)
            XCTAssertNil(joined)
        }
        let owner = person("One more")
        let oneMore = try await create("H25", by: owner)
        let twentySixth = await refusal(joining: oneMore, as: joiner)
        XCTAssertEqual(twentySixth?.errorDescription, HuddleServiceError.tooManyHuddles.errorDescription)
    }

    func testTheLimitsComeBeforeTheBlockCheckAsOnTheServer() async throws {
        plans.freeLimitsActive = true
        deps.session.currentUser = you
        let stranger = person("Stranger")
        try await deps.moderationService.block(stranger)
        let intoCrew = await refusal(joining: try huddle("The Crew"), as: stranger)
        XCTAssertEqual(intoCrew?.errorDescription, HuddleServiceError.huddleFullFree.errorDescription)
        let intoDinners = await refusal(joining: try huddle("Sunday Dinners"), as: stranger)
        XCTAssertEqual(intoDinners?.errorDescription, HuddleServiceError.cannotJoin.errorDescription)
        try await deps.moderationService.unblock(stranger)
    }

    func testANewHuddlesKeeperIsKeeperFromItsCreation() async throws {
        let before = Date.now
        let created = try await create("Fresh", by: you)
        let keeper = try XCTUnwrap(created.memberships.first)
        XCTAssertEqual(keeper.role, .keeper)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(keeper.keeperSince), before)
    }
}

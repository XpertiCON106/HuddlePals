import Foundation
import XCTest

@testable import HuddlePal

/// QA-16: huddlepal://join/<code> links, signed in or not.
@MainActor
final class InviteLinkTests: XCTestCase {
    func testOnlyWellFormedJoinLinksCarryACode() {
        XCTAssertEqual(InviteLink.code(from: URL(string: "huddlepal://join/crew42")!), "CREW42")
        XCTAssertEqual(InviteLink.code(from: URL(string: "huddlepal://join/PASTA7")!), "PASTA7")
        for bad in [
            "huddlepal://join/ABCD",        // too short for the Join screen
            "huddlepal://join/ABCDEFGH",    // too long: used to leave a dead button
            "huddlepal://join/AB%20CDE",
            "huddlepal://join/ABC-12",
            "huddlepal://other/CREW42",
            "https://join/CREW42",
        ] {
            XCTAssertNil(InviteLink.code(from: URL(string: bad)!), bad)
        }
    }

    func testALinkOpenedWhileSignedOutOpensJoinAfterSignIn() {
        let session = AppSession()
        let router = AppRouter()
        session.pendingInviteCode = "CREW42"
        router.openPendingInvite(session)
        XCTAssertEqual(router.huddlesPath, [.joinHuddle])
        // Join then takes the code.
        let join = JoinHuddleViewModel(deps: dependencies(session))
        XCTAssertEqual(join.code, "CREW42")
        XCTAssertNil(session.pendingInviteCode, "used once")
    }

    func testNoPendingInviteMeansNoNavigation() {
        let router = AppRouter()
        router.openPendingInvite(AppSession())
        XCTAssertTrue(router.huddlesPath.isEmpty)
    }

    func testASecondLinkWhileJoinIsOpenReplacesTheCode() {
        let session = AppSession()
        session.pendingInviteCode = "CREW42"
        let join = JoinHuddleViewModel(deps: dependencies(session))
        session.pendingInviteCode = "PASTA7"
        join.usePendingInvite()
        XCTAssertEqual(join.code, "PASTA7")
        XCTAssertNil(session.pendingInviteCode)
    }

    private func dependencies(_ session: AppSession) -> AppDependencies {
        let base = AppDependencies.makeMock(inMemory: true)
        return AppDependencies(
            modelContainer: base.modelContainer, engine: base.engine, dateProvider: base.dateProvider,
            session: session, debug: base.debug, auth: base.auth, huddleService: base.huddleService,
            depositService: base.depositService, mediaService: base.mediaService,
            moderationService: base.moderationService, seeder: base.seeder, reminders: base.reminders
        )
    }
}

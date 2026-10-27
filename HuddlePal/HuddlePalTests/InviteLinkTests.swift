import Foundation
import LinkPresentation
import UIKit
import XCTest

@testable import HuddlePal

/// Invite links, https://huddlepals.com/join#<code> (and huddlepal://join/<code>
/// from before), signed in or not, and how they're shared.
@MainActor
final class InviteLinkTests: XCTestCase {
    func testTheLinkIsAWebLinkWithTheCodeWhereNoServerSeesIt() throws {
        let code = InviteCode.generate()
        let url = InviteLink.url(for: code)
        XCTAssertEqual(url.absoluteString, "https://huddlepals.com/join#\(code.compact)")
        XCTAssertEqual(url.fragment, code.compact, "a fragment: browsers and link previews never send it")
        XCTAssertFalse(url.path.contains(code.compact))
        XCTAssertEqual(InviteLink.code(from: url), code.compact)
        XCTAssertEqual(InviteLink.code(from: URL(string: "https://HuddlePals.com/join/#\(code.displayed.lowercased())")!), code.compact)
        for other in [
            "https://huddlepals.com/join/\(code.compact)",   // in the path: would reach the server
            "https://huddlepals.com/join",
            "https://huddlepals.com/support#\(code.compact)",
            "https://example.com/join#\(code.compact)",
            "http://huddlepals.com/join#\(code.compact)",
        ] {
            XCTAssertNil(InviteLink.code(from: URL(string: other)!), other)
        }
    }

    func testOnlyWellFormedJoinLinksCarryACode() {
        let code = InviteCode.generate()
        XCTAssertEqual(InviteLink.code(from: URL(string: "huddlepal://join/\(code.displayed.lowercased())")!), code.compact)
        // Old codes still open Join, which explains they're out of date.
        XCTAssertEqual(InviteLink.code(from: URL(string: "huddlepal://join/crew42")!), "CREW42")
        XCTAssertEqual(InviteLink.code(from: URL(string: "huddlepal://join/PASTA7")!), "PASTA7")
        for bad in [
            "huddlepal://join/ABCD",        // too short for the Join screen
            "huddlepal://join/ABCDEFGH",    // too long: used to leave a dead button
            "huddlepal://join/AB%20CDE",
            "huddlepal://join/ABC-12",
            "huddlepal://join/\(code.compact.dropLast())",
            "huddlepal://join/\(code.compact.dropLast())O", // not in the alphabet
            "huddlepal://other/CREW42",
            "https://join/CREW42",
        ] {
            XCTAssertNil(InviteLink.code(from: URL(string: bad)!), bad)
        }
    }

    func testSharingGivesMessagesAPreviewAndOtherAppsALine() throws {
        let url = InviteLink.url(for: InviteCode.generate())
        let card = try XCTUnwrap(InviteCard.image(name: "The Crew", emoji: "🏔"))
        XCTAssertEqual(card.size, InviteCard.size)
        XCTAssertEqual(card.scale, 3)

        let item = InviteActivityItem(url: url, huddleName: "The Crew", card: card)
        let sheet = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        let metadata = try XCTUnwrap(item.activityViewControllerLinkMetadata(sheet))
        XCTAssertEqual(metadata.title, "Join “The Crew” on HuddlePals")
        XCTAssertEqual(metadata.url, url)
        XCTAssertNotNil(metadata.imageProvider, "the card")
        XCTAssertEqual(item.activityViewController(sheet, itemForActivityType: .message) as? URL, url, "just the link, as a preview")
        XCTAssertEqual(item.activityViewController(sheet, itemForActivityType: .copyToPasteboard) as? URL, url)
        XCTAssertEqual(
            item.activityViewController(sheet, itemForActivityType: .mail) as? String,
            "Join our huddle “The Crew” on HuddlePals: \(url.absoluteString)"
        )
        XCTAssertEqual(item.activityViewController(sheet, subjectForActivityType: .mail), "Join “The Crew” on HuddlePals")
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
            session: session, debug: base.debug, auth: base.auth, appleReauth: base.appleReauth, huddleService: base.huddleService,
            depositService: base.depositService, mediaService: base.mediaService,
            moderationService: base.moderationService, seeder: base.seeder, reminders: base.reminders
        )
    }
}

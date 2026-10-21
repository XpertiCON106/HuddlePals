import Foundation
import XCTest

@testable import HuddlePal

/// App Review guideline 1.2: every kind of user-generated content (photos,
/// comments, profiles) can be reported, and the reporter is thanked.
@MainActor
final class ReportingTests: XCTestCase {
    private var deps: AppDependencies!
    private var moderation: ModerationSpy!
    private var me: User!
    private var other: User!
    private var deposit: Deposit!

    override func setUp() async throws {
        try await super.setUp()
        let base = AppDependencies.makeMock(inMemory: true)
        moderation = ModerationSpy()
        deps = AppDependencies(
            modelContainer: base.modelContainer, engine: base.engine, dateProvider: base.dateProvider,
            session: base.session, debug: base.debug, auth: base.auth, appleReauth: base.appleReauth,
            huddleService: base.huddleService, depositService: base.depositService,
            mediaService: base.mediaService, moderationService: moderation,
            seeder: base.seeder, reminders: base.reminders
        )
        let context = base.modelContainer.mainContext
        me = User(displayName: "Me", avatarColorHex: "E5484D")
        other = User(displayName: "Other", avatarColorHex: "0091FF")
        let huddle = Huddle(name: "Crew", emoji: "🏔", inviteCode: "CREW42")
        deposit = Deposit(huddle: huddle, author: other, localImagePath: "Media/x/y.jpg", dayKey: "2026-10-20")
        for model in [me, other] as [User] { context.insert(model) }
        context.insert(huddle)
        context.insert(deposit)
        deps.session.currentUser = me
    }

    func testSomeoneElsesCommentCanBeReportedAndTheReporterIsThanked() async {
        let theirs = Comment(deposit: deposit, user: other, text: "not nice")
        let former = Comment(deposit: deposit, user: nil, text: "from someone who left")
        let mine = Comment(deposit: deposit, user: me, text: "hi")
        let viewModel = DepositDetailViewModel(deps: deps, deposit: deposit)

        XCTAssertTrue(viewModel.canReport(theirs))
        XCTAssertTrue(viewModel.canReport(former), "a Former member's comment stays reportable")
        XCTAssertFalse(viewModel.canReport(mine))

        await viewModel.report(theirs)
        XCTAssertEqual(moderation.reportedComments, [theirs.id])
        XCTAssertEqual(viewModel.reportedCommentIDs, [theirs.id])
        XCTAssertTrue(viewModel.isReportConfirmationPresented)
    }

    func testReportingAPhotoThanksTheReporter() async {
        let viewModel = DepositDetailViewModel(deps: deps, deposit: deposit)
        await viewModel.report()
        XCTAssertEqual(moderation.reportedDeposits, [deposit.id])
        XCTAssertTrue(viewModel.didReport)
        XCTAssertTrue(viewModel.isReportConfirmationPresented)
    }

    func testAMembersProfileCanBeReported() async {
        let viewModel = UserProfileViewModel(deps: deps, user: other)
        await viewModel.report()
        XCTAssertEqual(moderation.reportedUsers, [other.id])
        XCTAssertTrue(viewModel.didReport)
        XCTAssertTrue(viewModel.isReportAlertPresented)
    }

    func testAProfileReportThatFailsSaysSoAndCanBeRetried() async {
        moderation.failNext = true
        let viewModel = UserProfileViewModel(deps: deps, user: other)
        await viewModel.report()
        XCTAssertFalse(viewModel.didReport, "Report stays available to try again")
        XCTAssertTrue(viewModel.isReportAlertPresented, "the alert says it didn't go through")
        XCTAssertEqual(moderation.reportedUsers, [])
    }
}

@MainActor
private final class ModerationSpy: ModerationServiceProtocol {
    private(set) var reportedDeposits: [UUID] = []
    private(set) var reportedComments: [UUID] = []
    private(set) var reportedUsers: [UUID] = []
    var failNext = false

    private func checkFailure() throws {
        if failNext {
            failNext = false
            throw URLError(.notConnectedToInternet)
        }
    }

    func report(deposit: Deposit, reason: String?) async throws {
        try checkFailure()
        reportedDeposits.append(deposit.id)
    }

    func report(comment: Comment) async throws {
        try checkFailure()
        reportedComments.append(comment.id)
    }

    func report(user: User) async throws {
        try checkFailure()
        reportedUsers.append(user.id)
    }

    func block(_ user: User) async throws {}
    func unblock(_ user: User) async throws {}
    func blockedUserIDs() async throws -> Set<UUID> { [] }
}

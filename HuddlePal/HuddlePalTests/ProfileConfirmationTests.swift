import Foundation
import XCTest

@testable import HuddlePal

@MainActor
final class ProfileConfirmationTests: XCTestCase {
    private var deps: AppDependencies!
    private var auth: ProfileAuthSpy!
    private var media: ProfileMediaSpy!
    private var user: User!
    private var viewModel: ProfileViewModel!

    override func setUp() async throws {
        try await super.setUp()
        let base = AppDependencies.makeMock(inMemory: true)
        user = User(
            displayName: "Taylor",
            avatarColorHex: "E5484D",
            bio: "Original bio",
            profilePhotoPaths: ["Media/avatars/original-a.jpg", "Media/avatars/original-b.jpg"]
        )
        base.modelContainer.mainContext.insert(user)
        try base.modelContainer.mainContext.save()
        base.session.currentUser = user

        auth = ProfileAuthSpy()
        media = ProfileMediaSpy()
        deps = AppDependencies(
            modelContainer: base.modelContainer,
            engine: base.engine,
            dateProvider: base.dateProvider,
            session: base.session,
            debug: base.debug,
            appearance: base.appearance,
            auth: auth,
            huddleService: base.huddleService,
            depositService: base.depositService,
            mediaService: media,
            moderationService: base.moderationService,
            seeder: base.seeder,
            reminders: base.reminders
        )
        viewModel = ProfileViewModel(deps: deps)
        await viewModel.loadInitialState()
    }

    func testNoChangesDisablesSaveAndAllowsExitWithoutWarning() {
        XCTAssertFalse(viewModel.hasUnsavedChanges)
        XCTAssertFalse(viewModel.canSaveChanges)

        viewModel.requestSaveConfirmation()
        XCTAssertFalse(viewModel.isSaveConfirmationPresented)
        XCTAssertTrue(viewModel.requestNavigation())
        XCTAssertFalse(viewModel.isUnsavedChangesWarningPresented)
        XCTAssertEqual(auth.updateCalls, 0)
    }

    func testBioChangeRequiresConfirmationCancelPreservesAndConfirmSavesOnce() async {
        viewModel.bio = "A confirmed bio"
        XCTAssertTrue(viewModel.hasUnsavedChanges)

        viewModel.requestSaveConfirmation()
        XCTAssertTrue(viewModel.isSaveConfirmationPresented)
        viewModel.cancelSaveConfirmation()
        XCTAssertEqual(viewModel.bio, "A confirmed bio")
        XCTAssertTrue(viewModel.hasUnsavedChanges)
        XCTAssertEqual(auth.updateCalls, 0)

        viewModel.requestSaveConfirmation()
        let result = await viewModel.confirmAndSave()
        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(auth.updateCalls, 1)
        XCTAssertEqual(auth.lastBio, "A confirmed bio")
        XCTAssertFalse(viewModel.hasUnsavedChanges)
        XCTAssertFalse(viewModel.canSaveChanges)
    }

    func testBioChangeRevertedOrPresentationWhitespaceDoesNotStayDirty() {
        viewModel.bio = "Different"
        XCTAssertTrue(viewModel.hasUnsavedChanges)

        viewModel.bio = "  Original bio\n"
        XCTAssertFalse(viewModel.hasUnsavedChanges)
        XCTAssertTrue(viewModel.requestNavigation())
    }

    func testAvatarChangeCannotPersistBeforeConfirmation() async {
        viewModel.selectedColorHex = "0091FF"
        viewModel.requestSaveConfirmation()
        viewModel.cancelSaveConfirmation()

        XCTAssertEqual(user.avatarColorHex, "E5484D")
        XCTAssertEqual(auth.updateCalls, 0)
        XCTAssertTrue(viewModel.hasUnsavedChanges)

        viewModel.requestSaveConfirmation()
        let result = await viewModel.confirmAndSave()
        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(auth.lastAvatarColorHex, "0091FF")
        XCTAssertEqual(user.avatarColorHex, "0091FF")
        XCTAssertFalse(viewModel.hasUnsavedChanges)
    }

    func testAddedPhotoIsStagedUntilConfirmed() async {
        let stagedData = Data("new-photo".utf8)
        viewModel.stagePhotoData(stagedData)

        XCTAssertTrue(viewModel.hasUnsavedChanges)
        XCTAssertEqual(media.saveCalls, 0)
        XCTAssertEqual(auth.updateCalls, 0)

        viewModel.requestSaveConfirmation()
        viewModel.cancelSaveConfirmation()
        XCTAssertEqual(viewModel.draftPhotos.last?.previewData, stagedData)
        XCTAssertEqual(media.saveCalls, 0)

        viewModel.requestSaveConfirmation()
        let result = await viewModel.confirmAndSave()
        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(media.saveCalls, 1)
        XCTAssertEqual(auth.updateCalls, 1)
        XCTAssertEqual(auth.lastPhotoPaths?.count, 3)
        XCTAssertFalse(viewModel.hasUnsavedChanges)
    }

    func testRemovedAndReplacedPhotosAreOneConfirmedUpdate() async {
        viewModel.removePhoto(at: 0)
        XCTAssertTrue(viewModel.hasUnsavedChanges)
        XCTAssertEqual(auth.updateCalls, 0)

        viewModel.stagePhotoData(Data("replacement".utf8))
        viewModel.requestSaveConfirmation()
        let result = await viewModel.confirmAndSave()
        XCTAssertEqual(result, .succeeded)

        XCTAssertEqual(auth.updateCalls, 1)
        XCTAssertEqual(media.saveCalls, 1)
        XCTAssertEqual(auth.lastPhotoPaths?.count, 2)
        XCTAssertFalse(auth.lastPhotoPaths?.contains("Media/avatars/original-a.jpg") ?? true)
        XCTAssertFalse(viewModel.hasUnsavedChanges)
    }

    func testMultipleFieldsSaveAsOneConfirmedDraft() async {
        viewModel.bio = "Everything changed"
        viewModel.selectedColorHex = "6E56CF"
        viewModel.removePhoto(at: 1)

        viewModel.requestSaveConfirmation()
        let result = await viewModel.confirmAndSave()
        XCTAssertEqual(result, .succeeded)

        XCTAssertEqual(auth.updateCalls, 1)
        XCTAssertEqual(auth.lastBio, "Everything changed")
        XCTAssertEqual(auth.lastAvatarColorHex, "6E56CF")
        XCTAssertEqual(auth.lastPhotoPaths, ["Media/avatars/original-a.jpg"])
    }

    func testUnsavedNavigationCanKeepEditingOrDiscardWithoutLeaving() {
        viewModel.bio = "Unsaved"
        XCTAssertFalse(viewModel.requestNavigation())
        XCTAssertTrue(viewModel.isUnsavedChangesWarningPresented)

        viewModel.keepEditing()
        XCTAssertFalse(viewModel.isUnsavedChangesWarningPresented)
        XCTAssertTrue(viewModel.hasUnsavedChanges)
        XCTAssertEqual(viewModel.bio, "Unsaved")

        XCTAssertFalse(viewModel.requestNavigation())
        viewModel.discardChanges()
        XCTAssertFalse(viewModel.isUnsavedChangesWarningPresented)
        XCTAssertEqual(viewModel.bio, "Original bio")
        XCTAssertFalse(viewModel.hasUnsavedChanges)
        XCTAssertTrue(viewModel.requestNavigation(), "a new attempt may proceed after discard")
    }

    func testNormalSaveConfirmationStillWorksAfterBlockedNavigation() async {
        viewModel.bio = "Save independently"
        XCTAssertFalse(viewModel.requestNavigation())
        viewModel.keepEditing()

        viewModel.requestSaveConfirmation()
        XCTAssertFalse(viewModel.isUnsavedChangesWarningPresented)
        XCTAssertTrue(viewModel.isSaveConfirmationPresented)
        XCTAssertEqual(auth.updateCalls, 0)

        let result = await viewModel.confirmAndSave()
        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(auth.updateCalls, 1)
        XCTAssertFalse(viewModel.hasUnsavedChanges)
    }

    func testAccountExitIsNotQueuedAfterDiscard() {
        viewModel.bio = "Unsaved"
        XCTAssertNil(viewModel.requestExit(.signOut))

        viewModel.discardChanges()
        XCTAssertFalse(viewModel.hasUnsavedChanges)
        // Discard did not return or execute Sign Out. Only this new explicit
        // attempt yields an action for the view to perform.
        XCTAssertEqual(viewModel.requestExit(.signOut), .signOut)
    }

    func testSaveFailurePreservesDraftDirtyStateAndAllowsRetry() async {
        viewModel.bio = "Retry me"
        auth.failNextUpdate = true
        viewModel.requestSaveConfirmation()

        let failedResult = await viewModel.confirmAndSave()
        XCTAssertEqual(failedResult, .failed)
        XCTAssertTrue(viewModel.hasUnsavedChanges)
        XCTAssertEqual(viewModel.bio, "Retry me")
        XCTAssertNotNil(viewModel.statusMessage)
        XCTAssertFalse(viewModel.isSaving)

        viewModel.requestSaveConfirmation()
        let retryResult = await viewModel.confirmAndSave()
        XCTAssertEqual(retryResult, .succeeded)
        XCTAssertEqual(auth.updateCalls, 2)
        XCTAssertFalse(viewModel.hasUnsavedChanges)
    }

    func testUploadedStageIsReusedWhenProfileCommitFailsThenRetries() async {
        viewModel.stagePhotoData(Data("staged-once".utf8))
        auth.failNextUpdate = true
        viewModel.requestSaveConfirmation()

        let failedResult = await viewModel.confirmAndSave()
        XCTAssertEqual(failedResult, .failed)
        XCTAssertEqual(media.saveCalls, 1)
        XCTAssertTrue(viewModel.hasUnsavedChanges)

        viewModel.requestSaveConfirmation()
        let retryResult = await viewModel.confirmAndSave()
        XCTAssertEqual(retryResult, .succeeded)
        XCTAssertEqual(media.saveCalls, 1, "a staged upload is not duplicated on retry")
        XCTAssertFalse(viewModel.hasUnsavedChanges)
    }

    func testChangeIntroducedAfterConfirmationRemainsDraftAfterSave() async {
        viewModel.bio = "Confirmed bio"
        viewModel.requestSaveConfirmation()

        // Simulates a late picker callback or another local state update while
        // the native confirmation is visible.
        viewModel.bio = "Newer unconfirmed bio"
        viewModel.stagePhotoData(Data("late-photo".utf8))

        let result = await viewModel.confirmAndSave()
        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(auth.lastBio, "Confirmed bio")
        XCTAssertEqual(auth.lastPhotoPaths?.count, 2)
        XCTAssertEqual(media.saveCalls, 0)
        XCTAssertEqual(viewModel.bio, "Newer unconfirmed bio")
        XCTAssertEqual(viewModel.draftPhotos.count, 3)
        XCTAssertTrue(viewModel.hasUnsavedChanges)
    }

    func testRepeatedRequestsCannotStackConfirmationsOrSaves() async {
        viewModel.bio = "Only once"
        viewModel.requestSaveConfirmation()
        viewModel.requestSaveConfirmation()
        XCTAssertTrue(viewModel.isSaveConfirmationPresented)

        async let first = viewModel.confirmAndSave()
        async let second = viewModel.confirmAndSave()
        _ = await (first, second)

        XCTAssertEqual(auth.updateCalls, 1)
        XCTAssertFalse(viewModel.hasUnsavedChanges)
    }

    func testRouterBlocksBeforeMutationAndNeverReplaysDestination() {
        let router = AppRouter()
        XCTAssertTrue(router.selectTab(.profile))
        var allowNavigation = false
        var guardChecks = 0
        let guardID = UUID()
        router.installProfileNavigationGuard(id: guardID) {
            guardChecks += 1
            return allowNavigation
        }

        XCTAssertFalse(router.navigateToHuddles(route: .joinHuddle))
        XCTAssertEqual(router.selectedTab, .profile)
        XCTAssertTrue(router.huddlesPath.isEmpty, "the destination was never rendered")
        XCTAssertEqual(guardChecks, 1)

        // Resolving the warning cannot replay anything because the router did
        // not retain the destination.
        allowNavigation = true
        XCTAssertEqual(router.selectedTab, .profile)
        XCTAssertTrue(router.huddlesPath.isEmpty)

        XCTAssertTrue(router.navigateToHuddles(route: .joinHuddle))
        XCTAssertEqual(router.selectedTab, .huddles)
        XCTAssertEqual(router.huddlesPath, [.joinHuddle])
    }

    func testRepeatedNavigationAttemptsCannotStackOrBypassWarning() {
        let router = AppRouter()
        XCTAssertTrue(router.selectTab(.profile))
        let guardID = UUID()
        router.installProfileNavigationGuard(id: guardID) { [weak viewModel] in
            viewModel?.requestNavigation() ?? true
        }
        viewModel.bio = "Dirty"

        XCTAssertFalse(router.selectTab(.huddles))
        XCTAssertFalse(router.selectTab(.huddles))
        XCTAssertFalse(router.navigateToHuddles(route: .joinHuddle))
        XCTAssertEqual(router.selectedTab, .profile)
        XCTAssertTrue(router.huddlesPath.isEmpty)
        XCTAssertTrue(viewModel.isUnsavedChangesWarningPresented)

        viewModel.keepEditing()
        XCTAssertEqual(router.selectedTab, .profile)
        XCTAssertTrue(viewModel.hasUnsavedChanges)
        XCTAssertTrue(router.huddlesPath.isEmpty)
    }

    // MARK: Ending the session (QA-10)

    func testSignOutLeavesNothingOfTheAccountForTheNextPerson() async {
        deps.session.pendingInviteCode = "CREW42"
        deps.session.blockedUserIDs = [UUID()]

        await viewModel.signOut()

        XCTAssertNil(deps.session.currentUser)
        XCTAssertNil(deps.session.pendingInviteCode, "an invite parked by this account must not carry over")
        XCTAssertTrue(deps.session.blockedUserIDs.isEmpty)
        XCTAssertEqual(auth.removeLocalDataCalls, 1, "synced rows and cached photos are forgotten")
    }

    func testDeletingTheAccountAlsoForgetsLocalData() async {
        deps.session.pendingInviteCode = "CREW42"
        let deleted = await viewModel.deleteAccount()
        XCTAssertTrue(deleted)
        XCTAssertNil(deps.session.currentUser)
        XCTAssertNil(deps.session.pendingInviteCode)
        XCTAssertEqual(auth.removeLocalDataCalls, 1)
    }
}

@MainActor
private final class ProfileAuthSpy: AuthServiceProtocol {
    enum TestError: LocalizedError {
        case updateFailed
        var errorDescription: String? { "The profile couldn't be saved." }
    }

    private(set) var updateCalls = 0
    private(set) var lastAvatarColorHex: String?
    private(set) var lastBio: String?
    private(set) var lastPhotoPaths: [String]?
    var failNextUpdate = false

    func currentState() async throws -> AuthSessionState { .signedOut }
    func requestCode(to destination: OTPDestination) async throws {}
    func codeLength(for destination: OTPDestination) -> Int { 6 }
    func verifyCode(_ code: String, for destination: OTPDestination) async throws -> AuthSessionState {
        .signedOut
    }
    func signInWithApple(
        idToken: String,
        nonce: String,
        suggestedName: String?
    ) async throws -> AuthSessionState {
        .signedOut
    }
    func completeProfile(displayName: String, avatarColorHex: String) async throws -> User {
        throw TestError.updateFailed
    }

    func updateProfile(
        user: User,
        displayName: String,
        avatarColorHex: String,
        bio: String?,
        photoPaths: [String]
    ) async throws {
        updateCalls += 1
        if failNextUpdate {
            failNextUpdate = false
            throw TestError.updateFailed
        }
        lastAvatarColorHex = avatarColorHex
        lastBio = bio
        lastPhotoPaths = photoPaths
        user.displayName = displayName
        user.avatarColorHex = avatarColorHex
        user.bio = bio
        user.profilePhotoPaths = photoPaths
    }

    func signOut() async throws {}
    func deleteAccount() async throws {}

    private(set) var removeLocalDataCalls = 0
    func removeLocalData() throws { removeLocalDataCalls += 1 }
}

private final class ProfileMediaSpy: MediaServiceProtocol {
    private(set) var saveCalls = 0

    func saveImageData(_ data: Data, preferredName: String?) async throws -> String {
        saveCalls += 1
        return "Media/\(preferredName ?? "staged-\(saveCalls).jpg")"
    }

    func imageURL(for relativePath: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(relativePath)")
    }

    func loadImageData(at relativePath: String) async -> Data? { nil }
    func deleteImage(at relativePath: String) {}

    func saveDepositPhoto(_ data: Data, preferredName: String, huddleID: UUID) async throws -> StoredDepositPhoto {
        StoredDepositPhoto(path: try await saveImageData(data, preferredName: preferredName), wrappedPhotoKey: nil)
    }

    func loadDepositPhoto(at relativePath: String, huddleID: UUID, wrappedPhotoKey: String?) async -> Data? { nil }
}

import Foundation
import UIKit
import XCTest

@testable import HuddlePal

/// The deposit sheet's posting step (QA-14).
@MainActor
final class ComposeTests: XCTestCase {
    private var deps: AppDependencies!
    private var media: CountingMediaService!

    override func setUp() async throws {
        try await super.setUp()
        let base = AppDependencies.makeMock(inMemory: true)
        try await base.seeder.regenerate()
        guard case .signedIn(let user) = try await base.auth.currentState() else {
            throw XCTSkip("expected the seeded user to be signed in")
        }
        base.session.currentUser = user
        media = CountingMediaService()
        deps = AppDependencies(
            modelContainer: base.modelContainer, engine: base.engine, dateProvider: base.dateProvider,
            session: base.session, debug: base.debug, auth: base.auth, huddleService: base.huddleService,
            depositService: base.depositService, mediaService: media, moderationService: base.moderationService,
            seeder: base.seeder, reminders: base.reminders
        )
    }

    private func crew() async throws -> Huddle {
        let huddles = try await deps.huddleService.huddles(for: deps.session.currentUser!)
        return try XCTUnwrap(huddles.first { $0.inviteCode == "CREW42" })
    }

    private func capturedPhoto() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
    }

    func testADoubleTapPostsOnce() async throws {
        let huddle = try await crew()
        let viewModel = ComposeViewModel(deps: deps, huddle: huddle)
        viewModel.setCapturedImage(capturedPhoto())
        viewModel.continueToConfirm()

        async let first = viewModel.confirmAndPost()
        async let second = viewModel.confirmAndPost()
        let results = await [first, second]

        XCTAssertEqual(results.filter { $0 }.count, 1, "exactly one post succeeds")
        XCTAssertEqual(media.depositUploads, 1, "the second tap must not upload a second photo")
        XCTAssertNil(viewModel.errorMessage, "no spurious 'already posted' error")
        let today = deps.engine.todayKey(now: deps.dateProvider.now)
        let mine = huddle.deposits.filter { $0.author?.id == deps.session.currentUser?.id && $0.dayKey == today }
        XCTAssertEqual(mine.count, 1)
    }
}

/// The real local media store, counting deposit uploads.
private final class CountingMediaService: MediaServiceProtocol {
    private let inner = MockMediaService()
    private(set) var depositUploads = 0

    func saveImageData(_ data: Data, preferredName: String?) async throws -> String {
        try await inner.saveImageData(data, preferredName: preferredName)
    }
    func imageURL(for relativePath: String) -> URL { inner.imageURL(for: relativePath) }
    func loadImageData(at relativePath: String) async -> Data? { await inner.loadImageData(at: relativePath) }
    func deleteImage(at relativePath: String) { inner.deleteImage(at: relativePath) }
    func saveDepositPhoto(_ data: Data, preferredName: String, huddleID: UUID) async throws -> StoredDepositPhoto {
        depositUploads += 1
        // Upload latency, so a second tap lands while the first is in flight.
        try await Task.sleep(for: .milliseconds(50))
        return try await inner.saveDepositPhoto(data, preferredName: preferredName, huddleID: huddleID)
    }
    func loadDepositPhoto(at relativePath: String, huddleID: UUID, wrappedPhotoKey: String?) async -> Data? {
        await inner.loadDepositPhoto(at: relativePath, huddleID: huddleID, wrappedPhotoKey: wrappedPhotoKey)
    }
}

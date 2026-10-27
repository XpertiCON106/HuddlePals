import SwiftData
import XCTest

@testable import HuddlePal

/// A store written before videos and keeper_since (`Fixtures/store-e963ad4.store`:
/// the seeded world as the e963ad4 build saved it) opens with today's models,
/// keeps every row, and reads as it should. If a model change stops migrating
/// on its own, `AppDependencies.makeContainer` would quietly fall back to an
/// empty in-memory store; this fails first.
@MainActor
final class StoreMigrationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("StoreMigration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    /// A copy of the fixture, so each test migrates it from scratch.
    private func oldStore() throws -> URL {
        let bundle = Bundle(for: Self.self)
        let fixture = try XCTUnwrap(
            bundle.url(forResource: "store-e963ad4", withExtension: "store")
                ?? bundle.url(forResource: "store-e963ad4", withExtension: "store", subdirectory: "Fixtures"),
            "the fixture is in the test bundle"
        )
        let url = directory.appendingPathComponent("default.store")
        try FileManager.default.copyItem(at: fixture, to: url)
        return url
    }

    private func open(_ url: URL) throws -> ModelContainer {
        let schema = Schema(HuddleSchema.models)
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
    }

    func testTheOldStoreOpensWithEveryRow() throws {
        let container = try open(try oldStore())
        let context = container.mainContext
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Huddle>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Membership>()), 6)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Deposit>()), 137)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Reaction>()), 3)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Comment>()), 1)
    }

    func testEveryOldDepositIsAPhotoAndEveryOldKeeperKeptSinceJoining() throws {
        // Held: a ModelContext traps once its container is deallocated.
        let container = try open(try oldStore())
        let context = container.mainContext
        let deposits = try context.fetch(FetchDescriptor<Deposit>())
        XCTAssertTrue(deposits.allSatisfy { $0.mediaType == .photo && $0.mediaTypeRaw == "photo" })
        XCTAssertTrue(deposits.allSatisfy { $0.localVideoPath == nil && $0.durationMs == nil && !$0.isVideo })
        XCTAssertTrue(deposits.allSatisfy { $0.huddle != nil }, "relationships survive")

        let memberships = try context.fetch(FetchDescriptor<Membership>())
        XCTAssertTrue(memberships.allSatisfy { $0.keeperSince == nil })
        XCTAssertTrue(memberships.allSatisfy { $0.keptSince == $0.joinedAt })
        XCTAssertEqual(memberships.filter { $0.role == .keeper }.count, 2)
    }

    func testTheMigratedStoreTakesTheNewFieldsAndKeepsThem() throws {
        let url = try oldStore()
        let id: UUID
        let keeperID: UUID
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        do {
            let container = try open(url)
            let context = container.mainContext
            let deposit = try XCTUnwrap(try context.fetch(FetchDescriptor<Deposit>()).first)
            id = deposit.id
            deposit.mediaType = .video
            deposit.localVideoPath = deposit.localImagePath.replacingOccurrences(of: ".jpg", with: ".mp4")
            deposit.durationMs = 5_800
            let keeper = try XCTUnwrap(try context.fetch(FetchDescriptor<Membership>()).first { $0.role == .keeper })
            keeperID = keeper.id
            keeper.keeperSince = since
            try context.save()
        }

        let container = try open(url)
        let reopened = container.mainContext
        let saved = try XCTUnwrap(try reopened.fetch(FetchDescriptor<Deposit>(predicate: #Predicate { $0.id == id })).first)
        XCTAssertEqual(saved.mediaType, .video)
        XCTAssertTrue(saved.isVideo)
        XCTAssertEqual(saved.durationMs, 5_800)
        let savedKeeper = try XCTUnwrap(try reopened.fetch(FetchDescriptor<Membership>(predicate: #Predicate { $0.id == keeperID })).first)
        XCTAssertEqual(savedKeeper.keeperSince, since)
    }

    func testAMediaTypeThisBuildDoesntKnowReadsAsAPhoto() throws {
        let container = try open(try oldStore())
        let context = container.mainContext
        let deposit = try XCTUnwrap(try context.fetch(FetchDescriptor<Deposit>()).first)
        deposit.mediaTypeRaw = "hologram"
        XCTAssertEqual(deposit.mediaType, .photo)
        XCTAssertFalse(deposit.isVideo)
    }
}

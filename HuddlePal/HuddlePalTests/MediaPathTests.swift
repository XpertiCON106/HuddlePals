import Foundation
import XCTest

@testable import HuddlePal

/// QA-22: image paths come from rows other members wrote, so the cache never
/// reads, writes or deletes outside Documents/Media.
final class MediaPathTests: XCTestCase {
    private let media = MockMediaService()
    private var outside: URL!

    override func setUpWithError() throws {
        // A file next to the cache, standing in for the app's own data.
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        outside = documents.appendingPathComponent("qa22-outside-media.txt")
        try Data("private".utf8).write(to: outside)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: outside)
    }

    func testPathsThatEscapeTheCacheAreRefused() async throws {
        let escaping = "Media/../\(outside.lastPathComponent)"
        let read = await media.loadImageData(at: escaping)
        XCTAssertNil(read, "a crafted path must not read the app's own files")
        media.deleteImage(at: escaping)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "…or delete them")
        do {
            _ = try await media.saveImageData(Data("x".utf8), preferredName: "../\(outside.lastPathComponent)")
            XCTFail("…or overwrite them")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: outside), Data("private".utf8))
    }

    func testOrdinaryCachePathsStillWork() async throws {
        let path = try await media.saveImageData(Data("jpeg".utf8), preferredName: "\(UUID().uuidString)/\(UUID().uuidString).jpg")
        let read = await media.loadImageData(at: path)
        XCTAssertEqual(read, Data("jpeg".utf8))
        media.deleteImage(at: path)
        let gone = await media.loadImageData(at: path)
        XCTAssertNil(gone)
    }

    func testSafePathRules() {
        XCTAssertTrue(MockMediaService.isSafe("Media/avatars/abc/def.jpg"))
        XCTAssertFalse(MockMediaService.isSafe("/etc/passwd"))
        XCTAssertFalse(MockMediaService.isSafe("Media/../default.store"))
        XCTAssertFalse(MockMediaService.isSafe(""))
    }
}

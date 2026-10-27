import AVFoundation
import SwiftData
import UIKit
import XCTest

@testable import HuddlePal

/// The seeded offline world as Plus needs it: 45 days of history, so the
/// free plan's locked days (past 30) show at once, and one video drop with a
/// poster and a playable clip.
@MainActor
final class SeedWorldTests: XCTestCase {
    private var deps: AppDependencies!

    override func setUp() async throws {
        try await super.setUp()
        deps = AppDependencies.makeMock(inMemory: true)
        try await deps.seeder.regenerate()
    }

    private func crew() throws -> Huddle {
        let huddles = try deps.modelContainer.mainContext.fetch(FetchDescriptor<Huddle>())
        return try XCTUnwrap(huddles.first { $0.inviteCode == SeedDataService.crewInviteCode })
    }

    func testTheCrewGoesBack45DaysPastTheFreeArchiveWindow() throws {
        let engine = deps.engine
        let today = engine.todayKey(now: deps.dateProvider.now)
        let days = Set(try crew().deposits.map(\.dayKey))
        XCTAssertEqual(days.min(), engine.dayKey(byAdding: -45, to: today))
        let locked = days.filter { !engine.isDayUnlockedInArchive(dayKey: $0, todayDayKey: today, isPremium: false) }
        XCTAssertEqual(locked.count, 16, "days -45…-30 are locked on the free plan")
        XCTAssertTrue(days.allSatisfy { engine.isDayUnlockedInArchive(dayKey: $0, todayDayKey: today, isPremium: true) })
    }

    func testTheCrewIsFourMembersWhoJoinedBeforeItsHistory() throws {
        let crew = try crew()
        XCTAssertEqual(crew.memberships.count, HuddleLimits.freeMembers, "full on the free plan: a ready-made case")
        let firstDay = try XCTUnwrap(crew.deposits.map(\.dayKey).min())
        let joinDays = crew.memberJoinDayKeys(using: deps.engine).values
        XCTAssertTrue(joinDays.allSatisfy { $0 < firstDay })
        XCTAssertNotNil(crew.memberships.first { $0.role == .keeper }?.keeperSince)
    }

    func testTheSeededStreakIsStill6() async throws {
        let crew = try crew()
        try await deps.huddleService.recomputeStreak(for: crew, now: deps.dateProvider.now)
        XCTAssertEqual(crew.streakCount, 6)
    }

    func testMayasPostYesterdayIsAVideoWithAPosterAndAPlayableClip() async throws {
        let yesterday = try XCTUnwrap(deps.engine.yesterdayKey(now: deps.dateProvider.now))
        let videos = try crew().deposits.filter(\.isVideo)
        XCTAssertEqual(videos.count, 1)
        let video = try XCTUnwrap(videos.first)
        XCTAssertEqual(video.author?.displayName, "Maya")
        XCTAssertEqual(video.dayKey, yesterday)
        XCTAssertEqual(video.durationMs, 2000)
        let clipPath = try XCTUnwrap(video.localVideoPath)
        XCTAssertEqual(clipPath, video.localImagePath.replacingOccurrences(of: ".jpg", with: ".mp4"), "the clip sits next to its poster")

        let posterData = await deps.mediaService.loadImageData(at: video.localImagePath)
        let poster = try XCTUnwrap(posterData)
        XCTAssertNotNil(UIImage(data: poster), "the poster is a JPEG anything can show")
        let clipData = await deps.mediaService.loadImageData(at: clipPath)
        let clip = try XCTUnwrap(clipData)
        XCTAssertEqual(clip.dropFirst(4).prefix(4), Data("ftyp".utf8), "an MP4")

        let asset = AVURLAsset(url: deps.mediaService.imageURL(for: clipPath))
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 2, accuracy: 0.1)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
    }

    func testTheGeneratorMakesSmallDeterministicClips() async throws {
        let clip = try await PlaceholderVideoGenerator.clip(seed: 42, duration: 1)
        XCTAssertEqual(clip.durationMs, 1000)
        XCTAssertLessThan(clip.mp4.count, HuddleLimits.maxVideoBytes)
        XCTAssertEqual(clip.poster, PlaceholderImageGenerator.jpegData(seed: 42, size: CGSize(width: 360, height: 640)), "9:16, like a recording")
    }
}

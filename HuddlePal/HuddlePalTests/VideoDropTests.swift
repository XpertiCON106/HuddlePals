import AVFoundation
import CryptoKit
import UIKit
import XCTest

@testable import HuddlePal

/// Video drops on the device: one key for poster and clip, the recording's
/// short life on disk, the writer's settings and 6-second cutoff, playback
/// straight from memory, and Compose posting a video (or a photo instead
/// once Plus has ended). The live upload is in InviteKeyTests.
@MainActor
final class VideoDropTests: XCTestCase {
    // MARK: One key for both halves

    func testAVideoIsSealedWithOneKeyForItsPosterAndItsClip() throws {
        let huddleKey = PhotoCrypto.makeHuddleKey()
        let poster = PlaceholderImageGenerator.jpegData(seed: 1)
        let clip = Data("not really an mp4, but bytes all the same".utf8)
        let sealed = try PhotoCrypto.sealVideo(poster: poster, clip: clip, huddleKey: huddleKey)

        XCTAssertEqual(try PhotoCrypto.openPhoto(sealed.posterCiphertext, wrappedPhotoKey: sealed.wrappedPhotoKey, huddleKey: huddleKey), poster)
        XCTAssertEqual(try PhotoCrypto.openPhoto(sealed.clipCiphertext, wrappedPhotoKey: sealed.wrappedPhotoKey, huddleKey: huddleKey), clip)
        XCTAssertNotEqual(sealed.posterCiphertext.prefix(12), sealed.clipCiphertext.prefix(12), "each has its own nonce")
        XCTAssertNotNil(sealed.wrappedPhotoKey.range(of: "^[A-Za-z0-9+/]{80}$", options: .regularExpression), "the deposits column's shape")

        // A report discloses one key, and it opens both halves, nothing else.
        let disclosed = try PhotoCrypto.disclosedPhotoKey(sealed.wrappedPhotoKey, huddleKey: huddleKey)
        let photoKey = SymmetricKey(data: try XCTUnwrap(Data(base64Encoded: disclosed)))
        XCTAssertEqual(try PhotoCrypto.openPhoto(sealed.clipCiphertext, photoKey: photoKey), clip)
        XCTAssertEqual(try PhotoCrypto.openPhoto(sealed.posterCiphertext, photoKey: photoKey), poster)
        let other = try PhotoCrypto.sealVideo(poster: poster, clip: clip, huddleKey: huddleKey)
        XCTAssertThrowsError(try PhotoCrypto.openPhoto(other.clipCiphertext, photoKey: photoKey), "another video's key is its own")
    }

    // MARK: The recording's life on disk

    func testARecordingBecomesAClipInMemoryAndLeavesNothingBehind() async throws {
        let url = try CaptureFiles.newClipURL()
        let generated = try await PlaceholderVideoGenerator.clip(seed: 21)
        try generated.mp4.write(to: url)

        let prepared = try await ClipPreparer.prepare(fileAt: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the plaintext file is gone")
        XCTAssertEqual(prepared.clip, generated.mp4)
        XCTAssertEqual(Double(prepared.durationMs), 2000, accuracy: 100)
        XCTAssertNotNil(UIImage(data: prepared.poster), "a JPEG poster from the first frame")
        XCTAssertTrue(prepared.poster.starts(with: [0xFF, 0xD8, 0xFF]))
    }

    func testAClipTooLargeIsRefusedAndStillDeleted() async throws {
        let url = try CaptureFiles.newClipURL()
        try (try await PlaceholderVideoGenerator.clip(seed: 22)).mp4.write(to: url)
        do {
            _ = try await ClipPreparer.prepare(fileAt: url, maxBytes: 1_000)
            XCTFail("over the cap")
        } catch ClipPreparer.ClipError.tooLarge {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testAnUnreadableRecordingIsRefusedAndDeleted() async throws {
        let url = try CaptureFiles.newClipURL()
        try Data("half a file".utf8).write(to: url)
        do {
            _ = try await ClipPreparer.prepare(fileAt: url)
            XCTFail("not a video")
        } catch ClipPreparer.ClipError.unreadable {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRecordingsLiveInOneProtectedFolderThatTheLaunchSweeps() throws {
        let url = try CaptureFiles.newClipURL()
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, CaptureFiles.directory.standardizedFileURL)
        try Data("left behind by a kill mid-recording".utf8).write(to: url)
        let protection = try FileManager.default.attributesOfItem(atPath: CaptureFiles.directory.path)[.protectionKey] as? FileProtectionType
        if let protection { XCTAssertEqual(protection, .complete) }
        CaptureFiles.sweep()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: The writer

    func testTheClipEndsAtSixSecondsByTheFramesTimestamps() {
        XCTAssertFalse(ClipWriter.isPastEnd(CMTime(seconds: 5.999, preferredTimescale: 600)))
        XCTAssertTrue(ClipWriter.isPastEnd(CMTime(seconds: 6, preferredTimescale: 600)))
        XCTAssertTrue(ClipWriter.isPastEnd(CMTime(seconds: 6.2, preferredTimescale: 600)))
        XCTAssertEqual(ClipWriter.maxDuration.seconds, HuddleLimits.maxVideoDuration)
    }

    func testTheWriterRecordsSmallH264AndMonoAAC() throws {
        let video = ClipWriter.videoSettings(width: 720, height: 1280)
        XCTAssertEqual(video[AVVideoCodecKey] as? AVVideoCodecType, .h264)
        XCTAssertEqual(video[AVVideoWidthKey] as? Int, 720)
        XCTAssertEqual(video[AVVideoHeightKey] as? Int, 1280)
        let compression = try XCTUnwrap(video[AVVideoCompressionPropertiesKey] as? [String: Any])
        XCTAssertEqual(compression[AVVideoAverageBitRateKey] as? Int, 2_000_000)
        // 6 seconds at that rate, with sound, stays well under the cap.
        let bytes = 6 * (ClipWriter.videoBitRate + ClipWriter.audioBitRate) / 8
        XCTAssertLessThan(bytes, HuddleLimits.maxVideoBytes / 2)
        XCTAssertEqual(ClipWriter.audioSettings[AVFormatIDKey] as? AudioFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(ClipWriter.audioSettings[AVNumberOfChannelsKey] as? Int, 1)
    }

    // MARK: Playback from memory

    func testAClipPlaysFromMemoryWithItsLengthAndPictures() async throws {
        let generated = try await PlaceholderVideoGenerator.clip(seed: 23)
        let loader = InMemoryClipLoader(data: generated.mp4)
        let asset = loader.makeAsset()
        XCTAssertEqual(asset.url.scheme, InMemoryClipLoader.scheme, "no file: a URL only the loader answers")
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 2, accuracy: 0.1)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let frame = try await AVAssetImageGenerator(asset: asset).image(at: .zero).image
        XCTAssertGreaterThan(frame.width, 0, "frames decode from the bytes in memory")
        withExtendedLifetime(loader) {}
    }

    /// A clip loops; when something else stops it (the camera giving the
    /// audio back after a recording, a call) it starts again, and only a
    /// pause of its own keeps it paused.
    func testAClipLoopsAndKeepsPlayingUntilItsPaused() async throws {
        let generated = try await PlaceholderVideoGenerator.clip(seed: 5, duration: 1)
        let looping = LoopingClipPlayer(clip: generated.mp4)
        looping.isMuted = true
        looping.play()
        func wait(_ seconds: Double) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        try await wait(2.5)
        XCTAssertGreaterThanOrEqual(looping.loopCount, 1, "it starts over")
        XCTAssertEqual(looping.player.timeControlStatus, .playing)

        looping.player.pause() // as an audio session handover does
        try await wait(1.2)
        XCTAssertEqual(looping.player.timeControlStatus, .playing, "back by itself")

        looping.pause()
        try await wait(1.2)
        XCTAssertEqual(looping.player.timeControlStatus, .paused, "a pause of its own holds")
    }

    /// AVFoundation asks for ranges (2 bytes first, then pieces, sometimes
    /// "to the end"), and may come back for the rest of one it was partly sent.
    func testTheLoaderServesExactlyTheBytesAskedFor() {
        func range(at current: Int64, from requested: Int64? = nil, length: Int = 0, toEnd: Bool = false) -> Range<Int>? {
            InMemoryClipLoader.byteRange(
                currentOffset: current, requestedOffset: requested ?? current, requestedLength: length,
                toEnd: toEnd, clipLength: 1000
            )
        }
        XCTAssertEqual(range(at: 0, length: 2), 0..<2, "the first probe")
        XCTAssertEqual(range(at: 100, length: 50), 100..<150)
        XCTAssertEqual(range(at: 120, from: 100, length: 50), 120..<150, "the rest of a request already partly answered")
        XCTAssertEqual(range(at: 900, length: 500), 900..<1000, "cut off at the end")
        XCTAssertEqual(range(at: 400, toEnd: true), 400..<1000)
        XCTAssertEqual(range(at: 1000, length: 10), 1000..<1000, "at the very end: nothing, not an error")
        XCTAssertNil(range(at: 1001, length: 10), "past the end")
        XCTAssertNil(range(at: -1, length: 10))
    }

    func testDecryptedClipsStayInMemoryUntilSignOut() {
        let cache = DecryptedClipCache()
        cache.store(Data([1, 2, 3]), for: "a")
        XCTAssertEqual(cache.clip(for: "a"), Data([1, 2, 3]))
        cache.removeAll()
        XCTAssertNil(cache.clip(for: "a"))
    }

    func testABadgeSaysHowLong() {
        XCTAssertEqual(DepositVideoPlayer.seconds(6000), 6)
        XCTAssertEqual(DepositVideoPlayer.seconds(5600), 6)
        XCTAssertEqual(DepositVideoPlayer.seconds(300), 1, "never 0 seconds")
    }
}

/// Compose posting a video in the offline world: with Plus it goes in as a
/// video; once Plus has ended nothing is posted, the clip is kept, and a photo
/// can go up instead.
@MainActor
final class ComposeVideoTests: XCTestCase {
    private var deps: AppDependencies!
    private var plans: MockPlanLedger!
    private var you: User!
    private var crew: Huddle!

    override func setUp() async throws {
        try await super.setUp()
        // Compose opens on the medium posted last; every test starts on Photo.
        UserDefaults.standard.removeObject(forKey: ComposeViewModel.lastMediumKey)
        deps = AppDependencies.makeMock(inMemory: true)
        try await deps.seeder.regenerate()
        plans = try XCTUnwrap(deps.mockPlans)
        guard case .signedIn(let user) = try await deps.auth.currentState() else {
            throw XCTSkip("expected the seeded user to be signed in")
        }
        you = user
        deps.session.currentUser = user
        let huddles = try await deps.huddleService.huddles(for: user)
        crew = try XCTUnwrap(huddles.first { $0.inviteCode == SeedDataService.crewInviteCode })
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: ComposeViewModel.lastMediumKey)
        try await super.tearDown()
    }

    private func compose() -> ComposeViewModel {
        ComposeViewModel(deps: deps, huddle: crew)
    }

    private func todaysDeposit() -> Deposit? {
        let today = deps.engine.todayKey(now: deps.dateProvider.now)
        return crew.deposits.first { $0.author?.id == you.id && $0.dayKey == today }
    }

    func testVideoIsOfferedOnlyWithPlus() {
        XCTAssertFalse(compose().canRecordVideo)
        plans.setPlus(true, for: you.id)
        XCTAssertTrue(compose().canRecordVideo)
    }

    func testAVideoGoesInAsAVideoWithItsPosterAndClip() async throws {
        plans.setPlus(true, for: you.id)
        let viewModel = compose()
        viewModel.choose(.video)
        viewModel.setCapturedVideo(try await ClipPreparer.placeholder(seed: 31))
        XCTAssertTrue(viewModel.canContinue)
        viewModel.continueToConfirm()
        let posted = await viewModel.confirmAndPost()
        XCTAssertTrue(posted)

        let deposit = try XCTUnwrap(todaysDeposit())
        XCTAssertTrue(deposit.isVideo)
        XCTAssertEqual(deposit.durationMs, 2000)
        let clipPath = try XCTUnwrap(deposit.localVideoPath)
        XCTAssertEqual(clipPath, deposit.localImagePath.replacingOccurrences(of: ".jpg", with: ".mp4"))
        let clipData = await deps.mediaService.loadImageData(at: clipPath)
        let clip = try XCTUnwrap(clipData)
        XCTAssertEqual(clip.dropFirst(4).prefix(4), Data("ftyp".utf8))
    }

    func testAVideoAfterPlusEndedPostsNothingKeepsTheClipAndOffersAPhoto() async throws {
        plans.setPlus(true, for: you.id)
        let viewModel = compose()
        viewModel.choose(.video)
        let clip = try await ClipPreparer.placeholder(seed: 32)
        viewModel.setCapturedVideo(clip)
        viewModel.continueToConfirm()
        plans.setPlus(until: .now.addingTimeInterval(-1), for: you.id) // ran out meanwhile

        let posted = await viewModel.confirmAndPost()
        XCTAssertFalse(posted)
        XCTAssertTrue(viewModel.videoNeedsPlus)
        XCTAssertEqual(viewModel.errorMessage, DepositError.videoNeedsPlus.errorDescription)
        XCTAssertEqual(viewModel.clip?.id, clip.id, "the recording is kept")
        XCTAssertNil(todaysDeposit(), "nothing posted")

        viewModel.takePhotoInstead()
        XCTAssertEqual(viewModel.medium, .photo)
        XCTAssertEqual(viewModel.stage, .pick)
        XCTAssertNil(viewModel.clip)
        viewModel.setCapturedImage(UIGraphicsImageRenderer(size: CGSize(width: 30, height: 40)).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 30, height: 40))
        })
        viewModel.continueToConfirm()
        let photoPosted = await viewModel.confirmAndPost()
        XCTAssertTrue(photoPosted)
        XCTAssertEqual(todaysDeposit()?.mediaType, .photo)
    }

    func testSwitchingBetweenPhotoAndVideoDropsWhatWasCaptured() async throws {
        plans.setPlus(true, for: you.id)
        let viewModel = compose()
        viewModel.setCapturedImage(UIGraphicsImageRenderer(size: CGSize(width: 30, height: 40)).image { _ in })
        viewModel.choose(.video)
        XCTAssertFalse(viewModel.canContinue, "a photo doesn't come along into video")
        viewModel.setCapturedVideo(try await ClipPreparer.placeholder(seed: 33))
        XCTAssertTrue(viewModel.canContinue)
        viewModel.choose(.photo)
        XCTAssertNil(viewModel.clip)
        XCTAssertNil(viewModel.previewImage)
    }

    func testTheMockServerRefusesAVideoWithoutPlusLikeTheInsertPolicy() async throws {
        let today = deps.engine.todayKey(now: deps.dateProvider.now)
        do {
            try await deps.depositService.createDeposit(
                in: crew, author: you, localImagePath: "Media/x.jpg", wrappedPhotoKey: nil, caption: nil, dayKey: today,
                video: DepositVideo(localVideoPath: "Media/x.mp4", durationMs: 3000)
            )
            XCTFail("a video takes Plus")
        } catch DepositError.videoNeedsPlus {}
        XCTAssertNil(todaysDeposit())
    }
}

import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class ComposeViewModel {
    /// Once-and-permanent flow: capture → confirm ("This is permanent —
    /// post it?") → posted. No retakes after confirmation.
    enum Stage: Equatable {
        case pick
        case confirm
    }

    private let deps: AppDependencies
    let huddle: Huddle

    /// Today for the normal flow; yesterday when launched as a backfill
    /// (or recovery) from the archive or recovery banner.
    let targetDayKey: String
    let isBackfill: Bool

    /// What the day's one deposit is: a photo, or with Plus a video of up to
    /// 6 seconds. Never both.
    enum Medium: Equatable {
        case photo
        case video
    }

    private(set) var stage: Stage = .pick
    private(set) var medium: Medium = .photo

    private(set) var imageData: Data?
    /// The recorded video, in memory only, kept until it's posted or the
    /// person takes a photo instead.
    private(set) var clip: PreparedClip?
    /// The poster of a video, or the photo.
    private(set) var previewImage: UIImage?
    var caption = ""
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    /// Plus ended between recording and posting: nothing was posted, the
    /// clip is still here, and a photo for the day is offered instead.
    private(set) var videoNeedsPlus = false

    var canContinue: Bool { (imageData != nil || clip != nil) && !isSaving }
    /// Video drops come with HuddlePals Plus.
    var canRecordVideo: Bool { deps.plus.isPremium }

    init(deps: AppDependencies, huddle: Huddle, targetDayKey: String? = nil) {
        self.deps = deps
        self.huddle = huddle
        let today = deps.engine.todayKey(now: deps.dateProvider.now)
        self.targetDayKey = targetDayKey ?? today
        self.isBackfill = (targetDayKey ?? today) != today
    }

    /// Camera-only: the live capture handed back from `CameraPicker`. There
    /// is deliberately no path to import an existing photo into this flow.
    func setCapturedImage(_ image: UIImage) {
        errorMessage = nil
        // Downscale for upload; the preview keeps the full-res capture.
        guard let data = ImageDownscaler.jpegData(
            from: image,
            maxDimension: ImageDownscaler.depositMaxDimension
        ) else {
            errorMessage = "Couldn't process that photo. Try again."
            return
        }
        previewImage = image
        imageData = data
        clip = nil
        videoNeedsPlus = false
    }

    /// The recording handed back from the video camera. Camera-only too.
    func setCapturedVideo(_ clip: PreparedClip) {
        errorMessage = nil
        videoNeedsPlus = false
        self.clip = clip
        imageData = nil
        previewImage = clip.posterImage
    }

    /// Photo or video: switching drops what was captured for the other.
    func choose(_ medium: Medium) {
        guard medium != self.medium else { return }
        self.medium = medium
        imageData = nil
        clip = nil
        previewImage = nil
        errorMessage = nil
        videoNeedsPlus = false
    }

    /// After a video refused for want of Plus: back to the camera, for a photo.
    func takePhotoInstead() {
        choose(.photo)
        stage = .pick
    }

    /// Pick → the permanence gate.
    func continueToConfirm() {
        guard canContinue else { return }
        errorMessage = nil
        stage = .confirm
        Haptics.light()
    }

    /// Returns true on success so the sheet can dismiss into the reveal.
    /// Irreversible: once this succeeds the photo can never be deleted,
    /// edited, or replaced.
    func confirmAndPost() async -> Bool {
        // One post at a time: a second tap before the first finishes would
        // upload a second photo and then fail as "already posted today".
        guard !isSaving,
              imageData != nil || clip != nil,
              let user = deps.session.currentUser else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            if let clip {
                // The poster, then the clip, then the row: the server takes
                // a clip (and the row) only while Plus is on.
                let video = try await deps.mediaService.saveDepositVideo(
                    poster: clip.poster,
                    clip: clip.clip,
                    baseName: "\(huddle.id.uuidString)/\(UUID().uuidString)",
                    huddleID: huddle.id
                )
                try await deps.depositService.createDeposit(
                    in: huddle,
                    author: user,
                    localImagePath: video.posterPath,
                    wrappedPhotoKey: video.wrappedPhotoKey,
                    caption: caption,
                    dayKey: targetDayKey,
                    video: DepositVideo(localVideoPath: video.videoPath, durationMs: clip.durationMs)
                )
            } else if let imageData {
                let photo = try await deps.mediaService.saveDepositPhoto(
                    imageData,
                    preferredName: "\(huddle.id.uuidString)/\(UUID().uuidString).jpg",
                    huddleID: huddle.id
                )
                try await deps.depositService.createDeposit(
                    in: huddle,
                    author: user,
                    localImagePath: photo.path,
                    wrappedPhotoKey: photo.wrappedPhotoKey,
                    caption: caption,
                    dayKey: targetDayKey
                )
            }
            return true
        } catch DepositError.videoNeedsPlus {
            videoNeedsPlus = true
            errorMessage = DepositError.videoNeedsPlus.errorDescription
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

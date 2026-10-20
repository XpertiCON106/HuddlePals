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

    private(set) var stage: Stage = .pick

    private(set) var imageData: Data?
    private(set) var previewImage: UIImage?
    var caption = ""
    private(set) var isSaving = false
    private(set) var errorMessage: String?

    var canContinue: Bool { imageData != nil && !isSaving }

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
        guard let imageData,
              let user = deps.session.currentUser else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
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
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

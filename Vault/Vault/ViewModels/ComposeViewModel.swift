import Foundation
import Observation
import PhotosUI
import SwiftUI

@MainActor
@Observable
final class ComposeViewModel {
    /// Once-and-permanent flow: pick → confirm ("This is permanent —
    /// post it?") → posted. No retakes after confirmation.
    enum Stage: Equatable {
        case pick
        case confirm
    }

    private let deps: AppDependencies
    let vault: Vault

    /// Today for the normal flow; yesterday when launched as a backfill
    /// (or recovery) from the archive or recovery banner.
    let targetDayKey: String
    let isBackfill: Bool

    private(set) var stage: Stage = .pick

    var photoItem: PhotosPickerItem? {
        didSet { Task { await loadSelectedPhoto() } }
    }
    private(set) var imageData: Data?
    private(set) var previewImage: UIImage?
    var caption = ""
    private(set) var isSaving = false
    private(set) var errorMessage: String?

    var canContinue: Bool { imageData != nil && !isSaving }

    init(deps: AppDependencies, vault: Vault, targetDayKey: String? = nil) {
        self.deps = deps
        self.vault = vault
        let today = deps.engine.todayKey(now: deps.dateProvider.now)
        self.targetDayKey = targetDayKey ?? today
        self.isBackfill = (targetDayKey ?? today) != today
    }

    private func loadSelectedPhoto() async {
        errorMessage = nil
        guard let photoItem else { return }
        do {
            guard let data = try await photoItem.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                errorMessage = "Couldn't read that photo. Try another one."
                return
            }
            imageData = data
            previewImage = image
        } catch {
            errorMessage = "Couldn't load the photo: \(error.localizedDescription)"
        }
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
            let path = try await deps.mediaService.saveImageData(
                imageData,
                preferredName: "\(vault.id.uuidString)/\(UUID().uuidString).jpg"
            )
            try await deps.depositService.createDeposit(
                in: vault,
                author: user,
                localImagePath: path,
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

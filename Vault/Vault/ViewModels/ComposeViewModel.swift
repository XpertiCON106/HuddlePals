import Foundation
import Observation
import PhotosUI
import SwiftUI

@MainActor
@Observable
final class ComposeViewModel {
    private let deps: AppDependencies

    /// Today for the normal flow; yesterday when launched as a backfill
    /// from the archive.
    let targetDayKey: String
    let isBackfill: Bool

    var photoItem: PhotosPickerItem? {
        didSet { Task { await loadSelectedPhoto() } }
    }
    private(set) var imageData: Data?
    private(set) var previewImage: UIImage?
    var caption = ""
    private(set) var isSaving = false
    private(set) var errorMessage: String?

    var canDeposit: Bool { imageData != nil && !isSaving }

    init(deps: AppDependencies, targetDayKey: String? = nil) {
        self.deps = deps
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

    /// Returns true on success so the sheet can dismiss into the reveal.
    func deposit() async -> Bool {
        guard let imageData,
              let vault = deps.session.activeVault,
              let user = deps.session.currentUser else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            let path = try deps.mediaService.saveImageData(imageData, preferredName: nil)
            try await deps.depositService.createDeposit(
                in: vault,
                author: user,
                localImagePath: path,
                caption: caption,
                dayKey: targetDayKey
            )
            return true
        } catch {
            errorMessage = "Couldn't save the deposit: \(error.localizedDescription)"
            return false
        }
    }
}

import CryptoKit
import Foundation
import Observation
import PhotosUI
import SwiftUI

/// One photo in the profile editor's working draft. Existing photos keep
/// their stable backend path; newly picked photos are compared by a SHA-256
/// fingerprint of the downscaled JPEG bytes and remain in memory until a
/// confirmed save uploads them.
struct ProfilePhotoDraft: Identifiable, Equatable {
    enum Source: Equatable {
        case persisted(path: String)
        case staged(data: Data, fingerprint: String, uploadedPath: String?)
    }

    let id: UUID
    var source: Source

    init(id: UUID = UUID(), persistedPath: String) {
        self.id = id
        self.source = .persisted(path: persistedPath)
    }

    init(id: UUID = UUID(), stagedData: Data) {
        self.id = id
        self.source = .staged(
            data: stagedData,
            fingerprint: Self.fingerprint(for: stagedData),
            uploadedPath: nil
        )
    }

    var previewData: Data? {
        guard case .staged(let data, _, _) = source else { return nil }
        return data
    }

    var persistedPath: String? {
        guard case .persisted(let path) = source else { return nil }
        return path
    }

    var stagedUploadPath: String? {
        guard case .staged(_, _, let path) = source else { return nil }
        return path
    }

    /// Canonical comparison value. Upload bookkeeping is deliberately not
    /// included: uploading a staged asset does not make the profile saved.
    var canonicalReference: String {
        switch source {
        case .persisted(let path):
            return "persisted:\(path)"
        case .staged(_, let fingerprint, _):
            return "staged:\(fingerprint)"
        }
    }

    mutating func recordUploadedPath(_ path: String) {
        guard case .staged(let data, let fingerprint, _) = source else { return }
        source = .staged(data: data, fingerprint: fingerprint, uploadedPath: path)
    }

    private static func fingerprint(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
@Observable
final class ProfileViewModel {
    enum ExitAction: Equatable {
        case signOut
        case deleteAccount
    }

    enum SaveCompletion: Equatable {
        case succeeded
        case failed
    }

    private struct CanonicalProfileState: Equatable {
        let displayName: String
        let avatarColorHex: String
        let bio: String?
        let photoReferences: [String]
    }

    private struct ConfirmedDraft {
        let displayName: String
        let avatarColorHex: String
        let bio: String?
        let photos: [ProfilePhotoDraft]
    }

    private let deps: AppDependencies

    // MARK: Original snapshot + working draft

    /// Immutable until a complete profile update succeeds.
    private var originalState: CanonicalProfileState?

    var displayName = ""
    var selectedColorHex = AvatarPalette.hexes[0]
    var bio = ""
    private(set) var draftPhotos: [ProfilePhotoDraft] = []

    /// Raw picker results are converted to downscaled, in-memory staged
    /// photos. No upload or profile update happens in this callback.
    var photoItems: [PhotosPickerItem] = [] {
        didSet { Task { await ingestPickedPhotos() } }
    }

    private(set) var isLoading = true
    private(set) var isSaving = false
    private(set) var isProcessingPhotos = false
    private(set) var isPerformingAccountAction = false
    private(set) var statusMessage: String?

    var isSaveConfirmationPresented = false
    var isUnsavedChangesWarningPresented = false
    private var confirmedDraft: ConfirmedDraft?

    var isWorking: Bool {
        isLoading || isSaving || isProcessingPhotos || isPerformingAccountAction
    }

    var hasUnsavedChanges: Bool {
        guard let originalState else { return false }
        return currentCanonicalState != originalState
    }

    var isDraftValid: Bool {
        let name = normalizedDisplayName
        return (1...40).contains(name.count)
            && bio.count <= AuthValidation.bioLimit
            && draftPhotos.count <= AuthValidation.maxProfilePhotos
    }

    var canSaveChanges: Bool {
        hasUnsavedChanges
            && isDraftValid
            && !isWorking
            && !isSaveConfirmationPresented
            && !isUnsavedChangesWarningPresented
    }

    var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    var bioRemaining: Int { AuthValidation.bioLimit - bio.count }
    var canAddPhotos: Bool {
        draftPhotos.count < AuthValidation.maxProfilePhotos && !isWorking
    }

    // Appearance (dark mode) preference surface
    var appearance: AppearancePreference {
        get { deps.appearance.preference }
        set { deps.appearance.preference = newValue }
    }

    // MARK: Daily reminder surface

    var reminderEnabled: Bool { deps.reminders.settings.isEnabled }
    var reminderPermissionDenied: Bool { deps.reminders.permissionDenied }

    /// The chosen daily reminder time as a `Date` for a time-only picker.
    var reminderTime: Date {
        var components = DateComponents()
        components.hour = deps.reminders.settings.hour
        components.minute = deps.reminders.settings.minute
        return Calendar.current.date(from: components) ?? .now
    }

    /// Loads the current OS permission state so the UI can show a denial note.
    func refreshReminderStatus() async {
        await deps.reminders.updateAuthorizationStatus()
    }

    func setReminderEnabled(_ enabled: Bool) async {
        await deps.reminders.setEnabled(enabled)
    }

    func setReminderTime(_ date: Date) async {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        await deps.reminders.updateTime(
            hour: components.hour ?? 19,
            minute: components.minute ?? 0
        )
    }

    #if DEBUG
    // DEBUG bindings surface
    var simulateNotPostedToday: Bool {
        get { deps.debug.simulateNotPostedToday }
        set { deps.debug.simulateNotPostedToday = newValue }
    }

    var mockDayOffset: Int { deps.dateProvider.dayOffset }
    #endif

    /// Live builds hide the DEBUG tooling — those knobs only make sense
    /// against the mock world.
    var isLiveBackend: Bool { deps.isLive }

    init(deps: AppDependencies) {
        self.deps = deps
    }

    /// Captures the original profile exactly once for this editing session.
    /// Later model reconciliation cannot silently overwrite an in-progress
    /// draft. A successful save deliberately replaces the snapshot.
    func loadInitialState() async {
        guard originalState == nil else {
            isLoading = false
            return
        }
        guard let user = deps.session.currentUser else {
            statusMessage = "Your profile couldn't be loaded. Please try again."
            isLoading = false
            return
        }
        applyPersistedState(
            displayName: user.displayName,
            avatarColorHex: user.avatarColorHex,
            bio: user.bio,
            photoPaths: user.profilePhotoPaths
        )
        isLoading = false
    }

    // MARK: Draft photos

    private func ingestPickedPhotos() async {
        guard !photoItems.isEmpty, !isSaving else { return }
        let items = photoItems
        photoItems = []
        isProcessingPhotos = true
        defer { isProcessingPhotos = false }

        for item in items {
            guard draftPhotos.count < AuthValidation.maxProfilePhotos else { break }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let scaled = ImageDownscaler.jpegData(
                      from: image,
                      maxDimension: ImageDownscaler.avatarMaxDimension
                  ) else { continue }
            stagePhotoData(scaled)
        }
    }

    /// Adds already-validated/downscaled JPEG bytes to the working draft.
    /// Kept as a separate operation so image staging and dirty comparison
    /// are testable without driving the system photo picker.
    func stagePhotoData(_ data: Data) {
        guard draftPhotos.count < AuthValidation.maxProfilePhotos, !data.isEmpty else { return }
        draftPhotos.append(ProfilePhotoDraft(stagedData: data))
        statusMessage = nil
    }

    func removePhoto(at index: Int) {
        guard draftPhotos.indices.contains(index), !isWorking else { return }
        let removed = draftPhotos.remove(at: index)
        cleanupStagedAsset(removed)
        Haptics.light()
    }

    // MARK: Confirmed save

    /// Takes an immutable copy of exactly what the confirmation describes.
    /// Nothing is uploaded or persisted until `confirmAndSave()` is called.
    func requestSaveConfirmation() {
        guard canSaveChanges else { return }
        confirmedDraft = makeConfirmedDraft()
        statusMessage = nil
        isSaveConfirmationPresented = true
    }

    /// Cancel preserves the complete working draft. Navigation attempts are
    /// never retained by this view model, so there is nothing to replay.
    func cancelSaveConfirmation() {
        confirmedDraft = nil
        isSaveConfirmationPresented = false
    }

    /// Persists the captured draft once, after explicit confirmation.
    /// Uploads may finish before the profile-row update; their returned paths
    /// are retained in the draft on failure so a retry does not re-upload.
    func confirmAndSave() async -> SaveCompletion {
        guard let confirmedDraft, !isSaving else { return .failed }
        isSaveConfirmationPresented = false
        isSaving = true
        statusMessage = nil
        defer { isSaving = false }

        do {
            guard let user = deps.session.currentUser else { throw AuthError.notAuthenticated }
            var savedPaths: [String] = []
            for photo in confirmedDraft.photos {
                switch photo.source {
                case .persisted(let path):
                    savedPaths.append(path)
                case .staged(let data, _, let uploadedPath):
                    if let uploadedPath {
                        savedPaths.append(uploadedPath)
                    } else {
                        let path = try await deps.mediaService.saveImageData(
                            data,
                            preferredName: "avatars/\(user.id.uuidString.lowercased())/\(UUID().uuidString).jpg"
                        )
                        savedPaths.append(path)
                        recordUploadedPath(path, for: photo.id)
                    }
                }
            }

            try await deps.auth.updateProfile(
                user: user,
                displayName: confirmedDraft.displayName,
                avatarColorHex: confirmedDraft.avatarColorHex,
                bio: confirmedDraft.bio,
                photoPaths: savedPaths
            )

            // Only a fully successful profile update advances the immutable
            // original snapshot. Reconcile by stable draft-photo IDs instead
            // of replacing the working draft: a picker callback or other
            // local edit that arrived after confirmation must remain visible
            // and dirty rather than being silently discarded.
            reconcileDraftAfterSuccessfulSave(confirmedDraft, savedPaths: savedPaths)
            self.confirmedDraft = nil
            statusMessage = hasUnsavedChanges ? "Confirmed changes saved" : "Saved"
            Haptics.success()

            return .succeeded
        } catch {
            statusMessage = error.localizedDescription
            self.confirmedDraft = nil
            // The original snapshot remains untouched and the full draft
            // stays dirty. No navigation intent exists to resume.
            return .failed
        }
    }

    // MARK: Unsaved-change exits

    /// Synchronously decides whether navigation may begin. A dirty draft
    /// blocks the attempt before router state changes and only presents the
    /// warning; no destination or completion closure is stored.
    func requestNavigation() -> Bool {
        guard hasUnsavedChanges else { return true }
        guard !isWorking else { return false }
        if !isUnsavedChangesWarningPresented, !isSaveConfirmationPresented {
            isUnsavedChangesWarningPresented = true
        }
        return false
    }

    /// Account actions use the same synchronous guard, but the action is
    /// returned only for immediate execution when the draft is already clean.
    func requestExit(_ action: ExitAction) -> ExitAction? {
        requestNavigation() ? action : nil
    }

    func keepEditing() {
        isUnsavedChangesWarningPresented = false
    }

    func discardChanges() {
        restoreOriginalDraft()
        isUnsavedChangesWarningPresented = false
    }

    // MARK: Account actions

    func signOut() async {
        try? await deps.auth.signOut()
        deps.session.currentUser = nil
        deps.session.needsProfileSetup = false
    }

    /// Returns true on success so the view can route back to onboarding.
    func deleteAccount() async -> Bool {
        isPerformingAccountAction = true
        defer { isPerformingAccountAction = false }
        do {
            try await deps.auth.deleteAccount()
            deps.session.currentUser = nil
            deps.session.needsProfileSetup = false
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    // MARK: State helpers

    private var normalizedDisplayName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentCanonicalState: CanonicalProfileState {
        CanonicalProfileState(
            displayName: normalizedDisplayName,
            avatarColorHex: selectedColorHex,
            bio: AuthValidation.sanitizedBio(bio),
            photoReferences: draftPhotos.map(\.canonicalReference)
        )
    }

    private func makeConfirmedDraft() -> ConfirmedDraft {
        ConfirmedDraft(
            displayName: normalizedDisplayName,
            avatarColorHex: selectedColorHex,
            bio: AuthValidation.sanitizedBio(bio),
            photos: draftPhotos
        )
    }

    private func applyPersistedState(
        displayName: String,
        avatarColorHex: String,
        bio: String?,
        photoPaths: [String]
    ) {
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBio = AuthValidation.sanitizedBio(bio)
        self.displayName = normalizedName
        selectedColorHex = avatarColorHex
        self.bio = normalizedBio ?? ""
        draftPhotos = photoPaths.map { ProfilePhotoDraft(persistedPath: $0) }
        originalState = CanonicalProfileState(
            displayName: normalizedName,
            avatarColorHex: avatarColorHex,
            bio: normalizedBio,
            photoReferences: draftPhotos.map(\.canonicalReference)
        )
    }

    private func reconcileDraftAfterSuccessfulSave(
        _ savedDraft: ConfirmedDraft,
        savedPaths: [String]
    ) {
        let persistedPathsByDraftID = Dictionary(
            uniqueKeysWithValues: zip(savedDraft.photos.map(\.id), savedPaths)
        )

        draftPhotos = draftPhotos.map { photo in
            guard let savedPath = persistedPathsByDraftID[photo.id] else { return photo }
            return ProfilePhotoDraft(id: photo.id, persistedPath: savedPath)
        }

        originalState = CanonicalProfileState(
            displayName: savedDraft.displayName,
            avatarColorHex: savedDraft.avatarColorHex,
            bio: savedDraft.bio,
            photoReferences: savedPaths.map { "persisted:\($0)" }
        )
    }

    private func restoreOriginalDraft() {
        guard let originalState else { return }
        cleanupAllStagedAssets()
        displayName = originalState.displayName
        selectedColorHex = originalState.avatarColorHex
        bio = originalState.bio ?? ""
        draftPhotos = originalState.photoReferences.compactMap { reference in
            let prefix = "persisted:"
            guard reference.hasPrefix(prefix) else { return nil }
            return ProfilePhotoDraft(persistedPath: String(reference.dropFirst(prefix.count)))
        }
        statusMessage = nil
    }

    private func recordUploadedPath(_ path: String, for id: UUID) {
        guard let index = draftPhotos.firstIndex(where: { $0.id == id }) else { return }
        draftPhotos[index].recordUploadedPath(path)
    }

    private func cleanupStagedAsset(_ photo: ProfilePhotoDraft) {
        if let path = photo.stagedUploadPath {
            // LiveMediaService can remove the local staged cache today; its
            // documented orphan-cleanup job will eventually remove an upload
            // that never became referenced by a profile row.
            deps.mediaService.deleteImage(at: path)
        }
    }

    private func cleanupAllStagedAssets() {
        draftPhotos.forEach(cleanupStagedAsset)
    }

    // MARK: DEBUG actions

    #if DEBUG
    /// Wipes the store and rebuilds the seed world behind the splash, then
    /// re-runs the launch flow so the UI lands back in the seeded state.
    func regenerateSeedData() async {
        isPerformingAccountAction = true
        deps.session.isReady = false
        defer {
            deps.session.isReady = true
            isPerformingAccountAction = false
        }
        do {
            deps.dateProvider.reset()
            deps.debug.simulateNotPostedToday = false
            deps.session.currentUser = nil
            deps.session.needsProfileSetup = false
            try? await deps.auth.signOut()
            try await deps.seeder.regenerate()
            if case .signedIn(let user) = try await deps.auth.currentState() {
                deps.session.currentUser = user
            }
            originalState = nil
            isLoading = true
            await loadInitialState()
            statusMessage = "Seed data regenerated"
        } catch {
            statusMessage = "Regenerate failed: \(error.localizedDescription)"
        }
    }

    /// Moves the mock clock forward one day — the tool for demoing streak
    /// math (and the recovery window) without waiting for midnight.
    func advanceMockDay() async {
        deps.dateProvider.dayOffset += 1
        Haptics.light()
    }
    #endif
}

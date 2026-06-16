import Foundation
import Observation
import PhotosUI
import SwiftUI

@MainActor
@Observable
final class ProfileViewModel {
    private let deps: AppDependencies

    var displayName = ""
    var selectedColorHex = AvatarPalette.hexes[0]
    var bio = ""
    private(set) var photoPaths: [String] = []
    /// New picks pending upload, replacing/extending photoPaths on save.
    var photoItems: [PhotosPickerItem] = [] {
        didSet { Task { await ingestPickedPhotos() } }
    }
    private(set) var isWorking = false
    private(set) var statusMessage: String?

    var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    var bioRemaining: Int { AuthValidation.bioLimit - bio.count }
    var canAddPhotos: Bool { photoPaths.count < AuthValidation.maxProfilePhotos }

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

    // DEBUG bindings surface
    var simulateNotPostedToday: Bool {
        get { deps.debug.simulateNotPostedToday }
        set { deps.debug.simulateNotPostedToday = newValue }
    }

    var mockDayOffset: Int { deps.dateProvider.dayOffset }

    /// Live builds hide the DEBUG tooling — those knobs only make sense
    /// against the mock world.
    var isLiveBackend: Bool { deps.isLive }

    init(deps: AppDependencies) {
        self.deps = deps
        if let user = deps.session.currentUser {
            displayName = user.displayName
            selectedColorHex = user.avatarColorHex
            bio = user.bio ?? ""
            photoPaths = user.profilePhotoPaths
        }
    }

    private func ingestPickedPhotos() async {
        guard !photoItems.isEmpty, let user = deps.session.currentUser else { return }
        let items = photoItems
        photoItems = []
        isWorking = true
        defer { isWorking = false }
        for item in items {
            guard photoPaths.count < AuthValidation.maxProfilePhotos else { break }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  UIImage(data: data) != nil else { continue }
            if let path = try? await deps.mediaService.saveImageData(
                data,
                preferredName: "avatars/\(user.id.uuidString)/\(UUID().uuidString).jpg"
            ) {
                photoPaths.append(path)
            }
        }
        await persistProfile(status: "Photos updated")
    }

    func removePhoto(at index: Int) {
        guard photoPaths.indices.contains(index) else { return }
        photoPaths.remove(at: index)
        Haptics.light()
        Task { await persistProfile(status: "Photos updated") }
    }

    func saveProfile() async {
        await persistProfile(status: "Saved")
        Haptics.success()
    }

    private func persistProfile(status: String) async {
        guard let user = deps.session.currentUser else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await deps.auth.updateProfile(
                user: user,
                displayName: displayName,
                avatarColorHex: selectedColorHex,
                bio: bio,
                photoPaths: photoPaths
            )
            statusMessage = status
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func signOut() async {
        try? await deps.auth.signOut()
        deps.session.currentUser = nil
        deps.session.needsProfileSetup = false
    }

    // MARK: DEBUG actions

    /// Wipes the store and rebuilds the seed world behind the splash, then
    /// re-runs the launch flow so the UI lands back in the seeded state.
    func regenerateSeedData() async {
        isWorking = true
        deps.session.isReady = false
        defer {
            deps.session.isReady = true
            isWorking = false
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
}

import Foundation
import Observation

@MainActor
@Observable
final class ProfileViewModel {
    private let deps: AppDependencies

    var displayName = ""
    var selectedColorHex = AvatarPalette.hexes[0]
    private(set) var isWorking = false
    private(set) var statusMessage: String?

    var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
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
        }
    }

    func saveProfile() async {
        guard let user = deps.session.currentUser else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await deps.auth.updateProfile(
                user: user,
                displayName: displayName,
                avatarColorHex: selectedColorHex
            )
            statusMessage = "Saved"
            Haptics.success()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func signOut() async {
        try? await deps.auth.signOut()
        deps.session.currentUser = nil
        deps.session.activeVault = nil
        deps.session.needsProfileSetup = false
    }

    // MARK: DEBUG actions

    /// Wipes the store and rebuilds the seed world, then re-runs the
    /// launch flow so the UI lands back in the seeded LOCKED state.
    func regenerateSeedData() async {
        isWorking = true
        // Drop to the splash while the world is torn down and rebuilt —
        // otherwise onboarding flashes and views can render mid-deletion.
        deps.session.isReady = false
        defer {
            deps.session.isReady = true
            isWorking = false
        }
        do {
            deps.dateProvider.reset()
            deps.debug.simulateNotPostedToday = false
            deps.session.currentUser = nil
            deps.session.activeVault = nil
            deps.session.needsProfileSetup = false
            try? await deps.auth.signOut()
            try await deps.seeder.regenerate()
            if case .signedIn(let user) = try await deps.auth.currentState() {
                deps.session.currentUser = user
                let vaults = try await deps.vaultService.vaults(for: user)
                deps.session.activeVault = vaults.first
                if let vault = vaults.first {
                    try await deps.vaultService.recomputeStreak(for: vault, now: deps.dateProvider.now)
                }
            }
            statusMessage = "Seed data regenerated"
        } catch {
            statusMessage = "Regenerate failed: \(error.localizedDescription)"
        }
    }

    /// Moves the mock clock forward one day and recomputes the streak —
    /// the tool for demoing streak math without waiting for midnight.
    func advanceMockDay() async {
        deps.dateProvider.dayOffset += 1
        if let vault = deps.session.activeVault {
            try? await deps.vaultService.recomputeStreak(for: vault, now: deps.dateProvider.now)
        }
        Haptics.light()
    }
}

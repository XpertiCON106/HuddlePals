import Foundation
import Observation

/// Owns app bootstrap: seed → restore session → pick active vault →
/// recompute streak. RootView stays dumb.
@MainActor
@Observable
final class RootViewModel {
    private let deps: AppDependencies
    private(set) var bootstrapError: String?

    init(deps: AppDependencies) {
        self.deps = deps
    }

    func bootstrap() async {
        guard !deps.session.isReady else { return }
        do {
            try deps.seeder.seedIfNeeded()
            let user = try await deps.auth.restoreSession()
            deps.session.currentUser = user
            if let user {
                await selectInitialVault(for: user)
            }
        } catch {
            bootstrapError = error.localizedDescription
        }
        deps.session.isReady = true
    }

    /// Called after onboarding sign-in too.
    func selectInitialVault(for user: User) async {
        do {
            let vaults = try await deps.vaultService.vaults(for: user)
            deps.session.activeVault = vaults.first
            if let vault = vaults.first {
                try await deps.vaultService.recomputeStreak(for: vault, now: deps.dateProvider.now)
            }
        } catch {
            bootstrapError = error.localizedDescription
        }
    }
}

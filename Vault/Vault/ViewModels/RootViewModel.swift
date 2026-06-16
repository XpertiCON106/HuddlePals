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
            if !deps.isLive {
                try await deps.seeder.seedIfNeeded()
            }
            switch try await deps.auth.currentState() {
            case .signedIn(let user):
                deps.session.currentUser = user
            case .needsProfile:
                deps.session.needsProfileSetup = true
            case .signedOut:
                break
            }
        } catch {
            bootstrapError = error.localizedDescription
        }
        deps.session.isReady = true
        // Bring the daily reminder schedule in line with launch state.
        await deps.reminders.refresh()
    }
}

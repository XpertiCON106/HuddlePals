import Foundation
import Observation

/// Owns app bootstrap: seed (mock only) → restore session → schedule
/// reminders. RootView stays dumb.
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
                deps.session.blockedUserIDs = (try? await deps.moderationService.blockedUserIDs()) ?? []
            case .needsProfile:
                deps.session.needsProfileSetup = true
            case .signedOut:
                break
            }
        } catch {
            bootstrapError = error.localizedDescription
        }
        deps.session.isReady = true
        // Bring the daily reminder schedule in line with launch state, and
        // register for activity notifications if they're allowed (never asks).
        await deps.reminders.refresh()
        await deps.push.refresh()
    }
}

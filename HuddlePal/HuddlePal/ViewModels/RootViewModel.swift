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
            // A rejection survives reopening. Only local credential presence
            // is checked, so a legacy account keeps its deletion path.
            if deps.ageScreening.isBlocked() {
                deps.session.needsProfileSetup = await deps.auth.hasStoredSession()
                deps.session.isReady = true
                return
            }
            switch try await deps.auth.currentState() {
            case .signedIn(let user):
                deps.ageScreening.clearPendingBirthday()
                if let claimant = deps.terms.claimedBy, claimant != user.id { deps.terms.withdraw() }
                deps.session.currentUser = user
                deps.session.blockedUserIDs = (try? await deps.moderationService.blockedUserIDs()) ?? []
            case .needsProfile:
                deps.session.needsProfileSetup = true
            case .needsBirthday(let user):
                deps.session.pendingBirthdayUser = user
            case .signedOut:
                break
            }
        } catch {
            bootstrapError = error.localizedDescription
        }
        // UI tests can start with Plus.
        if let plans = deps.mockPlans, UITestHooks.plus, let user = deps.session.currentUser {
            plans.setPlus(true, for: user.id)
        }
        deps.session.isReady = true
        // Bring the daily reminder schedule in line with launch state, and
        // register for activity notifications if they're allowed (never asks).
        await deps.reminders.refresh()
        await deps.push.refresh()
        await deps.termsRecorder?.refresh()
        await deps.plus.refresh()
        // After Plus is known: nobody with it gets a reminder about it.
        await deps.plusPromo.refresh()
    }

    func retry() async {
        bootstrapError = nil
        deps.session.isReady = false
        await bootstrap()
    }

    func signOut() async {
        bootstrapError = nil
        await deps.signOut()
    }
}

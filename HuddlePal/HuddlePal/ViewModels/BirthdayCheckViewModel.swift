import Foundation
import Observation

/// Existing accounts confirm eligibility before the main app is mounted.
/// A failed lookup or save keeps this gate in place.
@MainActor
@Observable
final class BirthdayCheckViewModel {
    private let deps: AppDependencies
    var birthday: Birthday?
    private(set) var isSaving = false
    private(set) var isUnderage: Bool
    private(set) var errorMessage: String?
    private(set) var hasSavedBirthday = false

    init(deps: AppDependencies) {
        self.deps = deps
        birthday = deps.ageScreening.birthday
        isUnderage = deps.session.hasIneligibleBirthday || deps.ageScreening.isBlocked()
    }

    var canContinue: Bool { birthday?.isValid == true && !isSaving && !isUnderage }

    func save() async {
        guard canContinue, let birthday else { return }
        guard let pendingID = deps.session.pendingBirthdayUser?.id else { return }
        guard deps.ageScreening.submit(birthday) else {
            isUnderage = deps.ageScreening.isBlocked()
            return
        }
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        do {
            if !hasSavedBirthday {
                try await deps.auth.saveBirthday(birthday)
                hasSavedBirthday = true
            }
            guard case .signedIn(let user) = try await deps.auth.currentState() else {
                throw AuthError.notAuthenticated
            }
            guard deps.session.pendingBirthdayUser?.id == pendingID, user.id == pendingID else { return }
            deps.ageScreening.clearPendingBirthday()
            if let claimant = deps.terms.claimedBy, claimant != user.id { deps.terms.withdraw() }
            deps.session.pendingBirthdayUser = nil
            deps.session.currentUser = user
            deps.session.blockedUserIDs = (try? await deps.moderationService.blockedUserIDs()) ?? []
            Haptics.success()
        } catch {
            if deps.session.pendingBirthdayUser?.id == pendingID {
                errorMessage = error.localizedDescription
            }
        }
    }

    func signOut() async { await deps.signOut() }
}

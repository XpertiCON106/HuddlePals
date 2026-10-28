import Foundation
import Observation

/// Deleting the account, on its own page: what goes and what stays, Apple's
/// billing when it goes on, and typing DELETE before the button works.
/// Apple then confirms it's them: its fresh authorization code lets the
/// server revoke the app's Apple tokens (App Review 5.1.1(v)). When Apple
/// can't confirm, deleting is still offered without it (Apple TN3194).
@MainActor
@Observable
final class DeleteAccountViewModel {
    /// What has to be typed, exactly.
    static let confirmationWord = "DELETE"
    /// Store-wide wording, also checked by tests.
    static let billingContinuesWarning = "Your HuddlePals+ subscription is billed by Apple and keeps renewing after your account is deleted. To stop it, cancel it in Settings › your name › Subscriptions."

    private let deps: AppDependencies

    var confirmation = ""
    private(set) var isDeleting = false
    /// Whether Apple will keep billing after the account is gone: deleting
    /// it doesn't cancel the subscription.
    private(set) var appleBillingContinues = false
    private(set) var errorMessage: String?
    /// Apple couldn't confirm the person (no Apple Account on the device,
    /// Apple unreachable): the page offers to delete without it.
    var isAppleConfirmationFailurePresented = false

    init(deps: AppDependencies) {
        self.deps = deps
    }

    var isConfirmed: Bool {
        confirmation.trimmingCharacters(in: .whitespaces) == Self.confirmationWord
    }

    var canDelete: Bool { isConfirmed && !isDeleting }

    /// Apple's subscription settings exist only for a real subscription.
    var canManageSubscription: Bool { deps.isLive }

    func load() async {
        appleBillingContinues = await deps.plus.appleSubscriptionWillRenew()
    }

    /// True once deleted: the session is over and the app goes back to its
    /// first screen.
    func delete() async -> Bool {
        guard canDelete else { return false }
        isDeleting = true
        defer { isDeleting = false }
        errorMessage = nil
        let code: String
        do {
            code = try await deps.appleReauth.authorizationCode()
        } catch is CancellationError {
            return false // closed Apple's sheet: nothing is deleted
        } catch {
            isAppleConfirmationFailurePresented = true
            return false
        }
        return await performDeletion(appleAuthorizationCode: code)
    }

    /// Deletes without Apple's confirmation, once the person chose to after
    /// it failed. They remove the app from Sign in with Apple themselves.
    func deleteWithoutApple() async -> Bool {
        guard isConfirmed, !isDeleting else { return false }
        isDeleting = true
        defer { isDeleting = false }
        errorMessage = nil
        return await performDeletion(appleAuthorizationCode: nil)
    }

    private func performDeletion(appleAuthorizationCode: String?) async -> Bool {
        do {
            try await deps.auth.deleteAccount(appleAuthorizationCode: appleAuthorizationCode)
            await deps.endSession()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

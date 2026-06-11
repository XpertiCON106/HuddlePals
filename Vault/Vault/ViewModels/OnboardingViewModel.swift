import Foundation
import Observation

@MainActor
@Observable
final class OnboardingViewModel {
    struct Card: Identifiable {
        let id = UUID()
        let systemImage: String
        let title: String
        let message: String
    }

    static let cards = [
        Card(
            systemImage: "photo.on.rectangle.angled",
            title: "One photo a day",
            message: "Everyone in your vault deposits a single photo, every day. Small, honest, real."
        ),
        Card(
            systemImage: "lock.fill",
            title: "Locked until you share",
            message: "Today's photos stay blurred until you deposit your own. Reciprocity, not lurking."
        ),
        Card(
            systemImage: "archivebox.fill",
            title: "Yours forever",
            message: "Every day becomes part of a permanent archive your group keeps together."
        ),
    ]

    private let deps: AppDependencies

    var pageIndex = 0
    var displayName = ""
    var selectedColorHex = AvatarPalette.hexes[0]
    var isSigningIn = false
    var errorMessage: String?

    var canSignIn: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(deps: AppDependencies) {
        self.deps = deps
    }

    func signIn() async {
        guard canSignIn else { return }
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            let user = try await deps.auth.signIn(
                displayName: displayName,
                avatarColorHex: selectedColorHex
            )
            deps.session.currentUser = user
            let vaults = try await deps.vaultService.vaults(for: user)
            deps.session.activeVault = vaults.first
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

import Foundation
import Observation

enum AppTab: Hashable {
    case vaults
    case profile
}

/// A tab change requested while the profile editor is visible. The profile
/// screen owns the unsaved-draft decision, so the router parks the requested
/// destination until the editor explicitly completes or cancels it.
struct ProfileExitRequest: Identifiable, Equatable {
    let id = UUID()
    let destination: AppTab
    let routeAfterExit: Route?
}

/// Typed navigation destinations. @Model classes are Hashable via identity,
/// so they can ride along in the path.
enum Route: Hashable {
    case vaultHome(Vault)
    case archive(Vault)
    case depositDetail(Deposit)
    case vaultSettings(Vault)
    case createVault
    case joinVault
    case userProfile(User)
}

@MainActor
@Observable
final class AppRouter {
    var selectedTab: AppTab = .vaults
    /// Single stack for the Vaults tab: list → vault home → deeper screens.
    var vaultsPath: [Route] = []
    private(set) var profileExitRequest: ProfileExitRequest?

    func openVault(_ vault: Vault) {
        selectedTab = .vaults
        vaultsPath = [.vaultHome(vault)]
    }

    func popToVaultList() {
        vaultsPath.removeAll()
    }

    func requestProfileExit(to destination: AppTab, routeAfterExit: Route? = nil) {
        guard destination != .profile, profileExitRequest == nil else { return }
        profileExitRequest = ProfileExitRequest(
            destination: destination,
            routeAfterExit: routeAfterExit
        )
    }

    func completeProfileExit(to destination: AppTab) {
        let routeAfterExit = profileExitRequest?.routeAfterExit
        profileExitRequest = nil
        selectedTab = destination
        if destination == .vaults, let routeAfterExit,
           vaultsPath.last != routeAfterExit {
            vaultsPath.append(routeAfterExit)
        }
    }

    func cancelProfileExit() {
        profileExitRequest = nil
    }

    func resetAll() {
        vaultsPath.removeAll()
        profileExitRequest = nil
        selectedTab = .vaults
    }
}

import Foundation
import Observation

enum AppTab: Hashable {
    case vaults
    case profile
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
    private(set) var selectedTab: AppTab = .vaults
    /// Single stack for the Vaults tab: list → vault home → deeper screens.
    var vaultsPath: [Route] = []

    /// The mounted profile editor installs a synchronous guard. It returns
    /// before any router state is mutated, so a dirty editor can present its
    /// warning without the requested destination ever becoming active.
    /// Neither a destination nor a navigation closure is retained.
    @ObservationIgnored private var profileNavigationGuardID: UUID?
    @ObservationIgnored private var profileNavigationGuard: (() -> Bool)?

    func installProfileNavigationGuard(id: UUID, handler: @escaping () -> Bool) {
        profileNavigationGuardID = id
        profileNavigationGuard = handler
    }

    func removeProfileNavigationGuard(id: UUID) {
        guard profileNavigationGuardID == id else { return }
        profileNavigationGuardID = nil
        profileNavigationGuard = nil
    }

    /// Returns false without changing selection or path when the mounted
    /// profile editor blocks the attempt.
    @discardableResult
    func selectTab(_ destination: AppTab) -> Bool {
        guard destination != selectedTab else { return true }
        guard canNavigateAwayFromProfile(to: destination) else { return false }
        selectedTab = destination
        return true
    }

    /// Atomically guards both the tab change and the destination route. This
    /// prevents a deep link from mutating the navigation path before the
    /// profile editor has approved leaving.
    @discardableResult
    func navigateToVaults(route: Route? = nil) -> Bool {
        guard canNavigateAwayFromProfile(to: .vaults) else { return false }
        selectedTab = .vaults
        if let route, vaultsPath.last != route {
            vaultsPath.append(route)
        }
        return true
    }

    func openVault(_ vault: Vault) {
        guard canNavigateAwayFromProfile(to: .vaults) else { return }
        selectedTab = .vaults
        vaultsPath = [.vaultHome(vault)]
    }

    func popToVaultList() {
        vaultsPath.removeAll()
    }

    private func canNavigateAwayFromProfile(to destination: AppTab) -> Bool {
        guard selectedTab == .profile, destination != .profile else { return true }
        return profileNavigationGuard?() ?? true
    }

    func resetAll() {
        vaultsPath.removeAll()
        profileNavigationGuardID = nil
        profileNavigationGuard = nil
        selectedTab = .vaults
    }
}

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
    var selectedTab: AppTab = .vaults
    /// Single stack for the Vaults tab: list → vault home → deeper screens.
    var vaultsPath: [Route] = []

    func openVault(_ vault: Vault) {
        selectedTab = .vaults
        vaultsPath = [.vaultHome(vault)]
    }

    func popToVaultList() {
        vaultsPath.removeAll()
    }

    func resetAll() {
        vaultsPath.removeAll()
        selectedTab = .vaults
    }
}

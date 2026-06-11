import Foundation
import Observation

enum AppTab: Hashable {
    case today
    case archive
    case profile
}

/// Typed navigation destinations. @Model classes are Hashable via identity,
/// so they can ride along in the path.
enum Route: Hashable {
    case depositDetail(Deposit)
    case vaultSettings(Vault)
    case createVault
    case joinVault
}

@MainActor
@Observable
final class AppRouter {
    var selectedTab: AppTab = .today
    var todayPath: [Route] = []
    var archivePath: [Route] = []

    func popToRoot(of tab: AppTab) {
        switch tab {
        case .today: todayPath.removeAll()
        case .archive: archivePath.removeAll()
        case .profile: break
        }
    }

    func resetAll() {
        todayPath.removeAll()
        archivePath.removeAll()
        selectedTab = .today
    }
}

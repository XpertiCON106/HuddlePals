import SwiftUI
import SwiftData

@main
struct VaultApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var dependencies: AppDependencies
    @State private var router = AppRouter()

    init() {
        // Live when a filled-in Supabase.plist is bundled; mock otherwise.
        let deps: AppDependencies
        if let config = BackendConfig.load() {
            deps = AppDependencies.makeLive(config: config)
        } else {
            deps = AppDependencies.makeMock()
        }
        _dependencies = State(initialValue: deps)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(dependencies)
                .environment(router)
                .modelContainer(dependencies.modelContainer)
                .preferredColorScheme(dependencies.appearance.preference.colorScheme)
                .tint(Theme.accent)
                .onOpenURL { url in
                    handleDeepLink(url)
                }
                .onChange(of: scenePhase) { _, phase in
                    // Re-evaluate reminders on foreground: an upload made on
                    // another device (or earlier today) should silence the
                    // remaining nudges.
                    if phase == .active {
                        Task { await dependencies.reminders.refresh() }
                    }
                }
        }
    }

    /// vault://join/<CODE> — the shareable invite link. Routes to the Join
    /// screen with the code prefilled (or parks it until sign-in finishes).
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "vault", url.host == "join" else { return }
        let code = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (4...8).contains(code.count) else { return }
        dependencies.session.pendingInviteCode = code.uppercased()
        if dependencies.session.currentUser != nil {
            if router.selectedTab == .profile {
                // The profile editor must resolve an unsaved draft before a
                // programmatic deep link can move the user to Join.
                router.requestProfileExit(to: .vaults, routeAfterExit: .joinVault)
            } else {
                router.selectedTab = .vaults
                if router.vaultsPath.last != .joinVault {
                    router.vaultsPath.append(.joinVault)
                }
            }
        }
    }
}

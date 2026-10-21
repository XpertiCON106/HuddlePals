import SwiftUI
import SwiftData

@main
struct HuddlePalApp: App {
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

    /// huddlepal://join/<CODE> — the shareable invite link. Routes to the Join
    /// screen with the code prefilled (or parks it until sign-in finishes).
    private func handleDeepLink(_ url: URL) {
        guard let code = InviteLink.code(from: url) else { return }
        if dependencies.session.currentUser != nil {
            // `navigateToHuddles` consults the profile guard before mutating
            // either tab selection or path. A blocked link is canceled; its
            // code is deliberately not queued for replay after the warning.
            if router.navigateToHuddles(route: .joinHuddle) {
                dependencies.session.pendingInviteCode = code
            }
        } else {
            // Parked until sign-in; MainTabView then opens Join with it.
            dependencies.session.pendingInviteCode = code
        }
    }
}

import SwiftUI

/// Root router: splash while bootstrapping → onboarding when signed out →
/// the main tab UI once a session exists.
struct RootView: View {
    @Environment(AppDependencies.self) private var deps
    @State private var viewModel: RootViewModel?

    var body: some View {
        Group {
            if viewModel != nil, deps.session.isReady {
                if deps.session.currentUser == nil {
                    OnboardingView()
                } else {
                    MainTabView()
                }
            } else {
                SplashView()
            }
        }
        .background(Theme.background)
        .task {
            if viewModel == nil {
                let vm = RootViewModel(deps: deps)
                viewModel = vm
                await vm.bootstrap()
            }
        }
    }
}

private struct SplashView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("Vault")
                .font(Theme.displayFont(34))
                .foregroundStyle(Theme.textPrimary)
            Text("Preparing your vault…")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

// MARK: - Main tabs

struct MainTabView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            NavigationStack(path: $router.todayPath) {
                VaultHomeView()
                    .navigationDestination(for: Route.self) { RouteView(route: $0) }
            }
            .tabItem { Label("Today", systemImage: "lock.square.stack") }
            .tag(AppTab.today)

            NavigationStack(path: $router.archivePath) {
                ArchiveView()
                    .navigationDestination(for: Route.self) { RouteView(route: $0) }
            }
            .tabItem { Label("Archive", systemImage: "archivebox") }
            .tag(AppTab.archive)

            NavigationStack {
                ProfileView()
            }
            .tabItem { Label("Profile", systemImage: "person.crop.circle") }
            .tag(AppTab.profile)
        }
    }
}

/// Maps typed routes to destination screens.
struct RouteView: View {
    let route: Route

    var body: some View {
        switch route {
        case .depositDetail(let deposit):
            DepositDetailView(deposit: deposit)
        case .vaultSettings(let vault):
            VaultSettingsView(vault: vault)
        case .createVault:
            CreateVaultView()
        case .joinVault:
            JoinVaultView()
        }
    }
}

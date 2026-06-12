import SwiftUI

/// Root router: launch reveal while bootstrapping → onboarding when signed
/// out → the main tab UI once a session exists.
struct RootView: View {
    @Environment(AppDependencies.self) private var deps
    @State private var viewModel: RootViewModel?
    @State private var showLaunchReveal = true

    var body: some View {
        ZStack {
            Group {
                if viewModel != nil, deps.session.isReady {
                    if deps.session.currentUser == nil {
                        OnboardingView()
                    } else {
                        MainTabView()
                    }
                } else {
                    Theme.background.ignoresSafeArea()
                }
            }

            if showLaunchReveal {
                LaunchRevealView(isAppReady: deps.session.isReady) {
                    showLaunchReveal = false
                }
                .transition(.opacity)
                .zIndex(1)
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

// MARK: - Launch reveal

/// The vault dial draws itself in, breathes once, then the whole mark
/// springs forward and dissolves into the app. ~1.8s, spring physics
/// throughout; reduced-motion users get a quick crossfade.
private struct LaunchRevealView: View {
    let isAppReady: Bool
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ringProgress: CGFloat = 0
    @State private var spokesVisible = false
    @State private var wordmarkVisible = false
    @State private var exitScale: CGFloat = 1
    @State private var exitOpacity: CGFloat = 1
    @State private var exitStarted = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 22) {
                ZStack {
                    Circle()
                        .trim(from: 0, to: ringProgress)
                        .stroke(
                            Theme.accent,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round)
                        )
                        .frame(width: 96, height: 96)
                        .rotationEffect(.degrees(-90))

                    VaultSpokes()
                        .stroke(
                            Theme.accent,
                            style: StrokeStyle(lineWidth: 7, lineCap: .round)
                        )
                        .frame(width: 58, height: 58)
                        .opacity(spokesVisible ? 1 : 0)
                        .scaleEffect(spokesVisible ? 1 : 0.4)
                        .rotationEffect(.degrees(spokesVisible ? 0 : -50))

                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 13, height: 13)
                        .scaleEffect(spokesVisible ? 1 : 0.01)
                }

                Text("Vault")
                    .font(Theme.displayFont(30))
                    .foregroundStyle(Theme.textPrimary)
                    .opacity(wordmarkVisible ? 1 : 0)
                    .offset(y: wordmarkVisible ? 0 : 8)
            }
            .scaleEffect(exitScale)
        }
        .opacity(exitOpacity)
        .onAppear(perform: start)
        .onChange(of: isAppReady) {
            exitIfPossible()
        }
    }

    private func start() {
        if reduceMotion {
            ringProgress = 1
            spokesVisible = true
            wordmarkVisible = true
            exitIfPossible()
            return
        }
        withAnimation(.easeOut(duration: 0.7)) {
            ringProgress = 1
        }
        withAnimation(.spring(response: 0.55, dampingFraction: 0.62).delay(0.45)) {
            spokesVisible = true
        }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.75)) {
            wordmarkVisible = true
        }
        // Minimum dwell so a fast bootstrap still reads as a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.35) {
            exitIfPossible()
        }
    }

    private func exitIfPossible() {
        // Wait for both: animation dwell elapsed AND bootstrap finished.
        guard isAppReady, ringProgress == 1, !exitStarted else { return }
        guard wordmarkVisible || reduceMotion else { return }
        exitStarted = true
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.3)) { exitOpacity = 0 }
        } else {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) {
                exitScale = 1.12
            }
            withAnimation(.easeIn(duration: 0.32).delay(0.08)) {
                exitOpacity = 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            onFinished()
        }
    }
}

/// Five spokes of the vault wheel, drawn from the hub outward.
private struct VaultSpokes: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let inner = rect.width * 0.16
        let outer = rect.width * 0.5
        for index in 0..<5 {
            let angle = CGFloat(index) * (2 * .pi / 5) - .pi / 2
            path.move(to: CGPoint(
                x: center.x + cos(angle) * inner,
                y: center.y + sin(angle) * inner
            ))
            path.addLine(to: CGPoint(
                x: center.x + cos(angle) * outer,
                y: center.y + sin(angle) * outer
            ))
        }
        return path
    }
}

// MARK: - Main tabs

struct MainTabView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            NavigationStack(path: $router.vaultsPath) {
                VaultListView()
                    .navigationDestination(for: Route.self) { RouteView(route: $0) }
            }
            .tabItem { Label("Vaults", systemImage: "square.stack.3d.up") }
            .tag(AppTab.vaults)

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
        case .vaultHome(let vault):
            VaultHomeView(vault: vault)
        case .archive(let vault):
            ArchiveView(vault: vault)
        case .depositDetail(let deposit):
            DepositDetailView(deposit: deposit)
        case .vaultSettings(let vault):
            VaultSettingsView(vault: vault)
        case .createVault:
            CreateVaultView()
        case .joinVault:
            JoinVaultView()
        case .userProfile(let user):
            UserProfileView(user: user)
        }
    }
}

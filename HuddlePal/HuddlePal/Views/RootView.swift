import SwiftUI

/// Root router: launch reveal while bootstrapping → onboarding when signed
/// out or the current Terms aren't agreed to yet → the main tab UI once a
/// session exists and the Terms are accepted.
struct RootView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @State private var viewModel: RootViewModel?
    @State private var showLaunchReveal = true

    var body: some View {
        ZStack {
            Group {
                if viewModel != nil, deps.session.isReady {
                    // Even a restored session waits on the Terms: no one
                    // reaches the app without tapping Agree.
                    if deps.session.currentUser == nil || !deps.terms.hasAcceptedCurrentVersion {
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
        .onChange(of: deps.session.currentUser == nil) { _, signedOut in
            // However the session ended (sign-out, deletion, or the server
            // refusing it), the next account starts on a clean stack: no
            // route may point at a model that was just deleted.
            if signedOut { router.resetAll() }
        }
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

/// The hug mark draws itself in — the arm sweeps around, then the three
/// pals pop in one by one — and the whole mark springs forward and
/// dissolves into the app. ~1.8s, spring physics throughout; reduced-motion
/// users get a quick crossfade.
private struct LaunchRevealView: View {
    let isAppReady: Bool
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var armProgress: CGFloat = 0
    @State private var headsVisible = [false, false, false]
    @State private var wordmarkVisible = false
    @State private var exitScale: CGFloat = 1
    @State private var exitOpacity: CGFloat = 1
    @State private var exitStarted = false

    /// Side of the square the mark is laid out in — the icon's full canvas,
    /// so the mark itself is 0.64 × this wide.
    private let canvas: CGFloat = 150

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 22) {
                ZStack {
                    HugArm()
                        .trim(from: 0, to: armProgress)
                        .stroke(
                            Theme.accent,
                            style: StrokeStyle(lineWidth: canvas * HugMark.armWidth, lineCap: .round)
                        )

                    ForEach(HugMark.heads.indices, id: \.self) { index in
                        let head = HugMark.heads[index]
                        Circle()
                            .fill(Color(hex: head.hex))
                            .frame(width: canvas * HugMark.headDiameter, height: canvas * HugMark.headDiameter)
                            .scaleEffect(headsVisible[index] ? 1 : 0.01)
                            .position(x: canvas * head.x, y: canvas * (1 - head.y))
                    }
                }
                .frame(width: canvas, height: canvas)
                // The mark fills the middle half of its canvas; lay out only that.
                .frame(height: canvas * 0.5)

                Text("HuddlePals")
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
            armProgress = 1
            headsVisible = [true, true, true]
            wordmarkVisible = true
            exitIfPossible()
            return
        }
        withAnimation(.easeOut(duration: 0.6)) {
            armProgress = 1
        }
        for index in headsVisible.indices {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.55).delay(0.35 + 0.12 * Double(index))) {
                headsVisible[index] = true
            }
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
        guard isAppReady, armProgress == 1, !exitStarted else { return }
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

/// The hug mark's geometry, in unit coordinates of the app icon's canvas
/// (y up). Matches tools/generate_icon.swift; keep the two in sync.
private enum HugMark {
    static let armCenterY: CGFloat = 0.603
    static let armRadius: CGFloat = 0.285
    static let armWidth: CGFloat = 0.085
    static let headDiameter: CGFloat = 0.152
    static let heads: [(x: CGFloat, y: CGFloat, hex: String)] = [
        (0.335, 0.598, "F76B15"), // tangerine
        (0.5, 0.648, "E5484D"),   // coral
        (0.665, 0.598, "D6409F"), // magenta
    ]
}

/// The arm cradling the pals: an arc under them, drawn left to right so a
/// trim sweeps it in.
private struct HugArm: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.minY + rect.height * (1 - HugMark.armCenterY)),
            radius: rect.width * HugMark.armRadius,
            startAngle: .radians(0.92 * .pi),
            endAngle: .radians(0.08 * .pi),
            clockwise: true
        )
        return path
    }
}

// MARK: - Main tabs

struct MainTabView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: tabSelection) {
            NavigationStack(path: $router.huddlesPath) {
                HuddleListView()
                    .navigationDestination(for: Route.self) { RouteView(route: $0) }
            }
            .tabItem { Label("Huddles", systemImage: "square.stack.3d.up") }
            .tag(AppTab.huddles)

            NavigationStack {
                ProfileView()
            }
            .tabItem { Label("Profile", systemImage: "person.crop.circle") }
            .tag(AppTab.profile)
        }
    }

    /// The router invokes the mounted profile editor's guard synchronously.
    /// A rejected selection never changes `selectedTab`, so the destination
    /// tab cannot render even briefly.
    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { router.selectedTab },
            set: { destination in router.selectTab(destination) }
        )
    }
}

/// Maps typed routes to destination screens.
struct RouteView: View {
    let route: Route

    var body: some View {
        switch route {
        case .huddleHome(let huddle):
            HuddleHomeView(huddle: huddle)
        case .archive(let huddle):
            ArchiveView(huddle: huddle)
        case .depositDetail(let deposit):
            DepositDetailView(deposit: deposit)
        case .huddleSettings(let huddle):
            HuddleSettingsView(huddle: huddle)
        case .createHuddle:
            CreateHuddleView()
        case .joinHuddle:
            JoinHuddleView()
        case .userProfile(let user):
            UserProfileView(user: user)
        }
    }
}

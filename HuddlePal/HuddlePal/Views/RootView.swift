import SwiftUI

/// Root router: launch reveal while bootstrapping → onboarding when signed
/// out or the current Terms aren't agreed to yet → the huddle shelf once a
/// session exists and the Terms are accepted.
struct RootView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router
    @State private var viewModel: RootViewModel?
    @State private var showLaunchReveal = true

    /// Signed in, with the current Terms agreed to: the app itself.
    private var showsMain: Bool {
        viewModel != nil && deps.session.isReady
            && deps.session.currentUser != nil && deps.terms.hasAcceptedCurrentVersion
    }

    var body: some View {
        ZStack {
            Group {
                if viewModel != nil, deps.session.isReady {
                    if let error = viewModel?.bootstrapError {
                        VStack(spacing: 20) {
                            Text("Couldn't confirm your account")
                                .font(Theme.displayFont(24))
                            Text(error)
                                .multilineTextAlignment(.center)
                            PrimaryButton(title: "Try again") {
                                Task { await viewModel?.retry() }
                            }
                            Button("Sign out") { Task { await viewModel?.signOut() } }
                        }
                        .padding(Theme.screenPadding)
                    } else if deps.session.pendingBirthdayUser != nil {
                        BirthdayCheckView()
                    // Even a restored session waits on the Terms: no one
                    // reaches the app without tapping Agree.
                    } else if !showsMain {
                        OnboardingView()
                            .transition(.opacity)
                    } else {
                        MainView()
                            .transition(.opacity)
                    }
                } else {
                    Theme.background.ignoresSafeArea()
                }
            }
            // Into the app, onboarding fades out as the shelf fades in. Out
            // of it, no animation: the main UI goes in the same render as
            // the session (`AppDependencies.endSession`, which crossfades
            // from a still of the screen instead).
            .animation(showsMain ? .easeInOut(duration: 0.4) : nil, value: showsMain)

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
    /// The whole mark has been seen. Animated state takes its final value
    /// at once (only the drawing takes time), so this waits on the clock.
    @State private var hasPlayed = false

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
        .task {
            // The whole mark plays out, the wordmark settled, however fast the
            // app is ready (signed out, it's ready almost at once).
            guard !reduceMotion else { return }
            try? await Task.sleep(for: .seconds(1.45))
            hasPlayed = true
        }
        // Either can come last; each checks the other as it is now. (A
        // delayed closure would see `isAppReady` as it was at the start.)
        .onChange(of: hasPlayed) { exitIfPossible() }
        .onChange(of: isAppReady) { exitIfPossible() }
    }

    private func start() {
        if reduceMotion {
            armProgress = 1
            headsVisible = [true, true, true]
            wordmarkVisible = true
            hasPlayed = true
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
    }

    private func exitIfPossible() {
        // Wait for both: the mark played out AND bootstrap finished.
        guard isAppReady, hasPlayed, !exitStarted else { return }
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

// MARK: - Main

/// One stack, no tabs: the huddle shelf, with Profile and Create or join at
/// its top right.
struct MainView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        @Bindable var promo = deps.plusPromo
        NavigationStack(path: $router.huddlesPath) {
            HuddleListView()
                .navigationDestination(for: Route.self) { RouteView(route: $0) }
        }
        .sheet(item: $promo.sheet) { sheet in
            switch sheet {
            case .intro: PlusIntroSheet()
            case .paywall: PaywallView(context: .promotion)
            }
        }
        .task {
            // An invite link opened before signing in.
            router.openPendingInvite(deps.session)
        }
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
        case .profile:
            ProfileView()
        case .deleteAccount:
            DeleteAccountView()
        }
    }
}

import SwiftUI
import SwiftData
import UserNotifications

@main
struct HuddlePalApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var dependencies: AppDependencies
    @State private var router = AppRouter()

    init() {
        // Live when a filled-in Supabase.plist is bundled (and this isn't a
        // test run); mock otherwise.
        UITestHooks.resetPersistentStateIfTesting()
        // A recording left behind by a kill mid-capture: the only plaintext
        // video that is ever on disk.
        CaptureFiles.sweep()
        let deps: AppDependencies
        let config = BackendConfig.load()
        if let config, !UITestHooks.isUITesting,
           AppDependencies.usesLiveBackend(config: config, environment: ProcessInfo.processInfo.environment) {
            deps = AppDependencies.makeLive(config: config)
        } else {
            deps = AppDependencies.makeMock()
        }
        _dependencies = State(initialValue: deps)
        // Before launch finishes, so a tap that launched the app is delivered.
        UNUserNotificationCenter.current().delegate = deps.push.centerDelegate
        AppDelegate.push = deps.push
        // At launch, as StoreKit asks: renewals and purchases finished
        // elsewhere (Ask to Buy, another device) arrive from now on.
        deps.plus.start()
        // Screen titles in the app's display face (serif), like huddle names.
        let serif = UIFont.systemFont(ofSize: 34, weight: .bold).fontDescriptor.withDesign(.serif)
        if let serif {
            UINavigationBar.appearance().largeTitleTextAttributes = [.font: UIFont(descriptor: serif, size: 34)]
        }
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
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    // A universal link (huddlepals.com/join#…), if it isn't
                    // handed to onOpenURL.
                    if let url = activity.webpageURL { handleDeepLink(url) }
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    // Live updates: only while signed in and on screen.
                    dependencies.liveUpdates.setActive(phase == .active && dependencies.session.currentUser != nil)
                    // Re-evaluate reminders on foreground: an upload made on
                    // another device (or earlier today) should silence the
                    // remaining nudges. Push picks up a permission changed
                    // in iOS Settings. Plus may have renewed or run out.
                    if phase == .active {
                        Task {
                            await dependencies.reminders.refresh()
                            await dependencies.push.refresh()
                            await dependencies.termsRecorder?.refresh()
                            await dependencies.plus.refresh()
                            await dependencies.plusPromo.refresh()
                        }
                    }
                }
                .onChange(of: dependencies.session.currentUser?.id) { _, userID in
                    dependencies.liveUpdates.setActive(userID != nil && scenePhase == .active)
                    // Signed in (or switched account): register this device
                    // for the account's notifications, record (or ask for)
                    // its agreement to the Terms, and learn its plan.
                    if userID != nil {
                        Task {
                            await dependencies.push.refresh()
                            await dependencies.termsRecorder?.refresh()
                            await dependencies.plus.refresh()
                            await dependencies.plusPromo.refresh()
                        }
                    }
                }
                .onChange(of: dependencies.plus.isPremium) {
                    // Plus on: no more reminders about it. Run out: they
                    // come back, if asked for.
                    Task { await dependencies.plusPromo.refresh() }
                }
                .onChange(of: dependencies.terms.acceptedAt) {
                    // Agree tapped while signed in (a new version of the Terms).
                    Task { await dependencies.termsRecorder?.refresh() }
                }
        }
    }

    /// An invite link (`InviteLink`): routes to the Join screen with the code
    /// prefilled (or parks it until sign-in finishes).
    private func handleDeepLink(_ url: URL) {
        guard let code = InviteLink.code(from: url) else { return }
        if dependencies.session.currentUser != nil {
            // Join takes it as it opens. From an unsaved Profile, the guard
            // asks first; saving or discarding then goes on to Join.
            dependencies.session.pendingInviteCode = code
            router.navigateToHuddles(route: .joinHuddle)
        } else {
            // Parked until sign-in; MainView then opens Join with it.
            dependencies.session.pendingInviteCode = code
        }
    }
}

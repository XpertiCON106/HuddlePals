import Foundation
import Observation
import UIKit
import UserNotifications

// MARK: - Settings

/// The per-device "Huddle activity" preference. On by default, but nothing
/// is sent until the person allows notifications, which the app asks once
/// they've created or joined a huddle (`PushCoordinator.huddleJoined`).
@Observable
final class PushSettings {
    private static let enabledKey = "huddlepal.push.enabled"

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }
}

// MARK: - APNs environment

/// Which APNs host a device token belongs to (`device_tokens.environment`).
/// Builds signed for development (Xcode, the Simulator) get sandbox tokens;
/// TestFlight and App Store builds get production ones.
enum PushEnvironment: String {
    case sandbox
    case production

    static var current: PushEnvironment {
        #if targetEnvironment(simulator)
        return .sandbox
        #else
        let profile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
            .flatMap { try? Data(contentsOf: $0) }
        return from(provisioningProfile: profile)
        #endif
    }

    /// Reads `aps-environment` from the embedded provisioning profile (a
    /// signed plist, searched as text). App Store and TestFlight builds carry
    /// no profile: production.
    static func from(provisioningProfile data: Data?) -> PushEnvironment {
        guard let data, let text = String(data: data, encoding: .isoLatin1),
              let key = text.range(of: "<key>aps-environment</key>") else { return .production }
        let value = text[key.upperBound...].prefix(80)
        return value.contains("<string>development</string>") ? .sandbox : .production
    }
}

// MARK: - The system side

/// Notification permission and APNs registration; a protocol so tests can
/// say what the person chose.
protocol PushRegistering: AnyObject {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async -> Bool
    /// iOS answers through `AppDelegate` with the device token.
    func registerForRemoteNotifications()
}

final class SystemPushRegistrar: PushRegistering {
    /// Test runs never show the system prompt (it would hang a unit test and
    /// block a UI test) and never register.
    private var isTesting: Bool {
        UITestHooks.isUITesting || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        if isTesting { return UITestHooks.notificationsDenied ? .denied : .notDetermined }
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestAuthorization() async -> Bool {
        if isTesting { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func registerForRemoteNotifications() {
        guard !isTesting else { return }
        Task { @MainActor in UIApplication.shared.registerForRemoteNotifications() }
    }
}

// MARK: - Coordinator

/// Activity notifications from the server (new photos, comments and
/// reactions on your photos, new members), sent through APNs by the
/// send-push edge function. This owns the device side: asking for
/// permission at the right moment, registering this device's token for the
/// signed-in account (and removing it on sign-out or when turned off), and
/// opening the right huddle when a notification is tapped. Daily reminders
/// stay local (`ReminderCoordinator`).
@MainActor
@Observable
final class PushCoordinator {
    let settings: PushSettings
    /// iOS holds its delegate weakly, so it lives here.
    let centerDelegate = NotificationCenterRelay()
    private let registrar: any PushRegistering
    private let tokens: any PushTokenServiceProtocol
    private let session: AppSession
    private let environment: PushEnvironment

    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private static let tokenKey = "huddlepal.push.token"

    /// This device's APNs token, as last handed over. Kept across launches
    /// so sign-out can remove it before iOS hands it over again.
    private var deviceToken: String? {
        get { UserDefaults.standard.string(forKey: Self.tokenKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.tokenKey) }
    }

    init(
        settings: PushSettings = PushSettings(),
        registrar: any PushRegistering,
        tokens: any PushTokenServiceProtocol,
        session: AppSession,
        environment: PushEnvironment = .current
    ) {
        self.settings = settings
        self.registrar = registrar
        self.tokens = tokens
        self.session = session
        self.environment = environment
        centerDelegate.coordinator = self
    }

    /// iOS lets this device show notifications.
    var isAllowed: Bool {
        [.authorized, .provisional, .ephemeral].contains(authorizationStatus)
    }

    /// What the Settings toggle shows.
    var isOn: Bool { settings.isEnabled && isAllowed }

    /// Wanted, but turned off in iOS Settings.
    var permissionDenied: Bool { settings.isEnabled && authorizationStatus == .denied }

    func updateAuthorizationStatus() async {
        authorizationStatus = await registrar.authorizationStatus()
    }

    /// Launch, foreground, sign-in: registers with APNs if this device may
    /// show notifications. Never asks for permission.
    func refresh() async {
        await updateAuthorizationStatus()
        guard isOn, session.currentUser != nil else { return }
        registrar.registerForRemoteNotifications()
    }

    /// After creating or joining a huddle, when notifications start to
    /// matter: the first time, this is when the app asks.
    func huddleJoined() async {
        guard settings.isEnabled else { return }
        await updateAuthorizationStatus()
        if authorizationStatus == .notDetermined {
            _ = await registrar.requestAuthorization()
        }
        await refresh()
    }

    /// The token iOS handed over (`AppDelegate`), sent for the signed-in user.
    func didRegister(deviceToken data: Data) async {
        let token = Self.hex(data)
        deviceToken = token
        guard isOn, session.currentUser != nil else { return }
        // Retried on the next launch or foreground.
        try? await tokens.register(token: token, environment: environment)
    }

    /// The Settings toggle.
    func setEnabled(_ enabled: Bool) async {
        settings.isEnabled = enabled
        guard enabled else {
            await removeDeviceToken()
            return
        }
        await updateAuthorizationStatus()
        if authorizationStatus == .notDetermined {
            _ = await registrar.requestAuthorization()
        }
        await refresh()
    }

    /// The server forgets this device for this account: sign-out, or turned
    /// off. Needs the session, so sign-out calls it first.
    func removeDeviceToken() async {
        guard let token = deviceToken else { return }
        try? await tokens.unregister(token: token)
    }

    /// A tapped notification names its huddle (`huddle_id` in the payload);
    /// the shelf opens it (`HuddleListViewModel.takeNotifiedHuddle`).
    func notificationTapped(huddleID: String?) {
        guard let huddleID, let id = UUID(uuidString: huddleID) else { return }
        session.pendingHuddleID = id
    }

    static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }
}

/// UNUserNotificationCenter's delegate: activity notifications show even
/// while the app is open, and a tap opens the huddle it's about. Local
/// reminders keep iOS's default, which shows nothing in the foreground.
final class NotificationCenterRelay: NSObject, UNUserNotificationCenterDelegate {
    @MainActor weak var coordinator: PushCoordinator?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(notification.request.trigger is UNPushNotificationTrigger ? [.banner, .list, .sound] : [])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let huddleID = response.notification.request.content.userInfo["huddle_id"] as? String
        Task { @MainActor in
            self.coordinator?.notificationTapped(huddleID: huddleID)
            completionHandler()
        }
    }
}

// MARK: - App delegate

/// Receives the APNs device token, which only a UIApplicationDelegate can.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Set by HuddlePalApp once its dependencies exist; tokens only arrive
    /// after `PushCoordinator.refresh`, so it's always set by then.
    @MainActor static weak var push: PushCoordinator?

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in await Self.push?.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // No token, no pushes (e.g. no network, or no entitlement in this
        // build); the next launch or foreground tries again.
    }
}

import Foundation
import Observation
import SwiftData

// MARK: - Session

/// Observable session state the whole UI keys off. Mutated only by view
/// models (via services) — never by views.
@MainActor
@Observable
final class AppSession {
    var currentUser: User?
    /// Ids the current user has blocked — their photos/comments are hidden
    /// from the blocker's feed, archive, and detail views.
    var blockedUserIDs: Set<UUID> = []
    /// Invite code arriving via a huddlepal://join/<code> link, consumed by the
    /// Join screen.
    var pendingInviteCode: String?
    /// Authenticated but never finished the profile step — onboarding
    /// resumes there instead of at sign-in.
    var needsProfileSetup = false
    /// False until seeding + session restore finish on launch.
    var isReady = false
    /// Bumped by the live photo keyring whenever this device gains a huddle
    /// key, so photos showing the locked placeholder try to decrypt again.
    /// A display signal — the one field a service writes. Never bumps in mock
    /// mode, which has no keys.
    var photoKeysVersion = 0
}

// MARK: - Debug settings

@Observable
final class DebugSettings {
    /// Forces the reciprocity gate shut even if the user has deposited
    /// today, so the LOCKED state can be demoed on demand.
    var simulateNotPostedToday = false
}

// MARK: - Session end relay

/// Lets the Supabase client, built before the dependencies that own it,
/// reach them when the server ends the session.
@MainActor
final class SessionEndRelay {
    weak var dependencies: AppDependencies?
}

// MARK: - Dependencies

/// Composition root. Views receive this through the SwiftUI environment and
/// hand it to their view models — views themselves never call services.
/// `makeMock()` wires the seeded offline world; `makeLive(config:)` wires
/// Supabase behind the same protocols. No view knows the difference.
@MainActor
@Observable
final class AppDependencies {
    /// True when running against Supabase. Gates seeding and DEBUG tooling.
    let isLive: Bool
    let modelContainer: ModelContainer
    let engine: HuddleEngine
    let dateProvider: AppDateProvider
    let session: AppSession
    let debug: DebugSettings
    let appearance: AppearanceSettings
    /// Agreement to the Terms of Service — required before anything past
    /// the welcome cards (RootView, OnboardingViewModel).
    let terms: TermsAcceptance

    let auth: any AuthServiceProtocol
    /// Apple's confirmation sheet, shown before account deletion for the
    /// code that revokes the app's Apple tokens.
    let appleReauth: any AppleReauthenticating
    let huddleService: any HuddleServiceProtocol
    let depositService: any DepositServiceProtocol
    let mediaService: any MediaServiceProtocol
    let moderationService: any ModerationServiceProtocol
    let seeder: SeedDataService
    /// Per-user daily upload reminders (local notifications, backend-agnostic).
    /// This is the app's single notification path.
    let reminders: ReminderCoordinator

    init(
        isLive: Bool = false,
        modelContainer: ModelContainer,
        engine: HuddleEngine,
        dateProvider: AppDateProvider,
        session: AppSession,
        debug: DebugSettings,
        appearance: AppearanceSettings = AppearanceSettings(),
        terms: TermsAcceptance = TermsAcceptance(),
        auth: any AuthServiceProtocol,
        appleReauth: any AppleReauthenticating,
        huddleService: any HuddleServiceProtocol,
        depositService: any DepositServiceProtocol,
        mediaService: any MediaServiceProtocol,
        moderationService: any ModerationServiceProtocol,
        seeder: SeedDataService,
        reminders: ReminderCoordinator
    ) {
        self.isLive = isLive
        self.modelContainer = modelContainer
        self.engine = engine
        self.dateProvider = dateProvider
        self.session = session
        self.debug = debug
        self.appearance = appearance
        self.terms = terms
        self.auth = auth
        self.appleReauth = appleReauth
        self.huddleService = huddleService
        self.depositService = depositService
        self.mediaService = mediaService
        self.moderationService = moderationService
        self.seeder = seeder
        self.reminders = reminders
    }

    /// Ends the session on this device (sign-out, account deletion, or the
    /// server refusing the session) and leaves nothing of the account for
    /// whoever signs in next.
    func endSession() async {
        session.currentUser = nil
        session.needsProfileSetup = false
        session.pendingInviteCode = nil
        session.blockedUserIDs = []
        // In the same main-actor turn as clearing the session: the next
        // render swaps the main UI for onboarding, so no mounted screen
        // reads a model after it's deleted.
        try? auth.removeLocalData()
        await reminders.refresh()
    }

    /// Live only with a filled-in config, and never inside a test run: the
    /// unit tests are hosted by the app itself, and a bundled live config
    /// must not send its launch-time sync (streak recompute, key sharing)
    /// to the real backend from a test simulator.
    static func usesLiveBackend(config: BackendConfig?, environment: [String: String]) -> Bool {
        config != nil && environment["XCTestConfigurationFilePath"] == nil
    }

    static func makeMock(inMemory: Bool = false, terms: TermsAcceptance = TermsAcceptance()) -> AppDependencies {
        let container = Self.makeContainer(inMemory: inMemory)
        let context = container.mainContext
        let engine = HuddleEngine()
        let dateProvider = AppDateProvider()
        let skipLedger = SkipLedger()
        let media = MockMediaService()
        let session = AppSession()

        return AppDependencies(
            modelContainer: container,
            engine: engine,
            dateProvider: dateProvider,
            session: session,
            debug: DebugSettings(),
            terms: terms,
            auth: MockAuthService(context: context),
            appleReauth: MockAppleReauthenticator(),
            huddleService: MockHuddleService(
                context: context, engine: engine, skipLedger: skipLedger, dateProvider: dateProvider
            ),
            depositService: MockDepositService(context: context, engine: engine),
            mediaService: media,
            moderationService: MockModerationService(session: session),
            seeder: SeedDataService(
                context: context,
                engine: engine,
                media: media,
                skipLedger: skipLedger,
                dateProvider: dateProvider
            ),
            reminders: ReminderCoordinator(
                settings: ReminderSettings(),
                scheduler: DailyReminderScheduler(),
                session: session,
                engine: engine,
                dateProvider: dateProvider
            )
        )
    }

    /// Supabase-backed wiring. Same protocols, same views, real backend.
    static func makeLive(config: BackendConfig) -> AppDependencies {
        let container = Self.makeContainer(inMemory: false)
        let context = container.mainContext
        let engine = HuddleEngine()
        let dateProvider = AppDateProvider()
        // A mock-day offset left over from demo sessions must never bend
        // time against the real backend.
        dateProvider.reset()

        let relay = SessionEndRelay()
        let client = SupabaseClient(config: config) {
            Task { @MainActor in await relay.dependencies?.endSession() }
        }
        let store = SupabaseStore(context: context)
        let session = AppSession()
        let keyring = LivePhotoKeyring(client: client, session: session)
        let media = LiveMediaService(client: client, keyring: keyring)

        let dependencies = AppDependencies(
            isLive: true,
            modelContainer: container,
            engine: engine,
            dateProvider: dateProvider,
            session: session,
            debug: DebugSettings(),
            auth: LiveAuthService(client: client, store: store, keyring: keyring, media: media, config: config),
            appleReauth: SystemAppleReauthenticator(),
            huddleService: LiveHuddleService(
                client: client, store: store, engine: engine, dateProvider: dateProvider, keyring: keyring
            ),
            depositService: LiveDepositService(client: client, store: store, keyring: keyring),
            mediaService: media,
            moderationService: LiveModerationService(client: client, session: session, keyring: keyring),
            // Constructed but never invoked in live mode (RootViewModel
            // gates seeding on isLive).
            seeder: SeedDataService(
                context: context,
                engine: engine,
                media: media,
                skipLedger: SkipLedger(),
                dateProvider: dateProvider
            ),
            reminders: ReminderCoordinator(
                settings: ReminderSettings(),
                scheduler: DailyReminderScheduler(),
                session: session,
                engine: engine,
                dateProvider: dateProvider
            )
        )
        relay.dependencies = dependencies
        return dependencies
    }

    private static func makeContainer(inMemory: Bool) -> ModelContainer {
        let schema = Schema(HuddleSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // A schema mismatch from an old dev build is the only realistic
            // cause; fall back to a fresh in-memory store rather than crash.
            return try! ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
            )
        }
    }
}

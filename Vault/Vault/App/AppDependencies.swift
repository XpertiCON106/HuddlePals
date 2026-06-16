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
    /// Invite code arriving via a vault://join/<code> link, consumed by the
    /// Join screen.
    var pendingInviteCode: String?
    /// Authenticated but never finished the profile step — onboarding
    /// resumes there instead of at sign-in.
    var needsProfileSetup = false
    /// False until seeding + session restore finish on launch.
    var isReady = false
}

// MARK: - Debug settings

@Observable
final class DebugSettings {
    /// Forces the reciprocity gate shut even if the user has deposited
    /// today, so the LOCKED state can be demoed on demand.
    var simulateNotPostedToday = false
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
    let engine: VaultEngine
    let dateProvider: AppDateProvider
    let session: AppSession
    let debug: DebugSettings
    let appearance: AppearanceSettings

    let auth: any AuthServiceProtocol
    let vaultService: any VaultServiceProtocol
    let depositService: any DepositServiceProtocol
    let mediaService: any MediaServiceProtocol
    let notificationService: any NotificationServiceProtocol
    let seeder: SeedDataService
    /// Per-user daily upload reminders (local notifications, backend-agnostic).
    let reminders: ReminderCoordinator

    init(
        isLive: Bool = false,
        modelContainer: ModelContainer,
        engine: VaultEngine,
        dateProvider: AppDateProvider,
        session: AppSession,
        debug: DebugSettings,
        appearance: AppearanceSettings = AppearanceSettings(),
        auth: any AuthServiceProtocol,
        vaultService: any VaultServiceProtocol,
        depositService: any DepositServiceProtocol,
        mediaService: any MediaServiceProtocol,
        notificationService: any NotificationServiceProtocol,
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
        self.auth = auth
        self.vaultService = vaultService
        self.depositService = depositService
        self.mediaService = mediaService
        self.notificationService = notificationService
        self.seeder = seeder
        self.reminders = reminders
    }

    static func makeMock(inMemory: Bool = false) -> AppDependencies {
        let container = Self.makeContainer(inMemory: inMemory)
        let context = container.mainContext
        let engine = VaultEngine()
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
            auth: MockAuthService(context: context),
            vaultService: MockVaultService(context: context, engine: engine, skipLedger: skipLedger),
            depositService: MockDepositService(context: context, engine: engine),
            mediaService: media,
            notificationService: MockNotificationService(),
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
        let engine = VaultEngine()
        let dateProvider = AppDateProvider()
        // A mock-day offset left over from demo sessions must never bend
        // time against the real backend.
        dateProvider.reset()

        let client = SupabaseClient(config: config)
        let store = SupabaseStore(context: context)
        let media = LiveMediaService(client: client)
        let session = AppSession()

        return AppDependencies(
            isLive: true,
            modelContainer: container,
            engine: engine,
            dateProvider: dateProvider,
            session: session,
            debug: DebugSettings(),
            auth: LiveAuthService(client: client, store: store),
            vaultService: LiveVaultService(client: client, store: store, engine: engine),
            depositService: LiveDepositService(client: client, store: store),
            mediaService: media,
            notificationService: LiveNotificationService(),
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
    }

    private static func makeContainer(inMemory: Bool) -> ModelContainer {
        let schema = Schema(VaultSchema.models)
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

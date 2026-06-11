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
    var activeVault: Vault?
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
///
/// TODO: BACKEND — add `static func live()` that wires Supabase-backed
/// implementations of the same protocols; nothing else changes.
@MainActor
@Observable
final class AppDependencies {
    let modelContainer: ModelContainer
    let engine: VaultEngine
    let dateProvider: AppDateProvider
    let session: AppSession
    let debug: DebugSettings

    let auth: any AuthServiceProtocol
    let vaultService: any VaultServiceProtocol
    let depositService: any DepositServiceProtocol
    let mediaService: any MediaServiceProtocol
    let notificationService: any NotificationServiceProtocol
    let seeder: SeedDataService

    init(
        modelContainer: ModelContainer,
        engine: VaultEngine,
        dateProvider: AppDateProvider,
        session: AppSession,
        debug: DebugSettings,
        auth: any AuthServiceProtocol,
        vaultService: any VaultServiceProtocol,
        depositService: any DepositServiceProtocol,
        mediaService: any MediaServiceProtocol,
        notificationService: any NotificationServiceProtocol,
        seeder: SeedDataService
    ) {
        self.modelContainer = modelContainer
        self.engine = engine
        self.dateProvider = dateProvider
        self.session = session
        self.debug = debug
        self.auth = auth
        self.vaultService = vaultService
        self.depositService = depositService
        self.mediaService = mediaService
        self.notificationService = notificationService
        self.seeder = seeder
    }

    static func makeMock(inMemory: Bool = false) -> AppDependencies {
        let schema = Schema(VaultSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // A schema mismatch from an old dev build is the only realistic
            // cause; fall back to a fresh in-memory store rather than crash.
            container = try! ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
            )
        }

        let context = container.mainContext
        let engine = VaultEngine()
        let dateProvider = AppDateProvider()
        let skipLedger = SkipLedger()
        let media = MockMediaService()

        return AppDependencies(
            modelContainer: container,
            engine: engine,
            dateProvider: dateProvider,
            session: AppSession(),
            debug: DebugSettings(),
            auth: MockAuthService(context: context),
            vaultService: MockVaultService(context: context, engine: engine, skipLedger: skipLedger),
            depositService: MockDepositService(context: context, engine: engine, media: media),
            mediaService: media,
            notificationService: MockNotificationService(),
            seeder: SeedDataService(
                context: context,
                engine: engine,
                media: media,
                skipLedger: skipLedger,
                dateProvider: dateProvider
            )
        )
    }
}

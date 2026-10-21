import Foundation
import SwiftData
import UserNotifications
import XCTest

@testable import HuddlePal

/// QA-10: after sign-out or account deletion nothing the account could see
/// stays on the device, and nobody signed out gets reminders.
@MainActor
final class SignOutTests: XCTestCase {
    override func tearDown() async throws {
        StubURLProtocol.reset()
        KeychainStore.delete(key: LiveStub.sessionKey)
        try await super.tearDown()
    }

    func testLiveSignOutForgetsEverythingTheAccountCouldSee() async throws {
        let container = try LiveStub.inMemoryContainer()
        let context = container.mainContext
        let store = SupabaseStore(context: context)
        let client = try await LiveStub.signedInClient()
        let session = AppSession()
        let keyring = LivePhotoKeyring(client: client, session: session, identityStore: InMemoryIdentityStore())
        let media = LiveMediaService(client: client, keyring: keyring)
        let auth = LiveAuthService(client: client, store: store, keyring: keyring, media: media, config: LiveStub.config)

        let friend = User(displayName: "Friend", avatarColorHex: "0091FF", bio: "private bio")
        context.insert(friend)
        let huddle = try store.apply(HuddleDTO(
            id: UUID(), name: "Family", emoji: "🏔", inviteCode: "FAM123", notificationHour: 19, streakCount: 3
        ))
        context.insert(Deposit(huddle: huddle, author: friend, localImagePath: "Media/x/y.jpg", caption: "at home", dayKey: "2026-10-20"))
        try store.save()
        let avatar = media.imageURL(for: "Media/avatars/friend/a.jpg")
        try FileManager.default.createDirectory(at: avatar.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("plaintext jpeg".utf8).write(to: avatar)

        try auth.removeLocalData()

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<User>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Huddle>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Deposit>()), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: avatar.path), "cached profile photos are plaintext")
    }

    func testTheLiveClientKeepsNoHTTPCache() {
        // URLSession.shared would keep rows and photos under Library/Caches.
        XCTAssertNil(SupabaseClient.makeURLSession().configuration.urlCache)
    }

    func testRemindersAreCancelledWhenNobodyIsSignedIn() async {
        let scheduler = SchedulerSpy()
        let settings = ReminderSettings()
        let wasEnabled = settings.isEnabled
        defer { settings.isEnabled = wasEnabled }
        settings.isEnabled = true
        let session = AppSession()
        let coordinator = ReminderCoordinator(
            settings: settings, scheduler: scheduler, session: session,
            engine: HuddleEngine(), dateProvider: AppDateProvider()
        )

        await coordinator.refresh()
        XCTAssertEqual(scheduler.cancelCalls, 1)
        XCTAssertEqual(scheduler.rescheduleCalls, 0, "a signed-out device must not keep nudging")

        session.currentUser = User(displayName: "Me", avatarColorHex: "E5484D")
        await coordinator.refresh()
        XCTAssertEqual(scheduler.rescheduleCalls, 1)
    }
}

private final class SchedulerSpy: ReminderScheduling {
    private(set) var cancelCalls = 0
    private(set) var rescheduleCalls = 0

    func authorizationStatus() async -> UNAuthorizationStatus { .authorized }
    func requestAuthorization() async -> Bool { true }
    func cancelAll() { cancelCalls += 1 }
    func reschedule(enabled: Bool, hour: Int, minute: Int, suppressToday: Bool, calendar: Calendar, now: Date) async {
        rescheduleCalls += 1
    }
}

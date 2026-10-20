import Foundation
import SwiftData

/// User-generated-content safeguards (App Store guideline 1.2): reporting a
/// deposit and blocking a member. Blocking is presentational only — it hides
/// the blocked user's photos and comments from the blocker; it never changes
/// huddle membership or the group streak.
@MainActor
protocol ModerationServiceProtocol: AnyObject {
    func report(deposit: Deposit, reason: String?) async throws
    func block(_ user: User) async throws
    func unblock(_ user: User) async throws
    /// The ids the current user has blocked.
    func blockedUserIDs() async throws -> Set<UUID>
}

// MARK: - Mock

/// Offline stand-in: reports are accepted (and logged in DEBUG); blocks are
/// persisted per-user in UserDefaults so the demo behaves like the real thing.
@MainActor
final class MockModerationService: ModerationServiceProtocol {
    private let session: AppSession
    private static let blocksKeyPrefix = "huddlepal.mock.blocks."

    init(session: AppSession) {
        self.session = session
    }

    private var blocksKey: String? {
        session.currentUser.map { Self.blocksKeyPrefix + $0.id.uuidString }
    }

    func report(deposit: Deposit, reason: String?) async throws {
        #if DEBUG
        print("[MockModeration] report deposit \(deposit.id) reason: \(reason ?? "—")")
        #endif
    }

    func block(_ user: User) async throws {
        guard let key = blocksKey else { return }
        var ids = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        ids.insert(user.id.uuidString)
        UserDefaults.standard.set(Array(ids), forKey: key)
    }

    func unblock(_ user: User) async throws {
        guard let key = blocksKey else { return }
        var ids = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        ids.remove(user.id.uuidString)
        UserDefaults.standard.set(Array(ids), forKey: key)
    }

    func blockedUserIDs() async throws -> Set<UUID> {
        guard let key = blocksKey else { return [] }
        return Set((UserDefaults.standard.stringArray(forKey: key) ?? []).compactMap(UUID.init))
    }
}

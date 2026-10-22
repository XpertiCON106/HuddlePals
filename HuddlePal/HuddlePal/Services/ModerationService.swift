import Foundation
import SwiftData

/// User-generated-content safeguards (App Store guideline 1.2): reporting a
/// deposit, a comment or a member's profile, and blocking a member. Blocking
/// is presentational only — it hides
/// the blocked user's photos and comments from the blocker; it never changes
/// huddle membership or the group streak.
@MainActor
protocol ModerationServiceProtocol: AnyObject {
    func report(deposit: Deposit, reason: String?) async throws
    /// One comment. The report names it, so the operator can find it.
    func report(comment: Comment) async throws
    /// A member's profile: name, bio and profile photos.
    func report(user: User) async throws
    func block(_ user: User) async throws
    func unblock(_ user: User) async throws
    /// The ids the current user has blocked.
    func blockedUserIDs() async throws -> Set<UUID>
}

/// What the app says once a report has gone through.
enum ReportFeedback {
    static let title = "Thanks for reporting"
    static let message = "We review every report within 24 hours and remove anything that breaks our Terms."
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

    func report(comment: Comment) async throws {
        #if DEBUG
        print("[MockModeration] report comment \(comment.id)")
        #endif
    }

    func report(user: User) async throws {
        #if DEBUG
        print("[MockModeration] report user \(user.id)")
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

    /// Whom any mock account has blocked, for the join check the server
    /// makes in redeem_huddle_invite.
    static func blockedIDs(by blockerID: UUID) -> Set<UUID> {
        Set((UserDefaults.standard.stringArray(forKey: blocksKeyPrefix + blockerID.uuidString) ?? []).compactMap(UUID.init))
    }
}

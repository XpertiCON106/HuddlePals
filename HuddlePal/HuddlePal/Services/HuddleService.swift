import Foundation
import SwiftData

enum HuddleServiceError: LocalizedError {
    case inviteCodeNotFound
    case alreadyMember
    case notAMember
    case huddleFull
    /// Too many wrong invite codes recently (the server allows 10 an hour).
    case tooManyAttempts

    var errorDescription: String? {
        switch self {
        case .inviteCodeNotFound: "No huddle found for that code. Double-check it and try again."
        case .alreadyMember: "You're already a member of this huddle."
        case .notAMember: "You're not a member of this huddle."
        case .huddleFull: "This huddle already has 8 members — that's the limit."
        case .tooManyAttempts: "Too many codes that didn't match. Wait an hour, then try again."
        }
    }
}

@MainActor
protocol HuddleServiceProtocol: AnyObject {
    func huddles(for user: User) async throws -> [Huddle]
    func createHuddle(name: String, emoji: String, keeper: User) async throws -> Huddle
    func joinHuddle(inviteCode: String, user: User) async throws -> Huddle
    func leaveHuddle(_ huddle: Huddle, user: User) async throws
    /// Skip-token usage per dayKey, consumed by streak math.
    func skipRecords(for huddle: Huddle) async throws -> [String: Set<UUID>]
    func spendSkipToken(membership: Membership, dayKey: String) async throws
    func updateNotificationHour(_ hour: Int, for huddle: Huddle) async throws
    /// Recomputes and persists the group streak. Called on launch and after
    /// every deposit.
    func recomputeStreak(for huddle: Huddle, now: Date) async throws
}

// MARK: - Skip ledger

/// In-memory record of who spent a skip token on which day. Seeded with
/// historical skips so streak math has realistic data.
///
/// TODO: BACKEND — replace with a `skips` table (huddle_id, user_id, day_key)
/// so skip usage survives reinstall and syncs across members.
final class SkipLedger {
    private var records: [UUID: [String: Set<UUID>]] = [:]

    func recordSkip(huddleID: UUID, dayKey: String, userID: UUID) {
        records[huddleID, default: [:]][dayKey, default: []].insert(userID)
    }

    func skips(for huddleID: UUID) -> [String: Set<UUID>] {
        records[huddleID] ?? [:]
    }

    func removeAll() {
        records.removeAll()
    }
}

// MARK: - Mock

@MainActor
final class MockHuddleService: HuddleServiceProtocol {
    private let context: ModelContext
    private let engine: HuddleEngine
    private let skipLedger: SkipLedger
    /// Join days follow the (debug-shiftable) app clock, like deposits.
    private let dateProvider: DateProviding

    init(context: ModelContext, engine: HuddleEngine, skipLedger: SkipLedger, dateProvider: DateProviding) {
        self.context = context
        self.engine = engine
        self.skipLedger = skipLedger
        self.dateProvider = dateProvider
    }

    private var todayKey: String {
        engine.todayKey(now: dateProvider.now)
    }

    func huddles(for user: User) async throws -> [Huddle] {
        // TODO: BACKEND — fetch huddle memberships for the authed user from
        // Supabase (`memberships` joined to `huddles`), then merge into the
        // local SwiftData cache.
        user.memberships
            .compactMap(\.huddle)
            .sorted { $0.createdAt < $1.createdAt }
    }

    func createHuddle(name: String, emoji: String, keeper: User) async throws -> Huddle {
        // TODO: BACKEND — insert huddle + keeper membership in one RPC so
        // invite-code uniqueness is enforced server-side.
        let huddle = Huddle(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            emoji: emoji,
            inviteCode: try uniqueInviteCode()
        )
        context.insert(huddle)
        let membership = Membership(user: keeper, huddle: huddle, role: .keeper, joinedDayKey: todayKey)
        context.insert(membership)
        try context.save()
        return huddle
    }

    func joinHuddle(inviteCode: String, user: User) async throws -> Huddle {
        // TODO: BACKEND — call a join RPC that validates the code and
        // enforces the 8-member cap atomically.
        let code = inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let huddles = try context.fetch(FetchDescriptor<Huddle>())
        guard let huddle = huddles.first(where: { $0.inviteCode.uppercased() == code }) else {
            throw HuddleServiceError.inviteCodeNotFound
        }
        guard !huddle.memberships.contains(where: { $0.user?.id == user.id }) else {
            throw HuddleServiceError.alreadyMember
        }
        let membership = Membership(user: user, huddle: huddle, joinedDayKey: todayKey)
        context.insert(membership)
        try context.save()
        return huddle
    }

    func leaveHuddle(_ huddle: Huddle, user: User) async throws {
        // TODO: BACKEND — delete the membership row; server reassigns the
        // keeper role if the keeper leaves.
        guard let membership = huddle.memberships.first(where: { $0.user?.id == user.id }) else {
            throw HuddleServiceError.notAMember
        }
        context.delete(membership)
        try context.save()
    }

    func skipRecords(for huddle: Huddle) async throws -> [String: Set<UUID>] {
        skipLedger.skips(for: huddle.id)
    }

    func updateNotificationHour(_ hour: Int, for huddle: Huddle) async throws {
        huddle.notificationHour = hour
        try context.save()
    }

    func spendSkipToken(membership: Membership, dayKey: String) async throws {
        guard membership.skipTokensRemaining > 0,
              let huddleID = membership.huddle?.id,
              let userID = membership.user?.id else { return }
        membership.skipTokensRemaining -= 1
        skipLedger.recordSkip(huddleID: huddleID, dayKey: dayKey, userID: userID)
        try context.save()
    }

    func recomputeStreak(for huddle: Huddle, now: Date) async throws {
        // TODO: BACKEND — streaks should be computed server-side (edge
        // function on deposit insert) so all members agree; this local
        // recompute then becomes a cache.
        let snapshots = huddle.deposits.compactMap(\.snapshot)
        let result = engine.computeStreak(
            memberIDs: huddle.memberIDs,
            joinedDayKeys: huddle.memberJoinDayKeys(using: engine),
            deposits: snapshots,
            skips: skipLedger.skips(for: huddle.id),
            now: now
        )
        huddle.streakCount = result.count
        huddle.lastStreakDate = result.lastCompleteDayKey.flatMap { engine.date(fromDayKey: $0) }
        try context.save()
    }

    private func uniqueInviteCode() throws -> String {
        let existing = Set(try context.fetch(FetchDescriptor<Huddle>()).map(\.inviteCode))
        for _ in 0..<50 {
            let code = HuddleEngine.generateInviteCode()
            if !existing.contains(code) { return code }
        }
        return HuddleEngine.generateInviteCode(length: 8)
    }
}

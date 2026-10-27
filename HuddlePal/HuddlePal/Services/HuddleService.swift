import Foundation
import SwiftData

enum HuddleServiceError: LocalizedError {
    case inviteCodeNotFound
    /// A 6-character code from before invites carried a secret.
    case inviteCodeOutdated
    /// The server took the code, but its sealed key didn't open.
    case inviteUnusable
    /// The huddle's invite code can't be shown on this device right now.
    case inviteUnavailable
    case alreadyMember
    case notAMember
    case notKeeper
    /// Its keeper is on the free plan: 4 members.
    case huddleFullFree
    /// Its keeper is on the free plan, and it isn't one of the 3 huddles
    /// they've kept longest.
    case invitesPaused
    /// Its keeper has Plus: 10 members, the most a huddle can have.
    case huddleAtMaximum
    /// The person joining is in 25 huddles already.
    case tooManyHuddles
    /// Creating one more: 3 huddles kept on the free plan.
    case huddleLimitFree
    /// Creating one more: 10 huddles kept with Plus.
    case huddleLimitPlus
    /// Someone in the huddle has blocked the person joining.
    case cannotJoin
    /// Too many wrong invite codes recently (the server allows 10 an hour).
    case tooManyAttempts

    var errorDescription: String? {
        switch self {
        case .inviteCodeNotFound: "No huddle found for that code. Double-check it and try again."
        case .inviteCodeOutdated: "That's an older invite code. Ask someone in the huddle to send you the current one — it's under Invite code in the huddle's settings."
        case .inviteUnusable: "This invite code isn't working. Ask someone in the huddle for a new one."
        case .inviteUnavailable: "The invite code can't be shown right now. Check your connection and try again."
        case .alreadyMember: "You're already a member of this huddle."
        case .notAMember: "You're not a member of this huddle."
        case .notKeeper: "Only the huddle's keeper can do that."
        case .huddleFullFree: "This huddle is full for now — free huddles hold 4 people. Its keeper can make room or get HuddlePals+ for up to 10."
        case .invitesPaused: "This huddle isn't taking new members right now. Ask its keeper."
        case .huddleAtMaximum: "This huddle has 10 members — the most a huddle can have."
        case .tooManyHuddles: "You're in 25 huddles — the most anyone can join. Leave one to join another."
        case .huddleLimitFree: "You keep 3 huddles, the most on the free plan. Leave one or get HuddlePals+ to keep up to 10."
        case .huddleLimitPlus: "You keep 10 huddles — the most anyone can keep."
        case .cannotJoin: "You can't join this huddle."
        case .tooManyAttempts: "Too many codes that didn't match. Wait an hour, then try again."
        }
    }

    init(_ refusal: HuddleEngine.JoinRefusal) {
        switch refusal {
        case .freeLimit: self = .huddleFullFree
        case .invitesPaused: self = .invitesPaused
        case .maxMembers: self = .huddleAtMaximum
        case .membershipLimit: self = .tooManyHuddles
        }
    }

    init(_ refusal: HuddleEngine.CreateRefusal) {
        switch refusal {
        case .freeLimit: self = .huddleLimitFree
        case .plusLimit: self = .huddleLimitPlus
        }
    }

    /// The join refusal a server error names, if it names one. Checked
    /// before the generic "blocked" (someone blocked you), which every
    /// limit's code also contains so that builds from before Plus say
    /// "You can't join this huddle."
    init?(serverJoinMessage message: String) {
        guard let refusal = HuddleEngine.JoinRefusal.allCases.first(where: { message.contains($0.rawValue) }) else {
            return nil
        }
        self.init(refusal)
    }

    init?(serverCreateMessage message: String) {
        guard let refusal = HuddleEngine.CreateRefusal.allCases.first(where: { message.contains($0.rawValue) }) else {
            return nil
        }
        self.init(refusal)
    }
}

/// Whether a huddle takes new members right now, and if not why: the
/// server's huddle_join_status. Settings explains a closed huddle instead of
/// showing an invite code that would fail.
struct HuddleJoinStatus: Equatable {
    let refusal: HuddleEngine.JoinRefusal?
    let memberCount: Int
    let memberCap: Int

    var accepting: Bool { refusal == nil }
}

/// Someone waiting for a huddle's key whose key code nobody on this device
/// has confirmed yet: they joined with an old code, or their key changed.
/// `code` is computed here from the public key the server lists for them.
struct KeyCheck: Identifiable, Hashable {
    let userID: UUID
    /// Base64, as `user_keys` holds it.
    let publicKey: String
    let code: String

    var id: String { "\(userID.uuidString):\(publicKey)" }
}

@MainActor
protocol HuddleServiceProtocol: AnyObject {
    func huddles(for user: User) async throws -> [Huddle]
    func createHuddle(name: String, emoji: String, keeper: User) async throws -> Huddle
    /// Joins with an invite code (`InviteCode`; spaces, dashes and case
    /// don't matter). Live, the code also carries the huddle key, so every
    /// photo opens at once. An old 6-character code throws
    /// `.inviteCodeOutdated`.
    func joinHuddle(inviteCode: String, user: User) async throws -> Huddle
    /// The huddle's code, to show and share. A huddle still on an old
    /// secret-less code gets a new-format one, which retires the old. nil
    /// when it can't be shown on this device right now.
    func inviteCode(for huddle: Huddle) async throws -> InviteCode?
    /// Keeper only: a new code; the old one stops working at once.
    func resetInviteCode(for huddle: Huddle, by user: User) async throws -> InviteCode
    /// Whether the huddle takes new members, by its keeper's plan. nil when
    /// it can't be known right now (offline, or a server from before Plus).
    func joinStatus(for huddle: Huddle) async -> HuddleJoinStatus?
    func leaveHuddle(_ huddle: Huddle, user: User) async throws
    /// Keeper only: deletes the huddle for everyone, with every photo and
    /// video in it. Its members go at once; the huddle itself leaves this
    /// device with the next refresh of the shelf (`huddles(for:)`), after
    /// its screens have closed.
    func deleteHuddle(_ huddle: Huddle, by user: User) async throws
    /// Skip-token usage per dayKey, consumed by streak math.
    func skipRecords(for huddle: Huddle) async throws -> [String: Set<UUID>]
    func spendSkipToken(membership: Membership, dayKey: String) async throws
    func updateNotificationHour(_ hour: Int, for huddle: Huddle) async throws
    /// Recomputes and persists the group streak. Called on launch and after
    /// every deposit.
    func recomputeStreak(for huddle: Huddle, now: Date) async throws
    /// Members waiting for this huddle's key until someone checks their key
    /// code, as of the last time the huddle was opened. None in mock mode,
    /// which has no keys.
    func keyChecks(for huddle: Huddle) async -> [KeyCheck]
    /// The member's own phone shows the same code: share the huddle key with
    /// them, and trust that key from now on.
    func confirmKeyCheck(_ check: KeyCheck, in huddle: Huddle) async throws
    /// This account's key code, for members checking it. nil in mock mode.
    func ownKeyCode() async -> String?
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
    /// Who has Plus: the caps below refuse what the server's would.
    private let plans: MockPlanLedger

    init(
        context: ModelContext,
        engine: HuddleEngine,
        skipLedger: SkipLedger,
        dateProvider: DateProviding,
        plans: MockPlanLedger
    ) {
        self.context = context
        self.engine = engine
        self.skipLedger = skipLedger
        self.dateProvider = dateProvider
        self.plans = plans
    }

    private var todayKey: String {
        engine.todayKey(now: dateProvider.now)
    }

    func huddles(for user: User) async throws -> [Huddle] {
        // TODO: BACKEND — fetch huddle memberships for the authed user from
        // Supabase (`memberships` joined to `huddles`), then merge into the
        // local SwiftData cache.
        // A huddle nobody is in any more (its keeper deleted it) goes, with
        // its files.
        for huddle in try context.fetch(FetchDescriptor<Huddle>()) where huddle.memberships.isEmpty {
            MockMediaService().deleteFiles(of: huddle)
            context.delete(huddle)
        }
        try context.save()
        return user.memberships
            .compactMap(\.huddle)
            .sorted { $0.createdAt < $1.createdAt }
    }

    func createHuddle(name: String, emoji: String, keeper: User) async throws -> Huddle {
        // TODO: BACKEND — insert huddle + keeper membership in one RPC so
        // invite-code uniqueness is enforced server-side.
        // create_huddle's cap: huddles kept, inherited ones included.
        let kept = keeper.memberships.filter { $0.role == .keeper }.count
        if let refusal = HuddleEngine.createRefusal(
            keptHuddles: kept, isPremium: plans.hasPlus(keeper.id)
        ) {
            throw HuddleServiceError(refusal)
        }
        let huddle = Huddle(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            emoji: emoji,
            inviteCode: try uniqueInviteCode().compact
        )
        context.insert(huddle)
        let membership = Membership(
            user: keeper, huddle: huddle, role: .keeper, joinedDayKey: todayKey, keeperSince: .now
        )
        context.insert(membership)
        try context.save()
        return huddle
    }

    func joinHuddle(inviteCode: String, user: User) async throws -> Huddle {
        // The mock stores the whole code; it has no server to hide the
        // secret from. Same rules as redeem_huddle_invite otherwise.
        guard let code = InviteCode(inviteCode) else {
            throw InviteCode.isLegacy(inviteCode) ? HuddleServiceError.inviteCodeOutdated : .inviteCodeNotFound
        }
        let huddles = try context.fetch(FetchDescriptor<Huddle>())
        guard let huddle = huddles.first(where: { InviteCode($0.inviteCode) == code }) else {
            throw HuddleServiceError.inviteCodeNotFound
        }
        guard !huddle.memberships.contains(where: { $0.user?.id == user.id }) else {
            throw HuddleServiceError.alreadyMember
        }
        if let refusal = joinRefusal(for: huddle, joiner: user) {
            throw HuddleServiceError(refusal)
        }
        let blockers = huddle.memberships.compactMap { $0.user?.id }
        guard !blockers.contains(where: { MockModerationService.blockedIDs(by: $0).contains(user.id) }) else {
            throw HuddleServiceError.cannotJoin
        }
        let membership = Membership(user: user, huddle: huddle, joinedDayKey: todayKey)
        context.insert(membership)
        try context.save()
        return huddle
    }

    func inviteCode(for huddle: Huddle) async throws -> InviteCode? {
        if let code = InviteCode(huddle.inviteCode) { return code }
        // A store from before invites carried a secret: upgrade, as live does.
        let code = try uniqueInviteCode()
        huddle.inviteCode = code.compact
        try context.save()
        return code
    }

    func resetInviteCode(for huddle: Huddle, by user: User) async throws -> InviteCode {
        guard huddle.memberships.contains(where: { $0.user?.id == user.id && $0.role == .keeper }) else {
            throw HuddleServiceError.notKeeper
        }
        let code = try uniqueInviteCode()
        huddle.inviteCode = code.compact
        try context.save()
        return code
    }

    func leaveHuddle(_ huddle: Huddle, user: User) async throws {
        // Live: deleting the membership row fires the server's
        // memberships_after_delete trigger, which hands the keeper role to
        // the longest-standing remaining member. Mirrored here.
        guard let membership = huddle.memberships.first(where: { $0.user?.id == user.id }) else {
            throw HuddleServiceError.notAMember
        }
        let remaining = huddle.sortedMemberships.filter { $0.id != membership.id }
        if membership.role == .keeper, !remaining.contains(where: { $0.role == .keeper }),
           let successor = remaining.min(by: { $0.joinedAt < $1.joinedAt }) {
            successor.role = .keeper
            successor.keeperSince = .now
        }
        context.delete(membership)
        try context.save()
    }

    func deleteHuddle(_ huddle: Huddle, by user: User) async throws {
        // Live: the delete-huddle function deletes the rows and the files,
        // keeping anything reported for the operator. Offline there's no
        // operator: everyone is removed, and the next shelf refresh deletes
        // the huddle and its files.
        guard huddle.memberships.contains(where: { $0.user?.id == user.id && $0.role == .keeper }) else {
            throw HuddleServiceError.notKeeper
        }
        for membership in huddle.memberships {
            context.delete(membership)
        }
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

    // The offline world has no keys to share or check.
    func keyChecks(for huddle: Huddle) async -> [KeyCheck] { [] }
    func confirmKeyCheck(_ check: KeyCheck, in huddle: Huddle) async throws {}
    func ownKeyCode() async -> String? { nil }

    func joinStatus(for huddle: Huddle) async -> HuddleJoinStatus? {
        let (keeperIsPremium, keeperRank) = keeperPlan(of: huddle)
        let rule = HuddleEngine.joinRule(
            memberCount: huddle.memberships.count, keeperIsPremium: keeperIsPremium, keeperRank: keeperRank
        )
        return HuddleJoinStatus(refusal: rule.refusal, memberCount: huddle.memberships.count, memberCap: rule.memberCap)
    }

    /// The server's join rules (huddle_join_rule, then the joiner's
    /// 25-huddle limit), on the offline world: the keeper's plan decides.
    private func joinRefusal(for huddle: Huddle, joiner: User) -> HuddleEngine.JoinRefusal? {
        let (keeperIsPremium, keeperRank) = keeperPlan(of: huddle)
        return HuddleEngine.joinRefusal(
            memberCount: huddle.memberships.count,
            keeperIsPremium: keeperIsPremium,
            keeperRank: keeperRank,
            joinerHuddleCount: joiner.memberships.count
        )
    }

    /// Whether the huddle's keeper has Plus, and its place in their queue of
    /// huddles kept (nil without a keeper).
    private func keeperPlan(of huddle: Huddle) -> (isPremium: Bool, rank: Int?) {
        let keeper = huddle.memberships.first { $0.role == .keeper }?.user
        let kept = (keeper?.memberships ?? []).filter { $0.role == .keeper }.compactMap { membership in
            membership.huddle.map { (huddleID: $0.id, keeperSince: membership.keptSince) }
        }
        return (plans.hasPlus(keeper?.id), HuddleEngine.keeperRank(of: huddle.id, among: kept))
    }

    /// Unique by lookup part, like `huddles.invite_code`.
    private func uniqueInviteCode() throws -> InviteCode {
        let taken = Set(try context.fetch(FetchDescriptor<Huddle>()).map { String($0.inviteCode.prefix(InviteCode.lookupLength)) })
        var code = InviteCode.generate()
        while taken.contains(code.lookup) { code = InviteCode.generate() }
        return code
    }
}

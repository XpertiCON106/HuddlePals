import Foundation
import SwiftData

@MainActor
final class LiveHuddleService: HuddleServiceProtocol {
    private let client: SupabaseClient
    private let store: SupabaseStore
    private let engine: HuddleEngine
    private let dateProvider: DateProviding
    private let keyring: LivePhotoKeyring

    init(
        client: SupabaseClient,
        store: SupabaseStore,
        engine: HuddleEngine,
        dateProvider: DateProviding,
        keyring: LivePhotoKeyring
    ) {
        self.client = client
        self.store = store
        self.engine = engine
        self.dateProvider = dateProvider
        self.keyring = keyring
    }

    /// The device's local today — sent as the new member's join day, which
    /// the server trusts within ±1 day (`client_day_key`).
    private var todayKey: String {
        engine.todayKey(now: dateProvider.now)
    }

    func isMember(of huddle: Huddle, user: User) async throws -> Bool {
        let rows: [MembershipDTO] = try await client.select("memberships", query: [
            URLQueryItem(name: "huddle_id", value: "eq.\(huddle.id.uuidString)"),
            URLQueryItem(name: "user_id", value: "eq.\(user.id.uuidString)"),
        ])
        return !rows.isEmpty
    }

    func huddles(for user: User) async throws -> [Huddle] {
        let mine: [MembershipDTO] = try await client.select("memberships", query: [
            URLQueryItem(name: "user_id", value: "eq.\(user.id.uuidString)"),
        ])
        let huddleIDs = mine.map(\.huddleId)
        try store.pruneHuddles(keeping: Set(huddleIDs))
        guard !huddleIDs.isEmpty else {
            try store.save()
            return []
        }

        let huddleDTOs: [HuddleDTO] = try await client.select("huddles", query: [
            URLQueryItem(name: "id", value: huddleIDs.postgrestInList),
        ])
        let allMemberships: [MembershipDTO] = try await client.select("memberships", query: [
            URLQueryItem(name: "huddle_id", value: huddleIDs.postgrestInList),
        ])
        let userIDs = Array(Set(allMemberships.map(\.userId)))
        let profiles: [ProfileDTO] = try await client.select("profiles", query: [
            URLQueryItem(name: "id", value: userIDs.postgrestInList),
        ])

        for profile in profiles {
            try store.apply(profile)
        }
        var result: [Huddle] = []
        for dto in huddleDTOs {
            let huddle = try store.apply(dto)
            try store.applyMemberships(allMemberships.filter { $0.huddleId == dto.id }, to: huddle)
            result.append(huddle)
        }
        try store.save()
        // The foreground pass: share huddle keys with members who joined (or
        // re-keyed) since. Off the list's critical path — it shows no photos.
        let keyring = keyring
        Task { await keyring.sync(huddleIDs: huddleIDs) }
        return result.sorted { $0.createdAt < $1.createdAt }
    }

    func createHuddle(name: String, emoji: String, keeper: User) async throws -> Huddle {
        let rows: [HuddleDTO]
        do {
            rows = try await client.rpc("create_huddle", params: [
                "p_name": name.trimmingCharacters(in: .whitespacesAndNewlines),
                "p_emoji": emoji,
                "p_day_key": todayKey,
            ])
        } catch let SupabaseClient.ClientError.http(status, message) {
            if let refusal = HuddleServiceError(serverCreateMessage: message) { throw refusal }
            throw SupabaseClient.ClientError.http(status: status, message: message)
        }
        guard let dto = rows.first else {
            throw SupabaseClient.ClientError.http(status: 500, message: "create_huddle returned nothing")
        }
        let huddle = try await syncSingleHuddle(dto)
        // The creator's device makes the huddle key. If this fails, the next
        // foreground or huddle open retries it before any photo needs it.
        await keyring.sync(huddleIDs: [huddle.id])
        return huddle
    }

    /// Instant join: the server checks the code's proof (never its secret)
    /// and returns the huddle key sealed for the code; the keyring opens it
    /// and stores this user's own copy. No other member has to be online, and
    /// every photo opens straight away.
    func joinHuddle(inviteCode: String, user: User) async throws -> Huddle {
        guard let code = InviteCode(inviteCode) else {
            throw InviteCode.isLegacy(inviteCode) ? HuddleServiceError.inviteCodeOutdated : .inviteCodeNotFound
        }
        do {
            let rows: [InviteRedemptionDTO] = try await client.rpc("redeem_huddle_invite", params: [
                "p_lookup": code.lookup,
                "p_proof": InviteCrypto.proof(for: code),
                "p_day_key": todayKey,
            ])
            guard let redemption = rows.first else {
                throw HuddleServiceError.inviteCodeNotFound
            }
            let huddleID = redemption.joinedHuddleId
            guard await keyring.acceptInvite(code, redemption: redemption) else {
                // The server took the proof but its sealed key doesn't open
                // (a damaged invite): don't stay where no photo would open.
                try? await client.delete("memberships", query: [
                    URLQueryItem(name: "huddle_id", value: "eq.\(huddleID.uuidString)"),
                    URLQueryItem(name: "user_id", value: "eq.\(user.id.uuidString)"),
                ])
                throw HuddleServiceError.inviteUnusable
            }
            let huddles: [HuddleDTO] = try await client.select("huddles", query: [
                URLQueryItem(name: "id", value: "eq.\(huddleID.uuidString)"),
            ])
            guard let dto = huddles.first else {
                throw SupabaseClient.ClientError.http(status: 500, message: "joined huddle not readable")
            }
            return try await syncSingleHuddle(dto)
        } catch let SupabaseClient.ClientError.http(_, message) {
            // Map the RPC's raised exceptions onto the app's error space.
            if message.contains("invite_code_not_found") { throw HuddleServiceError.inviteCodeNotFound }
            if message.contains("already_member") { throw HuddleServiceError.alreadyMember }
            // The limits first: their codes contain "blocked" too (see
            // HuddleServiceError.init(serverJoinMessage:)).
            if let refusal = HuddleServiceError(serverJoinMessage: message) { throw refusal }
            if message.contains("blocked") { throw HuddleServiceError.cannotJoin }
            if message.contains("too_many_attempts") { throw HuddleServiceError.tooManyAttempts }
            throw SupabaseClient.ClientError.http(status: 0, message: message)
        }
    }

    func inviteCode(for huddle: Huddle) async throws -> InviteCode? {
        try await keyring.inviteCode(for: huddle.id)
    }

    func resetInviteCode(for huddle: Huddle, by user: User) async throws -> InviteCode {
        do {
            return try await keyring.resetInviteCode(for: huddle.id)
        } catch let SupabaseClient.ClientError.http(_, message) where message.contains("not_keeper") {
            throw HuddleServiceError.notKeeper
        } catch PhotoKeyError.huddleKeyUnavailable {
            throw HuddleServiceError.inviteUnavailable
        }
    }

    func joinStatus(for huddle: Huddle) async -> HuddleJoinStatus? {
        struct StatusDTO: Decodable {
            let accepting: Bool
            let refusal: String?
            let memberCount: Int
            let memberCap: Int
        }
        guard let rows: [StatusDTO] = try? await client.rpc("huddle_join_status", params: [
            "p_huddle": huddle.id.uuidString,
        ]), let row = rows.first else { return nil }
        let refusal = row.refusal.flatMap(HuddleEngine.JoinRefusal.init(rawValue:))
        // A refusal this build doesn't know: no status rather than "open".
        if !row.accepting, refusal == nil { return nil }
        return HuddleJoinStatus(refusal: refusal, memberCount: row.memberCount, memberCap: row.memberCap)
    }

    func leaveHuddle(_ huddle: Huddle, user: User) async throws {
        // The server's rule would quietly keep the row: say why instead.
        if huddle.memberships.contains(where: { $0.user?.id == user.id && $0.role == .keeper }) {
            throw HuddleServiceError.keeperCannotLeave
        }
        try await client.delete("memberships", query: [
            URLQueryItem(name: "huddle_id", value: "eq.\(huddle.id.uuidString)"),
            URLQueryItem(name: "user_id", value: "eq.\(user.id.uuidString)"),
        ])
        if let membership = huddle.memberships.first(where: { $0.user?.id == user.id }) {
            store.deleteMembershipLocally(membership)
        }
        try store.save()
    }

    func deleteHuddle(_ huddle: Huddle, by user: User) async throws {
        guard huddle.memberships.contains(where: { $0.user?.id == user.id && $0.role == .keeper }) else {
            throw HuddleServiceError.notKeeper
        }
        let body = try JSONEncoder().encode(["huddle_id": huddle.id.uuidString.lowercased()])
        do {
            try await client.invokeFunction("delete-huddle", body: body)
        } catch SupabaseClient.ClientError.http(status: 403, message: _) {
            throw HuddleServiceError.notKeeper
        } catch SupabaseClient.ClientError.http(status: 404, message: _) {
            // Already deleted (from another device): only this one is left.
        }
        store.removeMembershipsLocally(of: huddle)
        try store.save()
    }

    func skipRecords(for huddle: Huddle) async throws -> [String: Set<UUID>] {
        let dtos: [SkipDTO] = try await client.select("skips", query: [
            URLQueryItem(name: "huddle_id", value: "eq.\(huddle.id.uuidString)"),
        ])
        var result: [String: Set<UUID>] = [:]
        for dto in dtos {
            result[dto.dayKey, default: []].insert(dto.userId)
        }
        return result
    }

    func spendSkipToken(membership: Membership, dayKey: String) async throws {
        guard let huddleID = membership.huddle?.id, let userID = membership.user?.id else { return }
        try await client.rpcVoid("spend_skip_token", params: [
            "p_huddle": huddleID.uuidString,
            "p_user": userID.uuidString,
            "p_day_key": dayKey,
        ])
        membership.skipTokensRemaining = max(0, membership.skipTokensRemaining - 1)
        try store.save()
    }

    func updateNotificationHour(_ hour: Int, for huddle: Huddle) async throws {
        struct Patch: Encodable { let notificationHour: Int }
        try await client.update("huddles", values: Patch(notificationHour: hour), query: [
            URLQueryItem(name: "id", value: "eq.\(huddle.id.uuidString)"),
        ])
        huddle.notificationHour = hour
        try store.save()
    }

    /// The server is the single source of truth for streaks; the RPC walks
    /// the full deposit + skip history and returns the new count.
    func recomputeStreak(for huddle: Huddle, now: Date) async throws {
        let count: Int = try await client.rpc("recompute_streak", params: [
            "p_huddle": huddle.id.uuidString,
            "p_today": engine.todayKey(now: now),
        ])
        huddle.streakCount = count
        // Pull the row back for last_streak_day.
        let rows: [HuddleDTO] = try await client.select("huddles", query: [
            URLQueryItem(name: "id", value: "eq.\(huddle.id.uuidString)"),
        ])
        if let dto = rows.first {
            try store.apply(dto)
        }
        try store.save()
    }

    /// What the keyring found on its last pass over the huddle (every open
    /// of it syncs its keys): no request of its own.
    func keyChecks(for huddle: Huddle) async -> [KeyCheck] {
        keyring.keyChecks(for: huddle.id)
    }

    func confirmKeyCheck(_ check: KeyCheck, in huddle: Huddle) async throws {
        try await keyring.confirmKeyCheck(check, huddleID: huddle.id)
    }

    func ownKeyCode() async -> String? {
        await keyring.ownKeyCode()
    }

    private func syncSingleHuddle(_ dto: HuddleDTO) async throws -> Huddle {
        let huddle = try store.apply(dto)
        let memberships: [MembershipDTO] = try await client.select("memberships", query: [
            URLQueryItem(name: "huddle_id", value: "eq.\(dto.id.uuidString)"),
        ])
        let userIDs = Array(Set(memberships.map(\.userId)))
        let profiles: [ProfileDTO] = try await client.select("profiles", query: [
            URLQueryItem(name: "id", value: userIDs.postgrestInList),
        ])
        for profile in profiles {
            try store.apply(profile)
        }
        try store.applyMemberships(memberships, to: huddle)
        try store.save()
        return huddle
    }
}

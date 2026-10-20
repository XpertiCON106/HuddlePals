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
        let rows: [HuddleDTO] = try await client.rpc("create_huddle", params: [
            "p_name": name.trimmingCharacters(in: .whitespacesAndNewlines),
            "p_emoji": emoji,
            "p_day_key": todayKey,
        ])
        guard let dto = rows.first else {
            throw SupabaseClient.ClientError.http(status: 500, message: "create_huddle returned nothing")
        }
        let huddle = try await syncSingleHuddle(dto)
        // The creator's device makes the huddle key. If this fails, the next
        // foreground or huddle open retries it before any photo needs it.
        await keyring.sync(huddleIDs: [huddle.id])
        return huddle
    }

    func joinHuddle(inviteCode: String, user: User) async throws -> Huddle {
        do {
            let rows: [HuddleDTO] = try await client.rpc("join_huddle", params: [
                "p_code": inviteCode,
                "p_day_key": todayKey,
            ])
            guard let dto = rows.first else {
                throw HuddleServiceError.inviteCodeNotFound
            }
            return try await syncSingleHuddle(dto)
        } catch let SupabaseClient.ClientError.http(_, message) {
            // Map the RPC's raised exceptions onto the app's error space.
            if message.contains("invite_code_not_found") { throw HuddleServiceError.inviteCodeNotFound }
            if message.contains("already_member") { throw HuddleServiceError.alreadyMember }
            if message.contains("huddle_full") { throw HuddleServiceError.huddleFull }
            throw SupabaseClient.ClientError.http(status: 0, message: message)
        }
    }

    func leaveHuddle(_ huddle: Huddle, user: User) async throws {
        try await client.delete("memberships", query: [
            URLQueryItem(name: "huddle_id", value: "eq.\(huddle.id.uuidString)"),
            URLQueryItem(name: "user_id", value: "eq.\(user.id.uuidString)"),
        ])
        if let membership = huddle.memberships.first(where: { $0.user?.id == user.id }) {
            store.deleteMembershipLocally(membership)
        }
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

import Foundation
import SwiftData

@MainActor
final class LiveVaultService: VaultServiceProtocol {
    private let client: SupabaseClient
    private let store: SupabaseStore
    private let engine: VaultEngine

    init(client: SupabaseClient, store: SupabaseStore, engine: VaultEngine) {
        self.client = client
        self.store = store
        self.engine = engine
    }

    func vaults(for user: User) async throws -> [Vault] {
        let mine: [MembershipDTO] = try await client.select("memberships", query: [
            URLQueryItem(name: "user_id", value: "eq.\(user.id.uuidString)"),
        ])
        let vaultIDs = mine.map(\.vaultId)
        try store.pruneVaults(keeping: Set(vaultIDs))
        guard !vaultIDs.isEmpty else {
            try store.save()
            return []
        }

        let vaultDTOs: [VaultDTO] = try await client.select("vaults", query: [
            URLQueryItem(name: "id", value: vaultIDs.postgrestInList),
        ])
        let allMemberships: [MembershipDTO] = try await client.select("memberships", query: [
            URLQueryItem(name: "vault_id", value: vaultIDs.postgrestInList),
        ])
        let userIDs = Array(Set(allMemberships.map(\.userId)))
        let profiles: [ProfileDTO] = try await client.select("profiles", query: [
            URLQueryItem(name: "id", value: userIDs.postgrestInList),
        ])

        for profile in profiles {
            try store.apply(profile)
        }
        var result: [Vault] = []
        for dto in vaultDTOs {
            let vault = try store.apply(dto)
            try store.applyMemberships(allMemberships.filter { $0.vaultId == dto.id }, to: vault)
            result.append(vault)
        }
        try store.save()
        return result.sorted { $0.createdAt < $1.createdAt }
    }

    func createVault(name: String, emoji: String, keeper: User) async throws -> Vault {
        let rows: [VaultDTO] = try await client.rpc("create_vault", params: [
            "p_name": name.trimmingCharacters(in: .whitespacesAndNewlines),
            "p_emoji": emoji,
        ])
        guard let dto = rows.first else {
            throw SupabaseClient.ClientError.http(status: 500, message: "create_vault returned nothing")
        }
        return try await syncSingleVault(dto)
    }

    func joinVault(inviteCode: String, user: User) async throws -> Vault {
        do {
            let rows: [VaultDTO] = try await client.rpc("join_vault", params: ["p_code": inviteCode])
            guard let dto = rows.first else {
                throw VaultServiceError.inviteCodeNotFound
            }
            return try await syncSingleVault(dto)
        } catch let SupabaseClient.ClientError.http(_, message) {
            // Map the RPC's raised exceptions onto the app's error space.
            if message.contains("invite_code_not_found") { throw VaultServiceError.inviteCodeNotFound }
            if message.contains("already_member") { throw VaultServiceError.alreadyMember }
            if message.contains("vault_full") { throw VaultServiceError.vaultFull }
            throw SupabaseClient.ClientError.http(status: 0, message: message)
        }
    }

    func leaveVault(_ vault: Vault, user: User) async throws {
        try await client.delete("memberships", query: [
            URLQueryItem(name: "vault_id", value: "eq.\(vault.id.uuidString)"),
            URLQueryItem(name: "user_id", value: "eq.\(user.id.uuidString)"),
        ])
        if let membership = vault.memberships.first(where: { $0.user?.id == user.id }) {
            store.deleteMembershipLocally(membership)
        }
        try store.save()
    }

    func skipRecords(for vault: Vault) async throws -> [String: Set<UUID>] {
        let dtos: [SkipDTO] = try await client.select("skips", query: [
            URLQueryItem(name: "vault_id", value: "eq.\(vault.id.uuidString)"),
        ])
        var result: [String: Set<UUID>] = [:]
        for dto in dtos {
            result[dto.dayKey, default: []].insert(dto.userId)
        }
        return result
    }

    func spendSkipToken(membership: Membership, dayKey: String) async throws {
        guard let vaultID = membership.vault?.id, let userID = membership.user?.id else { return }
        try await client.rpcVoid("spend_skip_token", params: [
            "p_vault": vaultID.uuidString,
            "p_user": userID.uuidString,
            "p_day_key": dayKey,
        ])
        membership.skipTokensRemaining = max(0, membership.skipTokensRemaining - 1)
        try store.save()
    }

    func updateNotificationHour(_ hour: Int, for vault: Vault) async throws {
        struct Patch: Encodable { let notificationHour: Int }
        try await client.update("vaults", values: Patch(notificationHour: hour), query: [
            URLQueryItem(name: "id", value: "eq.\(vault.id.uuidString)"),
        ])
        vault.notificationHour = hour
        try store.save()
    }

    /// The server is the single source of truth for streaks; the RPC walks
    /// the full deposit + skip history and returns the new count.
    func recomputeStreak(for vault: Vault, now: Date) async throws {
        let count: Int = try await client.rpc("recompute_streak", params: [
            "p_vault": vault.id.uuidString,
            "p_today": engine.todayKey(now: now),
        ])
        vault.streakCount = count
        // Pull the row back for last_streak_day.
        let rows: [VaultDTO] = try await client.select("vaults", query: [
            URLQueryItem(name: "id", value: "eq.\(vault.id.uuidString)"),
        ])
        if let dto = rows.first {
            try store.apply(dto)
        }
        try store.save()
    }

    private func syncSingleVault(_ dto: VaultDTO) async throws -> Vault {
        let vault = try store.apply(dto)
        let memberships: [MembershipDTO] = try await client.select("memberships", query: [
            URLQueryItem(name: "vault_id", value: "eq.\(dto.id.uuidString)"),
        ])
        let userIDs = Array(Set(memberships.map(\.userId)))
        let profiles: [ProfileDTO] = try await client.select("profiles", query: [
            URLQueryItem(name: "id", value: userIDs.postgrestInList),
        ])
        for profile in profiles {
            try store.apply(profile)
        }
        try store.applyMemberships(memberships, to: vault)
        try store.save()
        return vault
    }
}

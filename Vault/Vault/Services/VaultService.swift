import Foundation
import SwiftData

enum VaultServiceError: LocalizedError {
    case inviteCodeNotFound
    case alreadyMember
    case notAMember
    case vaultFull

    var errorDescription: String? {
        switch self {
        case .inviteCodeNotFound: "No vault found for that code. Double-check it and try again."
        case .alreadyMember: "You're already a member of this vault."
        case .notAMember: "You're not a member of this vault."
        case .vaultFull: "This vault already has 8 members — that's the limit."
        }
    }
}

@MainActor
protocol VaultServiceProtocol: AnyObject {
    func vaults(for user: User) async throws -> [Vault]
    func createVault(name: String, emoji: String, keeper: User) async throws -> Vault
    func joinVault(inviteCode: String, user: User) async throws -> Vault
    func leaveVault(_ vault: Vault, user: User) async throws
    /// Skip-token usage per dayKey, consumed by streak math.
    func skipRecords(for vault: Vault) async throws -> [String: Set<UUID>]
    func spendSkipToken(membership: Membership, dayKey: String) async throws
    func updateNotificationHour(_ hour: Int, for vault: Vault) async throws
    /// Recomputes and persists the group streak. Called on launch and after
    /// every deposit.
    func recomputeStreak(for vault: Vault, now: Date) async throws
}

// MARK: - Skip ledger

/// In-memory record of who spent a skip token on which day. Seeded with
/// historical skips so streak math has realistic data.
///
/// TODO: BACKEND — replace with a `skips` table (vault_id, user_id, day_key)
/// so skip usage survives reinstall and syncs across members.
final class SkipLedger {
    private var records: [UUID: [String: Set<UUID>]] = [:]

    func recordSkip(vaultID: UUID, dayKey: String, userID: UUID) {
        records[vaultID, default: [:]][dayKey, default: []].insert(userID)
    }

    func skips(for vaultID: UUID) -> [String: Set<UUID>] {
        records[vaultID] ?? [:]
    }

    func removeAll() {
        records.removeAll()
    }
}

// MARK: - Mock

@MainActor
final class MockVaultService: VaultServiceProtocol {
    private let context: ModelContext
    private let engine: VaultEngine
    private let skipLedger: SkipLedger

    init(context: ModelContext, engine: VaultEngine, skipLedger: SkipLedger) {
        self.context = context
        self.engine = engine
        self.skipLedger = skipLedger
    }

    func vaults(for user: User) async throws -> [Vault] {
        // TODO: BACKEND — fetch vault memberships for the authed user from
        // Supabase (`memberships` joined to `vaults`), then merge into the
        // local SwiftData cache.
        user.memberships
            .compactMap(\.vault)
            .sorted { $0.createdAt < $1.createdAt }
    }

    func createVault(name: String, emoji: String, keeper: User) async throws -> Vault {
        // TODO: BACKEND — insert vault + keeper membership in one RPC so
        // invite-code uniqueness is enforced server-side.
        let vault = Vault(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            emoji: emoji,
            inviteCode: try uniqueInviteCode()
        )
        context.insert(vault)
        let membership = Membership(user: keeper, vault: vault, role: .keeper)
        context.insert(membership)
        try context.save()
        return vault
    }

    func joinVault(inviteCode: String, user: User) async throws -> Vault {
        // TODO: BACKEND — call a join RPC that validates the code and
        // enforces the 8-member cap atomically.
        let code = inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let vaults = try context.fetch(FetchDescriptor<Vault>())
        guard let vault = vaults.first(where: { $0.inviteCode.uppercased() == code }) else {
            throw VaultServiceError.inviteCodeNotFound
        }
        guard !vault.memberships.contains(where: { $0.user?.id == user.id }) else {
            throw VaultServiceError.alreadyMember
        }
        let membership = Membership(user: user, vault: vault)
        context.insert(membership)
        try context.save()
        return vault
    }

    func leaveVault(_ vault: Vault, user: User) async throws {
        // TODO: BACKEND — delete the membership row; server reassigns the
        // keeper role if the keeper leaves.
        guard let membership = vault.memberships.first(where: { $0.user?.id == user.id }) else {
            throw VaultServiceError.notAMember
        }
        context.delete(membership)
        try context.save()
    }

    func skipRecords(for vault: Vault) async throws -> [String: Set<UUID>] {
        skipLedger.skips(for: vault.id)
    }

    func updateNotificationHour(_ hour: Int, for vault: Vault) async throws {
        vault.notificationHour = hour
        try context.save()
    }

    func spendSkipToken(membership: Membership, dayKey: String) async throws {
        guard membership.skipTokensRemaining > 0,
              let vaultID = membership.vault?.id,
              let userID = membership.user?.id else { return }
        membership.skipTokensRemaining -= 1
        skipLedger.recordSkip(vaultID: vaultID, dayKey: dayKey, userID: userID)
        try context.save()
    }

    func recomputeStreak(for vault: Vault, now: Date) async throws {
        // TODO: BACKEND — streaks should be computed server-side (edge
        // function on deposit insert) so all members agree; this local
        // recompute then becomes a cache.
        let memberIDs = Set(vault.memberships.compactMap { $0.user?.id })
        let snapshots = vault.deposits.compactMap(\.snapshot)
        let result = engine.computeStreak(
            memberIDs: memberIDs,
            deposits: snapshots,
            skips: skipLedger.skips(for: vault.id),
            now: now
        )
        vault.streakCount = result.count
        vault.lastStreakDate = result.lastCompleteDayKey.flatMap { engine.date(fromDayKey: $0) }
        try context.save()
    }

    private func uniqueInviteCode() throws -> String {
        let existing = Set(try context.fetch(FetchDescriptor<Vault>()).map(\.inviteCode))
        for _ in 0..<50 {
            let code = VaultEngine.generateInviteCode()
            if !existing.contains(code) { return code }
        }
        return VaultEngine.generateInviteCode(length: 8)
    }
}

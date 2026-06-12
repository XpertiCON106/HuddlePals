import Foundation
import SwiftData

/// Reconciles remote rows into the local SwiftData store. The server is the
/// source of truth: rows are upserted by id, and local rows that vanished
/// remotely (within the synced scope) are pruned. Views keep rendering the
/// same SwiftData models they always did — this is the entire trick that
/// lets the UI stay untouched in live mode.
@MainActor
final class SupabaseStore {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Lookups

    func user(id: UUID) throws -> User? {
        try context.fetch(FetchDescriptor<User>()).first { $0.id == id }
    }

    func vault(id: UUID) throws -> Vault? {
        try context.fetch(FetchDescriptor<Vault>()).first { $0.id == id }
    }

    // MARK: - Upserts

    @discardableResult
    func apply(_ dto: ProfileDTO) throws -> User {
        if let existing = try user(id: dto.id) {
            existing.displayName = dto.displayName
            existing.avatarColorHex = dto.avatarColorHex
            existing.bio = dto.bio
            existing.profilePhotoPaths = dto.photoPaths ?? []
            return existing
        }
        let user = User(
            id: dto.id,
            displayName: dto.displayName,
            avatarColorHex: dto.avatarColorHex,
            bio: dto.bio,
            profilePhotoPaths: dto.photoPaths ?? [],
            joinedAt: dto.createdAt ?? .now
        )
        context.insert(user)
        return user
    }

    @discardableResult
    func apply(_ dto: VaultDTO) throws -> Vault {
        if let existing = try vault(id: dto.id) {
            existing.name = dto.name
            existing.emoji = dto.emoji
            existing.inviteCode = dto.inviteCode
            existing.notificationHour = dto.notificationHour
            existing.streakCount = dto.streakCount
            existing.lastStreakDate = dto.lastStreakDay.flatMap(Self.dayKeyDate)
            return existing
        }
        let vault = Vault(
            id: dto.id,
            name: dto.name,
            emoji: dto.emoji,
            inviteCode: dto.inviteCode,
            createdAt: dto.createdAt ?? .now,
            notificationHour: dto.notificationHour,
            streakCount: dto.streakCount,
            lastStreakDate: dto.lastStreakDay.flatMap(Self.dayKeyDate)
        )
        context.insert(vault)
        return vault
    }

    /// Syncs the membership list of one vault, pruning members who left.
    func applyMemberships(_ dtos: [MembershipDTO], to vault: Vault) throws {
        let remoteIDs = Set(dtos.map(\.id))
        for stale in vault.memberships where !remoteIDs.contains(stale.id) {
            context.delete(stale)
        }
        let existingByID = Dictionary(
            vault.memberships.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for dto in dtos {
            guard let user = try user(id: dto.userId) else { continue }
            if let existing = existingByID[dto.id] {
                existing.role = MembershipRole(rawValue: dto.role) ?? .member
                existing.skipTokensRemaining = dto.skipTokensRemaining
            } else {
                let membership = Membership(
                    id: dto.id,
                    user: user,
                    vault: vault,
                    role: MembershipRole(rawValue: dto.role) ?? .member,
                    skipTokensRemaining: dto.skipTokensRemaining,
                    joinedAt: dto.joinedAt ?? .now
                )
                context.insert(membership)
            }
        }
    }

    /// Syncs all deposits (and their reactions/comments) of one vault.
    /// `localImagePath` is derived from the storage path — MediaService
    /// caches the bytes under the same relative path.
    func applyDeposits(
        _ dtos: [DepositDTO],
        reactions: [ReactionDTO],
        comments: [CommentDTO],
        to vault: Vault
    ) throws {
        let remoteIDs = Set(dtos.map(\.id))
        for stale in vault.deposits where !remoteIDs.contains(stale.id) {
            context.delete(stale) // replaced or removed remotely
        }
        var depositsByID: [UUID: Deposit] = Dictionary(
            vault.deposits.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for dto in dtos {
            guard let author = try user(id: dto.authorId) else { continue }
            if let existing = depositsByID[dto.id] {
                existing.localImagePath = LiveMediaService.cachePath(forStoragePath: dto.storagePath)
                existing.caption = dto.caption
                existing.dayKey = dto.dayKey
            } else {
                let deposit = Deposit(
                    id: dto.id,
                    vault: vault,
                    author: author,
                    localImagePath: LiveMediaService.cachePath(forStoragePath: dto.storagePath),
                    caption: dto.caption,
                    dayKey: dto.dayKey,
                    createdAt: dto.createdAt ?? .now
                )
                context.insert(deposit)
                depositsByID[dto.id] = deposit
            }
        }

        let remoteReactionIDs = Set(reactions.map(\.id))
        let remoteCommentIDs = Set(comments.map(\.id))
        for deposit in depositsByID.values {
            for stale in deposit.reactions where !remoteReactionIDs.contains(stale.id) {
                context.delete(stale)
            }
            for stale in deposit.comments where !remoteCommentIDs.contains(stale.id) {
                context.delete(stale)
            }
        }
        let existingReactionIDs = Set(depositsByID.values.flatMap(\.reactions).map(\.id))
        for dto in reactions where !existingReactionIDs.contains(dto.id) {
            guard let deposit = depositsByID[dto.depositId],
                  let user = try user(id: dto.userId) else { continue }
            context.insert(Reaction(
                id: dto.id, deposit: deposit, user: user,
                emoji: dto.emoji, createdAt: dto.createdAt ?? .now
            ))
        }
        let existingCommentIDs = Set(depositsByID.values.flatMap(\.comments).map(\.id))
        for dto in comments where !existingCommentIDs.contains(dto.id) {
            guard let deposit = depositsByID[dto.depositId],
                  let user = try user(id: dto.userId) else { continue }
            context.insert(Comment(
                id: dto.id, deposit: deposit, user: user,
                text: dto.body, createdAt: dto.createdAt ?? .now
            ))
        }
    }

    /// Upsert of a single deposit (after create/replace) — no pruning, but
    /// any *other* local row for the same (author, day) goes away, mirroring
    /// the server's unique constraint.
    @discardableResult
    func applyDeposit(_ dto: DepositDTO, to vault: Vault, author: User) throws -> Deposit {
        for stale in vault.deposits
        where stale.id != dto.id && stale.author?.id == dto.authorId && stale.dayKey == dto.dayKey {
            context.delete(stale)
        }
        if let existing = vault.deposits.first(where: { $0.id == dto.id }) {
            existing.localImagePath = LiveMediaService.cachePath(forStoragePath: dto.storagePath)
            existing.caption = dto.caption
            existing.dayKey = dto.dayKey
            return existing
        }
        let deposit = Deposit(
            id: dto.id,
            vault: vault,
            author: author,
            localImagePath: LiveMediaService.cachePath(forStoragePath: dto.storagePath),
            caption: dto.caption,
            dayKey: dto.dayKey,
            createdAt: dto.createdAt ?? .now
        )
        context.insert(deposit)
        return deposit
    }

    func insertReactionLocally(_ dto: ReactionDTO, deposit: Deposit, user: User) {
        guard !deposit.reactions.contains(where: { $0.id == dto.id }) else { return }
        context.insert(Reaction(
            id: dto.id, deposit: deposit, user: user,
            emoji: dto.emoji, createdAt: dto.createdAt ?? .now
        ))
    }

    @discardableResult
    func insertCommentLocally(_ dto: CommentDTO, deposit: Deposit, user: User) -> Comment {
        if let existing = deposit.comments.first(where: { $0.id == dto.id }) {
            return existing
        }
        let comment = Comment(
            id: dto.id, deposit: deposit, user: user,
            text: dto.body, createdAt: dto.createdAt ?? .now
        )
        context.insert(comment)
        return comment
    }

    func deleteReactionLocally(_ reaction: Reaction) {
        context.delete(reaction)
    }

    func deleteMembershipLocally(_ membership: Membership) {
        context.delete(membership)
    }

    /// Prunes vaults the user no longer belongs to (left on another device).
    func pruneVaults(keeping ids: Set<UUID>) throws {
        for vault in try context.fetch(FetchDescriptor<Vault>()) where !ids.contains(vault.id) {
            context.delete(vault)
        }
    }

    func save() throws {
        try context.save()
    }

    private static func dayKeyDate(_ key: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: key)
    }
}

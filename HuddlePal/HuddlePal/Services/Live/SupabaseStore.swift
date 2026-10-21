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

    // Predicate-filtered point lookups: these run inside per-row
    // reconciliation loops, so fetching the whole table and scanning each
    // time was O(n²). The id is unique, so fetchLimit 1 is exact.
    func user(id: UUID) throws -> User? {
        var descriptor = FetchDescriptor<User>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func huddle(id: UUID) throws -> Huddle? {
        var descriptor = FetchDescriptor<Huddle>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// The ids among `ids` that have no local `User` row yet.
    func missingUserIDs(in ids: Set<UUID>) throws -> [UUID] {
        try Array(ids.filter { try user(id: $0) == nil })
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
    func apply(_ dto: HuddleDTO) throws -> Huddle {
        if let existing = try huddle(id: dto.id) {
            existing.name = dto.name
            existing.emoji = dto.emoji
            existing.inviteCode = dto.inviteCode
            existing.notificationHour = dto.notificationHour
            existing.streakCount = dto.streakCount
            existing.lastStreakDate = dto.lastStreakDay.flatMap(Self.dayKeyDate)
            return existing
        }
        let huddle = Huddle(
            id: dto.id,
            name: dto.name,
            emoji: dto.emoji,
            inviteCode: dto.inviteCode,
            createdAt: dto.createdAt ?? .now,
            notificationHour: dto.notificationHour,
            streakCount: dto.streakCount,
            lastStreakDate: dto.lastStreakDay.flatMap(Self.dayKeyDate)
        )
        context.insert(huddle)
        return huddle
    }

    /// Syncs the membership list of one huddle, pruning members who left.
    func applyMemberships(_ dtos: [MembershipDTO], to huddle: Huddle) throws {
        let remoteIDs = Set(dtos.map(\.id))
        for stale in huddle.memberships where !remoteIDs.contains(stale.id) {
            context.delete(stale)
        }
        let existingByID = Dictionary(
            huddle.memberships.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for dto in dtos {
            guard let user = try user(id: dto.userId) else { continue }
            if let existing = existingByID[dto.id] {
                existing.role = MembershipRole(rawValue: dto.role) ?? .member
                existing.skipTokensRemaining = dto.skipTokensRemaining
                existing.joinedDayKey = dto.joinedDayKey
            } else {
                let membership = Membership(
                    id: dto.id,
                    user: user,
                    huddle: huddle,
                    role: MembershipRole(rawValue: dto.role) ?? .member,
                    skipTokensRemaining: dto.skipTokensRemaining,
                    joinedAt: dto.joinedAt ?? .now,
                    joinedDayKey: dto.joinedDayKey
                )
                context.insert(membership)
            }
        }
    }

    /// Syncs all deposits (and their reactions/comments) of one huddle.
    /// `localImagePath` is derived from the storage path — MediaService
    /// caches the bytes under the same relative path.
    ///
    /// A row whose author can't be resolved is kept with a nil author
    /// ("Former member"), never dropped: a deleted account nulls the id, and
    /// a member who left keeps their id but their profile is no longer
    /// readable under RLS. Deposits are permanent; so is their display.
    func applyDeposits(
        _ dtos: [DepositDTO],
        reactions: [ReactionDTO],
        comments: [CommentDTO],
        to huddle: Huddle
    ) throws {
        let remoteIDs = Set(dtos.map(\.id))
        for stale in huddle.deposits where !remoteIDs.contains(stale.id) {
            context.delete(stale) // gone remotely
        }
        var depositsByID: [UUID: Deposit] = Dictionary(
            huddle.deposits.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for dto in dtos {
            let author = try resolveUser(dto.authorId)
            if let existing = depositsByID[dto.id] {
                existing.localImagePath = LiveMediaService.cachePath(forStoragePath: dto.storagePath)
                existing.caption = dto.caption
                existing.dayKey = dto.dayKey
                existing.wrappedPhotoKey = Self.wrappedPhotoKey(of: dto)
                if existing.author?.id != author?.id { existing.author = author }
            } else {
                let deposit = Deposit(
                    id: dto.id,
                    huddle: huddle,
                    author: author,
                    localImagePath: LiveMediaService.cachePath(forStoragePath: dto.storagePath),
                    caption: dto.caption,
                    dayKey: dto.dayKey,
                    createdAt: dto.createdAt ?? .now,
                    wrappedPhotoKey: Self.wrappedPhotoKey(of: dto)
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
        let existingReactions = Dictionary(
            depositsByID.values.flatMap(\.reactions).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for dto in reactions {
            guard let deposit = depositsByID[dto.depositId] else { continue }
            // Counts stay honest even when the reactor's profile is unreadable.
            let user = try resolveUser(dto.userId)
            if let existing = existingReactions[dto.id] {
                if existing.user?.id != user?.id { existing.user = user }
                continue
            }
            context.insert(Reaction(
                id: dto.id, deposit: deposit, user: user,
                emoji: dto.emoji, createdAt: dto.createdAt ?? .now
            ))
        }
        let existingComments = Dictionary(
            depositsByID.values.flatMap(\.comments).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for dto in comments {
            guard let deposit = depositsByID[dto.depositId] else { continue }
            let user = try resolveUser(dto.userId)
            if let existing = existingComments[dto.id] {
                if existing.user?.id != user?.id { existing.user = user }
                continue
            }
            context.insert(Comment(
                id: dto.id, deposit: deposit, user: user,
                text: dto.body, createdAt: dto.createdAt ?? .now
            ))
        }
    }

    /// Local user for a remote id; nil for a null id or an unknown profile.
    private func resolveUser(_ id: UUID?) throws -> User? {
        guard let id else { return nil }
        return try user(id: id)
    }

    /// Upsert of a single deposit (right after creating it) — no pruning, but
    /// any *other* local row for the same (author, day) goes away, mirroring
    /// the server's unique constraint.
    @discardableResult
    func applyDeposit(_ dto: DepositDTO, to huddle: Huddle, author: User) throws -> Deposit {
        // Matched on the known author, not `dto.authorId`: comparing two nil
        // authors would wrongly sweep up unrelated "Former member" rows.
        for stale in huddle.deposits
        where stale.id != dto.id && stale.author?.id == author.id && stale.dayKey == dto.dayKey {
            context.delete(stale)
        }
        if let existing = huddle.deposits.first(where: { $0.id == dto.id }) {
            existing.localImagePath = LiveMediaService.cachePath(forStoragePath: dto.storagePath)
            existing.caption = dto.caption
            existing.dayKey = dto.dayKey
            existing.wrappedPhotoKey = Self.wrappedPhotoKey(of: dto)
            return existing
        }
        let deposit = Deposit(
            id: dto.id,
            huddle: huddle,
            author: author,
            localImagePath: LiveMediaService.cachePath(forStoragePath: dto.storagePath),
            caption: dto.caption,
            dayKey: dto.dayKey,
            createdAt: dto.createdAt ?? .now,
            wrappedPhotoKey: Self.wrappedPhotoKey(of: dto)
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

    /// Prunes huddles the user no longer belongs to (left on another device).
    func pruneHuddles(keeping ids: Set<UUID>) throws {
        for huddle in try context.fetch(FetchDescriptor<Huddle>()) where !ids.contains(huddle.id) {
            context.delete(huddle)
        }
    }

    func save() throws {
        try context.save()
    }

    /// Sign-out / account deletion: every synced row goes, so nothing the
    /// previous account could see is left for the next one.
    func removeAllLocalData() throws {
        // Object by object, parents first, so the cascade rules run: a batch
        // `delete(model:)` refuses rows that others still point at.
        for huddle in try context.fetch(FetchDescriptor<Huddle>()) { context.delete(huddle) }
        for user in try context.fetch(FetchDescriptor<User>()) { context.delete(user) }
        // Anything left without a parent.
        for deposit in try context.fetch(FetchDescriptor<Deposit>()) { context.delete(deposit) }
        for membership in try context.fetch(FetchDescriptor<Membership>()) { context.delete(membership) }
        for reaction in try context.fetch(FetchDescriptor<Reaction>()) { context.delete(reaction) }
        for comment in try context.fetch(FetchDescriptor<Comment>()) { context.delete(comment) }
        try context.save()
    }

    /// Only a format this build can decrypt; anything else (a newer
    /// `enc_version`) renders as the locked placeholder.
    private static func wrappedPhotoKey(of dto: DepositDTO) -> String? {
        dto.encVersion == PhotoCrypto.formatVersion ? dto.wrappedPhotoKey : nil
    }

    private static func dayKeyDate(_ key: String) -> Date? {
        let formatter = DateFormatter()
        // Day keys are Gregorian; the user's own calendar would misread the year.
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: key)
    }
}

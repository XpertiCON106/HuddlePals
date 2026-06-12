import Foundation
import SwiftData

// MARK: - User

@Model
final class User {
    @Attribute(.unique) var id: UUID
    var displayName: String
    /// Identity color token: solid hex or "hex-hex" gradient (AvatarStyle).
    var avatarColorHex: String
    /// Short bio, max 160 chars (enforced in UI + DB check).
    var bio: String?
    /// Up to 3 profile photos, Documents-relative cache paths
    /// ("Media/avatars/<user_id>/<file>.jpg").
    var profilePhotoPaths: [String] = []
    var joinedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Membership.user)
    var memberships: [Membership] = []

    init(
        id: UUID = UUID(),
        displayName: String,
        avatarColorHex: String,
        bio: String? = nil,
        profilePhotoPaths: [String] = [],
        joinedAt: Date = .now
    ) {
        self.id = id
        self.displayName = displayName
        self.avatarColorHex = avatarColorHex
        self.bio = bio
        self.profilePhotoPaths = profilePhotoPaths
        self.joinedAt = joinedAt
    }

    var initials: String {
        let parts = displayName.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

// MARK: - Vault

@Model
final class Vault {
    @Attribute(.unique) var id: UUID
    var name: String
    var emoji: String
    var inviteCode: String
    var createdAt: Date
    var notificationHour: Int
    var streakCount: Int
    var lastStreakDate: Date?

    @Relationship(deleteRule: .cascade, inverse: \Membership.vault)
    var memberships: [Membership] = []

    @Relationship(deleteRule: .cascade, inverse: \Deposit.vault)
    var deposits: [Deposit] = []

    init(
        id: UUID = UUID(),
        name: String,
        emoji: String,
        inviteCode: String,
        createdAt: Date = .now,
        notificationHour: Int = 19,
        streakCount: Int = 0,
        lastStreakDate: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.inviteCode = inviteCode
        self.createdAt = createdAt
        self.notificationHour = notificationHour
        self.streakCount = streakCount
        self.lastStreakDate = lastStreakDate
    }

    /// Members in a stable order (keeper first, then by join date).
    var sortedMemberships: [Membership] {
        memberships.sorted {
            if $0.role != $1.role { return $0.role == .keeper }
            return $0.joinedAt < $1.joinedAt
        }
    }

    var members: [User] {
        sortedMemberships.compactMap(\.user)
    }
}

// MARK: - Membership

enum MembershipRole: String, Codable, CaseIterable {
    case keeper
    case member

    var displayName: String {
        switch self {
        case .keeper: "Keeper"
        case .member: "Member"
        }
    }
}

@Model
final class Membership {
    @Attribute(.unique) var id: UUID
    var user: User?
    var vault: Vault?
    var role: MembershipRole
    var skipTokensRemaining: Int
    var joinedAt: Date

    init(
        id: UUID = UUID(),
        user: User,
        vault: Vault,
        role: MembershipRole = .member,
        skipTokensRemaining: Int = 2,
        joinedAt: Date = .now
    ) {
        self.id = id
        self.user = user
        self.vault = vault
        self.role = role
        self.skipTokensRemaining = skipTokensRemaining
        self.joinedAt = joinedAt
    }
}

// MARK: - Deposit

@Model
final class Deposit {
    @Attribute(.unique) var id: UUID
    var vault: Vault?
    var author: User?
    /// Path relative to the app's Documents directory. The Documents
    /// container path changes between launches, so never store it absolute.
    var localImagePath: String
    var caption: String?
    /// Calendar day this deposit belongs to, "yyyy-MM-dd" in device timezone.
    var dayKey: String
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Reaction.deposit)
    var reactions: [Reaction] = []

    @Relationship(deleteRule: .cascade, inverse: \Comment.deposit)
    var comments: [Comment] = []

    init(
        id: UUID = UUID(),
        vault: Vault,
        author: User,
        localImagePath: String,
        caption: String? = nil,
        dayKey: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.vault = vault
        self.author = author
        self.localImagePath = localImagePath
        self.caption = caption
        self.dayKey = dayKey
        self.createdAt = createdAt
    }

    /// Pure-value snapshot consumed by `VaultEngine`. Nil when the deposit
    /// has been orphaned from its vault or author.
    var snapshot: DepositSnapshot? {
        guard let vaultID = vault?.id, let authorID = author?.id else { return nil }
        return DepositSnapshot(
            id: id,
            vaultID: vaultID,
            authorID: authorID,
            dayKey: dayKey,
            createdAt: createdAt
        )
    }
}

// MARK: - Reaction

@Model
final class Reaction {
    @Attribute(.unique) var id: UUID
    var deposit: Deposit?
    var user: User?
    var emoji: String
    var createdAt: Date

    init(id: UUID = UUID(), deposit: Deposit, user: User, emoji: String, createdAt: Date = .now) {
        self.id = id
        self.deposit = deposit
        self.user = user
        self.emoji = emoji
        self.createdAt = createdAt
    }
}

// MARK: - Comment

@Model
final class Comment {
    @Attribute(.unique) var id: UUID
    var deposit: Deposit?
    var user: User?
    var text: String
    var createdAt: Date

    init(id: UUID = UUID(), deposit: Deposit, user: User, text: String, createdAt: Date = .now) {
        self.id = id
        self.deposit = deposit
        self.user = user
        self.text = text
        self.createdAt = createdAt
    }
}

// MARK: - Schema

enum VaultSchema {
    static let models: [any PersistentModel.Type] = [
        User.self, Vault.self, Membership.self, Deposit.self, Reaction.self, Comment.self,
    ]
}

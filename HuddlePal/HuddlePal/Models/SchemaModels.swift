import Foundation
import SwiftData

// MARK: - User

@Model
final class User {
    @Attribute(.unique) var id: UUID
    var displayName: String
    /// Identity color token: solid hex or "hex-hex" gradient (AvatarStyle).
    var avatarColorHex: String
    /// Short bio: 50 characters in the app (the database check allows 160,
    /// which bios from before may still use).
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

// MARK: - Huddle

@Model
final class Huddle {
    @Attribute(.unique) var id: UUID
    var name: String
    var emoji: String
    var inviteCode: String
    var createdAt: Date
    var notificationHour: Int
    var streakCount: Int
    var lastStreakDate: Date?

    @Relationship(deleteRule: .cascade, inverse: \Membership.huddle)
    var memberships: [Membership] = []

    @Relationship(deleteRule: .cascade, inverse: \Deposit.huddle)
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

    /// Current members' ids, for streak math.
    var memberIDs: Set<UUID> {
        Set(memberships.compactMap { $0.user?.id })
    }

    /// Each current member's join day, for `HuddleEngine`'s streak math
    /// (members count from the day after they joined).
    func memberJoinDayKeys(using engine: HuddleEngine) -> [UUID: String] {
        var keys: [UUID: String] = [:]
        for membership in memberships {
            guard let userID = membership.user?.id else { continue }
            keys[userID] = membership.joinedDayKey ?? engine.dayKey(for: membership.joinedAt)
        }
        return keys
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
    var huddle: Huddle?
    var role: MembershipRole
    var skipTokensRemaining: Int
    var joinedAt: Date
    /// The member's local day at join ("yyyy-MM-dd"). Streaks wait on them
    /// only from the next day. Nil for rows from before this existed —
    /// `Huddle.memberJoinDayKeys` falls back to `joinedAt`.
    var joinedDayKey: String?
    /// When this member became the keeper (`memberships.keeper_since`); nil
    /// for members. The free plan takes new members only into the 3 huddles
    /// a keeper has kept longest (`HuddleEngine.joinRule`). Nil for keepers in
    /// stores from before it existed: `keptSince` falls back to `joinedAt`.
    var keeperSince: Date?

    init(
        id: UUID = UUID(),
        user: User,
        huddle: Huddle,
        role: MembershipRole = .member,
        skipTokensRemaining: Int = 2,
        joinedAt: Date = .now,
        joinedDayKey: String? = nil,
        keeperSince: Date? = nil
    ) {
        self.id = id
        self.user = user
        self.huddle = huddle
        self.role = role
        self.skipTokensRemaining = skipTokensRemaining
        self.joinedAt = joinedAt
        self.joinedDayKey = joinedDayKey
        self.keeperSince = keeperSince
    }

    /// When the keeper took this huddle on, for their queue of huddles kept
    /// (the server backfilled keepers from before keeper_since the same way).
    var keptSince: Date {
        keeperSince ?? joinedAt
    }
}

// MARK: - Deposit

/// What a deposit holds: one photo, or a video clip of up to 6 seconds
/// (Plus) shown with its poster frame.
enum DepositMediaType: String, Codable, CaseIterable {
    case photo
    case video
}

@Model
final class Deposit {
    @Attribute(.unique) var id: UUID
    var huddle: Huddle?
    var author: User?
    /// Path relative to the app's Documents directory. The Documents
    /// container path changes between launches, so never store it absolute.
    /// For a video, its poster frame: what tiles show, and what app builds
    /// from before videos show as a photo.
    var localImagePath: String
    /// `deposits.media_type`, as text with a default so stores from before
    /// videos migrate as they are: every deposit in them is a photo. Read and
    /// write it through `mediaType`.
    var mediaTypeRaw: String = "photo"
    /// A video's clip, Documents-relative like `localImagePath`: the poster's
    /// path ending in .mp4. Nil for a photo.
    var localVideoPath: String?
    /// A video's length in milliseconds (6 000 at most); nil for a photo.
    var durationMs: Int?
    var caption: String?
    /// Calendar day this deposit belongs to, "yyyy-MM-dd" in device timezone.
    var dayKey: String
    var createdAt: Date
    /// Live only: the photo's own key sealed with the huddle key — the photo
    /// file is end-to-end encrypted (`PhotoCrypto`). Nil in mock mode, whose
    /// photos never leave the device.
    var wrappedPhotoKey: String?

    @Relationship(deleteRule: .cascade, inverse: \Reaction.deposit)
    var reactions: [Reaction] = []

    @Relationship(deleteRule: .cascade, inverse: \Comment.deposit)
    var comments: [Comment] = []

    /// `author` is nil for a "Former member": the account was deleted, or
    /// the author left the huddle and their profile is no longer readable.
    init(
        id: UUID = UUID(),
        huddle: Huddle,
        author: User?,
        localImagePath: String,
        caption: String? = nil,
        dayKey: String,
        createdAt: Date = .now,
        wrappedPhotoKey: String? = nil,
        mediaType: DepositMediaType = .photo,
        localVideoPath: String? = nil,
        durationMs: Int? = nil
    ) {
        self.id = id
        self.huddle = huddle
        self.author = author
        self.localImagePath = localImagePath
        self.caption = caption
        self.dayKey = dayKey
        self.createdAt = createdAt
        self.wrappedPhotoKey = wrappedPhotoKey
        self.mediaTypeRaw = mediaType.rawValue
        self.localVideoPath = localVideoPath
        self.durationMs = durationMs
    }

    /// A media type this build doesn't know reads as a photo: its poster is
    /// a JPEG at `localImagePath` either way.
    var mediaType: DepositMediaType {
        get { DepositMediaType(rawValue: mediaTypeRaw) ?? .photo }
        set { mediaTypeRaw = newValue.rawValue }
    }

    /// A clip to play: a video with its clip's path.
    var isVideo: Bool {
        mediaType == .video && localVideoPath != nil
    }

    /// Pure-value snapshot consumed by `HuddleEngine`. Nil when the deposit
    /// has been orphaned from its huddle or author.
    var snapshot: DepositSnapshot? {
        guard let huddleID = huddle?.id, let authorID = author?.id else { return nil }
        return DepositSnapshot(
            id: id,
            huddleID: huddleID,
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

    init(id: UUID = UUID(), deposit: Deposit, user: User?, emoji: String, createdAt: Date = .now) {
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

    init(id: UUID = UUID(), deposit: Deposit, user: User?, text: String, createdAt: Date = .now) {
        self.id = id
        self.deposit = deposit
        self.user = user
        self.text = text
        self.createdAt = createdAt
    }
}

// MARK: - Schema

enum HuddleSchema {
    static let models: [any PersistentModel.Type] = [
        User.self, Huddle.self, Membership.self, Deposit.self, Reaction.self, Comment.self,
    ]
}

extension ModelContext {
    /// Deletes every row of every model and saves. Object by object, parents
    /// first, so the cascade and nullify rules run: a batch
    /// `delete(model:)` refuses rows that others still point at.
    func deleteAllHuddleData() throws {
        for huddle in try fetch(FetchDescriptor<Huddle>()) { delete(huddle) }
        for user in try fetch(FetchDescriptor<User>()) { delete(user) }
        // Anything left without a parent.
        for deposit in try fetch(FetchDescriptor<Deposit>()) { delete(deposit) }
        for membership in try fetch(FetchDescriptor<Membership>()) { delete(membership) }
        for reaction in try fetch(FetchDescriptor<Reaction>()) { delete(reaction) }
        for comment in try fetch(FetchDescriptor<Comment>()) { delete(comment) }
        try save()
    }
}

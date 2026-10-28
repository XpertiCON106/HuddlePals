import Foundation

// Wire types for PostgREST rows. Property names are chosen so the client's
// convertFromSnakeCase/convertToSnakeCase strategies map them exactly
// (always `Id`, never `ID`, in multi-word names).

/// `profile_birthdates`: one row per account, readable only by its owner.
struct BirthdayDTO: Codable {
    let userId: UUID
    let birthDate: String
}

struct ProfileDTO: Codable {
    let id: UUID
    var displayName: String
    var avatarColorHex: String
    var bio: String?
    var photoPaths: [String]?
    var createdAt: Date?
}

struct HuddleDTO: Codable {
    let id: UUID
    var name: String
    var emoji: String
    var inviteCode: String
    var notificationHour: Int
    var streakCount: Int
    var lastStreakDay: String?
    var createdAt: Date?
}

struct MembershipDTO: Codable {
    let id: UUID
    let userId: UUID
    let huddleId: UUID
    var role: String
    var skipTokensRemaining: Int
    var joinedAt: Date?
    var joinedDayKey: String?
    /// Null for members, and from servers before migration 013.
    var keeperSince: Date?
}

struct DepositDTO: Codable {
    let id: UUID
    let huddleId: UUID
    /// Null once the author deletes their account (`on delete set null`) —
    /// the photo is permanent and renders as "Former member".
    let authorId: UUID?
    var storagePath: String
    var caption: String?
    var dayKey: String
    var createdAt: Date?
    /// The photo key sealed with the huddle key (`PhotoCrypto`); optional so a
    /// pre-encryption row can't fail decoding of the whole response.
    var wrappedPhotoKey: String?
    var encVersion: Int?
    /// "photo" or "video"; optional, like the next two, so a server from
    /// before migration 013 still decodes (every deposit a photo).
    var mediaType: String?
    /// A video's clip: its poster's `storagePath` ending in .mp4.
    var videoPath: String?
    var durationMs: Int?
}

struct ReactionDTO: Codable {
    let id: UUID
    let depositId: UUID
    let userId: UUID
    var emoji: String
    var createdAt: Date?
}

struct CommentDTO: Codable {
    let id: UUID
    let depositId: UUID
    /// Null once the commenter deletes their account, like `DepositDTO.authorId`.
    let userId: UUID?
    var body: String
    var createdAt: Date?
}

/// Projection used by the huddle list's "who posted today" read.
struct DepositorDTO: Codable {
    let huddleId: UUID
    let authorId: UUID?
}

struct SkipDTO: Codable {
    let id: UUID
    let huddleId: UUID
    let userId: UUID
    var dayKey: String
}

struct ReportDTO: Codable {
    let id: UUID
    let reporterId: UUID
}

/// `user_keys`: a user's E2EE identity public key.
struct UserKeyDTO: Codable {
    let userId: UUID
    var publicKey: String
}

/// `huddle_keys`: one member's wrapped copy of a huddle key.
struct HuddleKeyDTO: Codable {
    let huddleId: UUID
    let userId: UUID
    var wrappedKey: String
    var ephemeralPublicKey: String
    var recipientPublicKey: String
}

/// A row of the `huddle_key_recipients` RPC: a member without a working copy
/// of the key (joined before invites carried it, or replaced their identity key).
struct KeyRecipientDTO: Codable {
    let userId: UUID
    var publicKey: String
}

/// A row of the `huddle_invite` RPC: what a member's app needs to show the
/// huddle's invite code.
struct HuddleInviteDTO: Codable {
    /// The code's lookup part (`huddles.invite_code`).
    let lookup: String
    /// The huddle still runs on an old secret-less code.
    let legacy: Bool
    /// The code's secret sealed with the huddle key; nil when the huddle has
    /// no active invite (an old code, or one dropped with a replaced key).
    let sealedSecret: String?
}

/// A row of `redeem_huddle_invite`: the huddle just joined, and its key
/// sealed for the invite code.
struct InviteRedemptionDTO: Codable {
    let joinedHuddleId: UUID
    let inviteSalt: String
    let inviteSealedKey: String
}

/// `device_tokens`: one device registered for push notifications.
struct DeviceTokenDTO: Codable {
    let userId: UUID
    let token: String
    /// "sandbox" or "production" (`PushEnvironment`).
    let environment: String
}

/// `terms_acceptances`: one account's agreement to one version of the Terms.
/// `recorded_at` is the server's to set, so it isn't here.
struct TermsAcceptanceDTO: Codable {
    let userId: UUID
    let version: String
    let acceptedAt: Date
    let appVersion: String?
}

struct BlockDTO: Codable {
    let id: UUID
    let blockerId: UUID
    let blockedId: UUID
}

/// Body of the `delete-account` edge function. Without a code (Apple
/// couldn't confirm the person) the key is left out and the account is
/// deleted without revoking.
struct DeleteAccountRequestDTO: Encodable {
    let authorizationCode: String?
}

extension Array where Element == UUID {
    /// PostgREST `in.(a,b,c)` filter value.
    var postgrestInList: String {
        "in.(" + map(\.uuidString).joined(separator: ",") + ")"
    }

    /// An `in.(…)` filter costs ~37 URL bytes per id and gateways refuse
    /// request lines past ~8 KB, so id lists that grow with history are
    /// queried in chunks.
    func chunked(by size: Int = 100) -> [[UUID]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

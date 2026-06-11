import Foundation

// Wire types for PostgREST rows. Property names are chosen so the client's
// convertFromSnakeCase/convertToSnakeCase strategies map them exactly
// (always `Id`, never `ID`, in multi-word names).

struct ProfileDTO: Codable {
    let id: UUID
    var displayName: String
    var avatarColorHex: String
    var createdAt: Date?
}

struct VaultDTO: Codable {
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
    let vaultId: UUID
    var role: String
    var skipTokensRemaining: Int
    var joinedAt: Date?
}

struct DepositDTO: Codable {
    let id: UUID
    let vaultId: UUID
    let authorId: UUID
    var storagePath: String
    var caption: String?
    var dayKey: String
    var createdAt: Date?
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
    let userId: UUID
    var body: String
    var createdAt: Date?
}

struct SkipDTO: Codable {
    let id: UUID
    let vaultId: UUID
    let userId: UUID
    var dayKey: String
}

extension Array where Element == UUID {
    /// PostgREST `in.(a,b,c)` filter value.
    var postgrestInList: String {
        "in.(" + map(\.uuidString).joined(separator: ",") + ")"
    }
}

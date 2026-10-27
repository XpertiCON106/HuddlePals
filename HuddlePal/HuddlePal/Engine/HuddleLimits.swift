import Foundation

/// The free plan's and HuddlePals Plus's limits. Postgres enforces every one
/// (supabase migration 013: create_huddle, huddle_join_rule, the deposits and
/// Storage insert policies); the app mirrors them to explain a refusal before
/// it happens, and the mock backend to behave like the server.
enum HuddleLimits {
    /// Huddles an account can keep (be the keeper of), inherited ones included.
    static let freeHuddlesKept = 3
    static let plusHuddlesKept = 10
    /// Members a huddle takes, the keeper included, by the keeper's plan.
    static let freeMembers = 4
    static let plusMembers = 10
    /// Huddles one account can be in at all, kept and joined.
    static let huddlesJoined = 25
    /// Days the free plan opens in the archive: today and the 29 before it.
    static let freeArchiveDays = 30
    /// A video drop's longest length.
    static let maxVideoDuration: TimeInterval = 6
    /// A video clip's largest size before encryption: comfortably under the
    /// Storage bucket's 5 MB, which counts the ciphertext.
    static let maxVideoBytes = 4_000_000
}

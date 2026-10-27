import Foundation
import SwiftData

enum DepositError: LocalizedError {
    case alreadyDepositedToday
    /// HuddlePals+ wasn't on when the video went up (it ended since it
    /// was recorded): Storage or the database refused it, and nothing was
    /// posted.
    case videoNeedsPlus
    case videoTooLarge

    var errorDescription: String? {
        switch self {
        case .alreadyDepositedToday:
            "That day's photo is already in the huddle. One a day — forever."
        case .videoNeedsPlus:
            "Your HuddlePals+ has ended, so this video can't be posted. Nothing was posted: take a photo for today instead, or renew Plus to post the video."
        case .videoTooLarge:
            "That clip is too large to post. Record it again."
        }
    }
}

/// A video drop's clip, posted with its poster at `localImagePath`.
struct DepositVideo: Equatable {
    /// Documents-relative, like `localImagePath`: the poster's path ending
    /// in .mp4.
    let localVideoPath: String
    let durationMs: Int
}

@MainActor
protocol DepositServiceProtocol: AnyObject {
    func deposits(in huddle: Huddle) async throws -> [Deposit]
    /// Creates a deposit for the given dayKey. Once-and-permanent: throws
    /// `DepositError.alreadyDepositedToday` if the author already has one
    /// for that day. Deposits can never be edited, replaced, or deleted.
    /// `wrappedPhotoKey` comes from `MediaServiceProtocol.saveDepositPhoto`
    /// or `saveDepositVideo` (required live, where every deposit is
    /// end-to-end encrypted). With `video`, it's a video drop whose poster is
    /// at `localImagePath`; posting one takes Plus, and without it throws
    /// `DepositError.videoNeedsPlus`.
    @discardableResult
    func createDeposit(
        in huddle: Huddle,
        author: User,
        localImagePath: String,
        wrappedPhotoKey: String?,
        caption: String?,
        dayKey: String,
        video: DepositVideo?
    ) async throws -> Deposit
    /// Who has deposited on `dayKey`, keyed by huddle id (every requested
    /// huddle gets an entry). A lightweight read for the huddle list: it does
    /// not sync history into the local store — `deposits(in:)` owns that.
    func depositorIDs(in huddles: [Huddle], dayKey: String) async throws -> [UUID: Set<UUID>]
    func toggleReaction(_ emoji: String, on deposit: Deposit, by user: User) async throws
    @discardableResult
    func addComment(_ text: String, to deposit: Deposit, by user: User) async throws -> Comment
}

extension DepositServiceProtocol {
    /// A photo.
    @discardableResult
    func createDeposit(
        in huddle: Huddle,
        author: User,
        localImagePath: String,
        wrappedPhotoKey: String?,
        caption: String?,
        dayKey: String
    ) async throws -> Deposit {
        try await createDeposit(
            in: huddle, author: author, localImagePath: localImagePath,
            wrappedPhotoKey: wrappedPhotoKey, caption: caption, dayKey: dayKey, video: nil
        )
    }
}

// MARK: - Mock

@MainActor
final class MockDepositService: DepositServiceProtocol {
    private let context: ModelContext
    private let engine: HuddleEngine
    /// Who has Plus: a video takes it, as the deposits insert policy says.
    private let plans: MockPlanLedger

    init(context: ModelContext, engine: HuddleEngine, plans: MockPlanLedger) {
        self.context = context
        self.engine = engine
        self.plans = plans
    }

    func deposits(in huddle: Huddle) async throws -> [Deposit] {
        // TODO: BACKEND — page deposits from Supabase ordered by day_key
        // desc and hydrate image URLs from Storage; cache locally.
        huddle.deposits.sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func createDeposit(
        in huddle: Huddle,
        author: User,
        localImagePath: String,
        wrappedPhotoKey: String?,
        caption: String?,
        dayKey: String,
        video: DepositVideo?
    ) async throws -> Deposit {
        // Once-and-permanent: a day that already holds this member's photo
        // is closed forever.
        guard !huddle.deposits.contains(where: {
            $0.author?.id == author.id && $0.dayKey == dayKey
        }) else {
            throw DepositError.alreadyDepositedToday
        }
        if video != nil, !plans.hasPlus(author.id) {
            throw DepositError.videoNeedsPlus
        }
        let deposit = Deposit(
            huddle: huddle,
            author: author,
            localImagePath: localImagePath,
            caption: HuddleEngine.sanitizedCaption(caption),
            dayKey: dayKey,
            wrappedPhotoKey: wrappedPhotoKey,
            mediaType: video == nil ? .photo : .video,
            localVideoPath: video?.localVideoPath,
            durationMs: video?.durationMs
        )
        context.insert(deposit)
        try context.save()
        return deposit
    }

    func depositorIDs(in huddles: [Huddle], dayKey: String) async throws -> [UUID: Set<UUID>] {
        Dictionary(
            huddles.map { huddle in
                (huddle.id, Set(huddle.deposits.filter { $0.dayKey == dayKey }.compactMap { $0.author?.id }))
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func toggleReaction(_ emoji: String, on deposit: Deposit, by user: User) async throws {
        // TODO: BACKEND — toggle via delete-or-insert on a `reactions` table
        // with a (deposit_id, user_id, emoji) unique constraint.
        if let existing = deposit.reactions.first(where: {
            $0.user?.id == user.id && $0.emoji == emoji
        }) {
            context.delete(existing)
        } else {
            context.insert(Reaction(deposit: deposit, user: user, emoji: emoji))
        }
        try context.save()
    }

    @discardableResult
    func addComment(_ text: String, to deposit: Deposit, by user: User) async throws -> Comment {
        // TODO: BACKEND — insert into `comments`; realtime subscription
        // pushes new comments to other members.
        let comment = Comment(
            deposit: deposit,
            user: user,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        context.insert(comment)
        try context.save()
        return comment
    }
}

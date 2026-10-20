import Foundation
import SwiftData

enum DepositError: LocalizedError {
    case alreadyDepositedToday

    var errorDescription: String? {
        switch self {
        case .alreadyDepositedToday:
            "That day's photo is already in the huddle. One a day — forever."
        }
    }
}

@MainActor
protocol DepositServiceProtocol: AnyObject {
    func deposits(in huddle: Huddle) async throws -> [Deposit]
    /// Creates a deposit for the given dayKey. Once-and-permanent: throws
    /// `DepositError.alreadyDepositedToday` if the author already has one
    /// for that day. Deposits can never be edited, replaced, or deleted.
    /// `wrappedPhotoKey` comes from `MediaServiceProtocol.saveDepositPhoto`
    /// (required live, where every photo is end-to-end encrypted).
    @discardableResult
    func createDeposit(
        in huddle: Huddle,
        author: User,
        localImagePath: String,
        wrappedPhotoKey: String?,
        caption: String?,
        dayKey: String
    ) async throws -> Deposit
    /// Who has deposited on `dayKey`, keyed by huddle id (every requested
    /// huddle gets an entry). A lightweight read for the huddle list: it does
    /// not sync history into the local store — `deposits(in:)` owns that.
    func depositorIDs(in huddles: [Huddle], dayKey: String) async throws -> [UUID: Set<UUID>]
    func toggleReaction(_ emoji: String, on deposit: Deposit, by user: User) async throws
    @discardableResult
    func addComment(_ text: String, to deposit: Deposit, by user: User) async throws -> Comment
}

// MARK: - Mock

@MainActor
final class MockDepositService: DepositServiceProtocol {
    private let context: ModelContext
    private let engine: HuddleEngine

    init(context: ModelContext, engine: HuddleEngine) {
        self.context = context
        self.engine = engine
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
        dayKey: String
    ) async throws -> Deposit {
        // Once-and-permanent: a day that already holds this member's photo
        // is closed forever.
        guard !huddle.deposits.contains(where: {
            $0.author?.id == author.id && $0.dayKey == dayKey
        }) else {
            throw DepositError.alreadyDepositedToday
        }
        let deposit = Deposit(
            huddle: huddle,
            author: author,
            localImagePath: localImagePath,
            caption: HuddleEngine.sanitizedCaption(caption),
            dayKey: dayKey,
            wrappedPhotoKey: wrappedPhotoKey
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

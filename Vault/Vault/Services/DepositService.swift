import Foundation
import SwiftData

@MainActor
protocol DepositServiceProtocol: AnyObject {
    func deposits(in vault: Vault) async throws -> [Deposit]
    /// Creates a deposit for the given dayKey. A second deposit by the same
    /// author in the same vault on the same day *replaces* the first.
    @discardableResult
    func createDeposit(
        in vault: Vault,
        author: User,
        localImagePath: String,
        caption: String?,
        dayKey: String
    ) async throws -> Deposit
    func toggleReaction(_ emoji: String, on deposit: Deposit, by user: User) async throws
    @discardableResult
    func addComment(_ text: String, to deposit: Deposit, by user: User) async throws -> Comment
}

// MARK: - Mock

@MainActor
final class MockDepositService: DepositServiceProtocol {
    private let context: ModelContext
    private let engine: VaultEngine
    private let media: MediaServiceProtocol

    init(context: ModelContext, engine: VaultEngine, media: MediaServiceProtocol) {
        self.context = context
        self.engine = engine
        self.media = media
    }

    func deposits(in vault: Vault) async throws -> [Deposit] {
        // TODO: BACKEND — page deposits from Supabase ordered by day_key
        // desc and hydrate image URLs from Storage; cache locally.
        vault.deposits.sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func createDeposit(
        in vault: Vault,
        author: User,
        localImagePath: String,
        caption: String?,
        dayKey: String
    ) async throws -> Deposit {
        // TODO: BACKEND — upload the image to Supabase Storage, then insert
        // the deposit row; the (vault, author, day_key) unique constraint
        // makes the replacement an upsert.
        if let replaced = vault.deposits.first(where: {
            $0.author?.id == author.id && $0.dayKey == dayKey
        }) {
            media.deleteImage(at: replaced.localImagePath)
            context.delete(replaced)
        }
        let deposit = Deposit(
            vault: vault,
            author: author,
            localImagePath: localImagePath,
            caption: VaultEngine.sanitizedCaption(caption),
            dayKey: dayKey
        )
        context.insert(deposit)
        try context.save()
        return deposit
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

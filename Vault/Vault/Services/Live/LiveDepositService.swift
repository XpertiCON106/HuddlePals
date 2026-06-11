import Foundation
import SwiftData

@MainActor
final class LiveDepositService: DepositServiceProtocol {
    private let client: SupabaseClient
    private let store: SupabaseStore

    init(client: SupabaseClient, store: SupabaseStore) {
        self.client = client
        self.store = store
    }

    func deposits(in vault: Vault) async throws -> [Deposit] {
        let depositDTOs: [DepositDTO] = try await client.select("deposits", query: [
            URLQueryItem(name: "vault_id", value: "eq.\(vault.id.uuidString)"),
        ])
        var reactionDTOs: [ReactionDTO] = []
        var commentDTOs: [CommentDTO] = []
        let depositIDs = depositDTOs.map(\.id)
        if !depositIDs.isEmpty {
            reactionDTOs = try await client.select("reactions", query: [
                URLQueryItem(name: "deposit_id", value: depositIDs.postgrestInList),
            ])
            commentDTOs = try await client.select("comments", query: [
                URLQueryItem(name: "deposit_id", value: depositIDs.postgrestInList),
            ])
        }
        try store.applyDeposits(depositDTOs, reactions: reactionDTOs, comments: commentDTOs, to: vault)
        try store.save()
        return vault.deposits.sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func createDeposit(
        in vault: Vault,
        author: User,
        localImagePath: String,
        caption: String?,
        dayKey: String
    ) async throws -> Deposit {
        struct NewDeposit: Encodable {
            let vaultId: UUID
            let authorId: UUID
            let storagePath: String
            let caption: String?
            let dayKey: String
        }
        // The (vault, author, day_key) unique constraint turns this upsert
        // into the same-day replacement: Postgres updates the existing row
        // in place (same id), atomically.
        let rows: [DepositDTO] = try await client.upsert(
            "deposits",
            values: NewDeposit(
                vaultId: vault.id,
                authorId: author.id,
                storagePath: LiveMediaService.storagePath(forCachePath: localImagePath),
                caption: VaultEngine.sanitizedCaption(caption),
                dayKey: dayKey
            ),
            onConflict: "vault_id,author_id,day_key"
        )
        guard let dto = rows.first else {
            throw SupabaseClient.ClientError.http(status: 500, message: "deposit insert returned nothing")
        }
        let deposit = try store.applyDeposit(dto, to: vault, author: author)
        try store.save()
        return deposit
    }

    func toggleReaction(_ emoji: String, on deposit: Deposit, by user: User) async throws {
        if let mine = deposit.reactions.first(where: { $0.user?.id == user.id && $0.emoji == emoji }) {
            try await client.delete("reactions", query: [
                URLQueryItem(name: "id", value: "eq.\(mine.id.uuidString)"),
            ])
            store.deleteReactionLocally(mine)
        } else {
            struct NewReaction: Encodable {
                let depositId: UUID
                let userId: UUID
                let emoji: String
            }
            let rows: [ReactionDTO] = try await client.upsert(
                "reactions",
                values: NewReaction(depositId: deposit.id, userId: user.id, emoji: emoji),
                onConflict: "deposit_id,user_id,emoji"
            )
            if let dto = rows.first {
                store.insertReactionLocally(dto, deposit: deposit, user: user)
            }
        }
        try store.save()
    }

    @discardableResult
    func addComment(_ text: String, to deposit: Deposit, by user: User) async throws -> Comment {
        struct NewComment: Encodable {
            let depositId: UUID
            let userId: UUID
            let body: String
        }
        let rows: [CommentDTO] = try await client.upsert(
            "comments",
            values: NewComment(
                depositId: deposit.id,
                userId: user.id,
                body: text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
        guard let dto = rows.first else {
            throw SupabaseClient.ClientError.http(status: 500, message: "comment insert returned nothing")
        }
        let comment = store.insertCommentLocally(dto, deposit: deposit, user: user)
        try store.save()
        return comment
    }
}

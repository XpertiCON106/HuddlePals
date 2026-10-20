import Foundation
import SwiftData

@MainActor
final class LiveDepositService: DepositServiceProtocol {
    private let client: SupabaseClient
    private let store: SupabaseStore
    private let keyring: LivePhotoKeyring

    init(client: SupabaseClient, store: SupabaseStore, keyring: LivePhotoKeyring) {
        self.client = client
        self.store = store
        self.keyring = keyring
    }

    func deposits(in huddle: Huddle) async throws -> [Deposit] {
        // Opening a huddle: get its key if this device lacks it, and share it
        // with any member still waiting — before the photos render.
        await keyring.sync(huddleIDs: [huddle.id])
        let depositDTOs: [DepositDTO] = try await client.select("deposits", query: [
            URLQueryItem(name: "huddle_id", value: "eq.\(huddle.id.uuidString)"),
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
        // Pull any referenced profile we don't have yet (e.g. a member who
        // joined since the last huddle-list sync), so a current member is
        // never shown as "Former member". RLS returns nothing for people who
        // left or deleted their account — those stay author-less by design.
        let referenced = Set(
            depositDTOs.compactMap(\.authorId)
                + reactionDTOs.map(\.userId)
                + commentDTOs.compactMap(\.userId)
        )
        let missing = try store.missingUserIDs(in: referenced)
        if !missing.isEmpty {
            let profiles: [ProfileDTO] = try await client.select("profiles", query: [
                URLQueryItem(name: "id", value: missing.postgrestInList),
            ])
            for profile in profiles {
                try store.apply(profile)
            }
        }
        try store.applyDeposits(depositDTOs, reactions: reactionDTOs, comments: commentDTOs, to: huddle)
        try store.save()
        return huddle.deposits.sorted { $0.createdAt > $1.createdAt }
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
        struct NewDeposit: Encodable {
            let huddleId: UUID
            let authorId: UUID
            let storagePath: String
            let wrappedPhotoKey: String
            let encVersion: Int
            let caption: String?
            let dayKey: String
        }
        // Every live photo is end-to-end encrypted (the DB refuses one that
        // isn't); a missing key means the upload never went through
        // `saveDepositPhoto`.
        guard let wrappedPhotoKey else { throw PhotoKeyError.huddleKeyUnavailable }
        // Once-and-permanent: plain insert — the (huddle, author, day_key)
        // unique constraint makes a second attempt fail atomically.
        let rows: [DepositDTO]
        do {
            rows = try await client.upsert(
                "deposits",
                values: NewDeposit(
                    huddleId: huddle.id,
                    authorId: author.id,
                    storagePath: LiveMediaService.storagePath(forCachePath: localImagePath),
                    wrappedPhotoKey: wrappedPhotoKey,
                    encVersion: PhotoCrypto.formatVersion,
                    caption: HuddleEngine.sanitizedCaption(caption),
                    dayKey: dayKey
                )
            )
        } catch let SupabaseClient.ClientError.http(status, message) {
            if status == 409 || message.contains("duplicate key") {
                throw DepositError.alreadyDepositedToday
            }
            throw SupabaseClient.ClientError.http(status: status, message: message)
        }
        guard let dto = rows.first else {
            throw SupabaseClient.ClientError.http(status: 500, message: "deposit insert returned nothing")
        }
        let deposit = try store.applyDeposit(dto, to: huddle, author: author)
        try store.save()
        return deposit
    }

    /// One request for every huddle: just (huddle_id, author_id) for one day.
    func depositorIDs(in huddles: [Huddle], dayKey: String) async throws -> [UUID: Set<UUID>] {
        var result = Dictionary(huddles.map { ($0.id, Set<UUID>()) }, uniquingKeysWith: { first, _ in first })
        guard !huddles.isEmpty else { return result }
        let rows: [DepositorDTO] = try await client.select("deposits", query: [
            URLQueryItem(name: "select", value: "huddle_id,author_id"),
            URLQueryItem(name: "huddle_id", value: huddles.map(\.id).postgrestInList),
            URLQueryItem(name: "day_key", value: "eq.\(dayKey)"),
        ])
        for row in rows {
            guard let author = row.authorId else { continue }
            result[row.huddleId, default: []].insert(author)
        }
        return result
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

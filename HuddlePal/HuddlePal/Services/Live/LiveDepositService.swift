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
        // with any member who has no working copy — before the photos render.
        await keyring.sync(huddleIDs: [huddle.id])
        // A huddle still on an old secret-less code quietly gets a new-format
        // invite, retiring the old code. Off the photos' critical path.
        let keyring = keyring
        let huddleID = huddle.id
        Task { _ = try? await keyring.inviteCode(for: huddleID) }
        // Complete sets, paged and chunked: applyDeposits prunes whatever is
        // missing, so a truncated read would delete real history locally.
        let depositDTOs: [DepositDTO] = try await client.selectAll("deposits", query: [
            URLQueryItem(name: "huddle_id", value: "eq.\(huddle.id.uuidString)"),
        ])
        var reactionDTOs: [ReactionDTO] = []
        var commentDTOs: [CommentDTO] = []
        for chunk in depositDTOs.map(\.id).chunked() {
            reactionDTOs += try await client.selectAll("reactions", query: [
                URLQueryItem(name: "deposit_id", value: chunk.postgrestInList),
            ])
            commentDTOs += try await client.selectAll("comments", query: [
                URLQueryItem(name: "deposit_id", value: chunk.postgrestInList),
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
        for chunk in try store.missingUserIDs(in: referenced).chunked() {
            let profiles: [ProfileDTO] = try await client.select("profiles", query: [
                URLQueryItem(name: "id", value: chunk.postgrestInList),
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
        dayKey: String,
        video: DepositVideo?
    ) async throws -> Deposit {
        struct NewDeposit: Encodable {
            let huddleId: UUID
            let authorId: UUID
            let storagePath: String
            let wrappedPhotoKey: String
            let encVersion: Int
            let caption: String?
            let dayKey: String
            /// A video's only (nil is left out): a photo row is exactly
            /// what it was before migration 013.
            let mediaType: String?
            let videoPath: String?
            let durationMs: Int?
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
                    dayKey: dayKey,
                    mediaType: video.map { _ in DepositMediaType.video.rawValue },
                    videoPath: video.map { LiveMediaService.storagePath(forCachePath: $0.localVideoPath) },
                    durationMs: video?.durationMs
                )
            )
        } catch let SupabaseClient.ClientError.http(status, message) {
            if status == 409 || message.contains("duplicate key") {
                throw DepositError.alreadyDepositedToday
            }
            // The insert policy takes a video only with Plus (migration 013).
            if video != nil, message.contains("row-level security") {
                throw DepositError.videoNeedsPlus
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

    /// Saved here first, so it shows everywhere at once; the server catches
    /// up. If it can't, the change is undone here and the error thrown.
    func toggleReaction(_ emoji: String, on deposit: Deposit, by user: User) async throws {
        if let mine = deposit.reactions.first(where: { $0.user?.id == user.id && $0.emoji == emoji }) {
            let id = mine.id
            let createdAt = mine.createdAt
            store.deleteReactionLocally(mine)
            try store.save()
            store.withdrawnIDs.insert(id)
            defer { store.withdrawnIDs.remove(id) }
            do {
                try await client.delete("reactions", query: [
                    URLQueryItem(name: "id", value: "eq.\(id.uuidString)"),
                ])
            } catch {
                store.insertReactionLocally(id: id, emoji: emoji, createdAt: createdAt, deposit: deposit, user: user)
                try? store.save()
                throw error
            }
        } else {
            struct NewReaction: Encodable {
                let id: UUID
                let depositId: UUID
                let userId: UUID
                let emoji: String
            }
            let reaction = store.insertReactionLocally(id: UUID(), emoji: emoji, createdAt: .now, deposit: deposit, user: user)
            let id = reaction.id
            try store.save()
            store.pendingIDs.insert(id)
            defer { store.pendingIDs.remove(id) }
            do {
                let _: [ReactionDTO] = try await client.upsert(
                    "reactions",
                    values: NewReaction(id: id, depositId: deposit.id, userId: user.id, emoji: emoji),
                    onConflict: "deposit_id,user_id,emoji",
                    // Already there (a stale screen, a double tap): nothing to do.
                    ignoreDuplicates: true
                )
            } catch {
                store.deleteReactionLocally(reaction)
                try? store.save()
                throw error
            }
        }
    }

    /// Saved here first, so it shows everywhere at once; the server catches
    /// up. If it can't, the comment comes off again and the error is thrown.
    @discardableResult
    func addComment(_ text: String, to deposit: Deposit, by user: User) async throws -> Comment {
        struct NewComment: Encodable {
            let id: UUID
            let depositId: UUID
            let userId: UUID
            let body: String
        }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let comment = store.insertCommentLocally(id: UUID(), text: body, createdAt: .now, deposit: deposit, user: user)
        let id = comment.id
        try store.save()
        store.pendingIDs.insert(id)
        defer { store.pendingIDs.remove(id) }
        do {
            let rows: [CommentDTO] = try await client.upsert(
                "comments",
                values: NewComment(id: id, depositId: deposit.id, userId: user.id, body: body)
            )
            if let created = rows.first?.createdAt { comment.createdAt = created }
            try store.save()
            return comment
        } catch {
            store.deleteCommentLocally(comment)
            try? store.save()
            throw error
        }
    }
}

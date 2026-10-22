import CryptoKit
import Foundation

enum PhotoKeyError: LocalizedError {
    case huddleKeyUnavailable
    case photoTooLarge

    var errorDescription: String? {
        switch self {
        case .huddleKeyUnavailable:
            "This huddle's key isn't on this device yet, so its photos can't be posted or opened here. Try again in a moment."
        case .photoTooLarge:
            "That photo is too large to upload."
        }
    }
}

/// Live end-to-end key management (the scheme is in `PhotoCrypto` and
/// `InviteCrypto`): this device's identity key, the huddle keys it has
/// unwrapped and the invite codes it has opened — in memory only, never
/// UserDefaults or SwiftData — plus issuing and redeeming invites, and
/// sharing huddle keys with members who joined before invites carried them.
/// Every network step is best effort: the next foreground or huddle open
/// retries it.
@MainActor
final class LivePhotoKeyring {
    private let client: SupabaseClient
    private let session: AppSession
    private let identityStore: IdentityKeyStoring

    private var identity: (userID: UUID, key: Curve25519.KeyAgreement.PrivateKey)?
    /// The user whose public key the server is known to hold, this launch.
    private var publishedUserID: UUID?
    private var huddleKeys: [UUID: SymmetricKey] = [:]
    /// Full invite codes (with their secrets), opened or issued this launch.
    private var inviteCodes: [UUID: InviteCode] = [:]
    /// Huddles whose key came from an invite and whose own wrapped copy the
    /// server hasn't confirmed yet. `sync` retries until it has.
    private var unsavedOwnCopies: Set<UUID> = []

    init(client: SupabaseClient, session: AppSession, identityStore: IdentityKeyStoring = IdentityKeychain()) {
        self.client = client
        self.session = session
        self.identityStore = identityStore
    }

    // MARK: - Identity

    /// Loads — or, on this device's first sign-in, creates — the user's
    /// identity key and makes sure the server holds its public half.
    func ensureIdentity(for userID: UUID) async {
        guard publishedUserID != userID, let key = localIdentity(for: userID) else { return }
        let mine = PhotoCrypto.encode(key.publicKey)
        do {
            let rows: [UserKeyDTO] = try await client.select("user_keys", query: [
                URLQueryItem(name: "user_id", value: "eq.\(userID.uuidString)"),
            ])
            if rows.first?.publicKey != mine {
                // No key yet — or the server holds another one (this device
                // lost its key, or another device without iCloud Keychain
                // published its own). This device can only open copies
                // wrapped for its own key, so publish it: copies wrapped for
                // the old one go stale, and members' apps re-share.
                let _: [UserKeyDTO] = try await client.upsert(
                    "user_keys",
                    values: UserKeyDTO(userId: userID, publicKey: mine),
                    onConflict: "user_id"
                )
            }
            publishedUserID = userID
        } catch {
            // Retried by the next sync.
        }
    }

    private func localIdentity(for userID: UUID) -> Curve25519.KeyAgreement.PrivateKey? {
        if let identity, identity.userID == userID { return identity.key }
        let key: Curve25519.KeyAgreement.PrivateKey
        if let stored = identityStore.load(for: userID) {
            key = stored
        } else {
            let fresh = Curve25519.KeyAgreement.PrivateKey()
            // Never publish a key that isn't safely stored: the next launch
            // would make another one and strand every copy wrapped for this.
            guard identityStore.save(fresh, for: userID) else { return nil }
            key = fresh
        }
        identity = (userID, key)
        return key
    }

    // MARK: - Huddle keys

    /// A huddle key this device already holds — no network; the display path.
    func cachedHuddleKey(for huddleID: UUID) -> SymmetricKey? {
        huddleKeys[huddleID]
    }

    /// The key to seal a new photo with, syncing first if it isn't here yet.
    func huddleKeyForUpload(_ huddleID: UUID) async -> SymmetricKey? {
        if let key = huddleKeys[huddleID] { return key }
        await sync(huddleIDs: [huddleID])
        return huddleKeys[huddleID]
    }

    /// The foreground / huddle-open pass: unwrap this user's copies, create the
    /// first key of a huddle that has none (normally one just created), and
    /// wrap each held key for the members waiting for it.
    func sync(huddleIDs: [UUID]) async {
        guard !huddleIDs.isEmpty, let userID = await client.currentUserID else { return }
        await ensureIdentity(for: userID)
        guard publishedUserID == userID, let identity = localIdentity(for: userID) else { return }
        await saveOwnCopies(userID: userID, identity: identity)
        let myPublicKey = PhotoCrypto.encode(identity.publicKey)
        var gained = false

        let missing = huddleIDs.filter { huddleKeys[$0] == nil }
        if !missing.isEmpty, let rows: [HuddleKeyDTO] = try? await client.select("huddle_keys", query: [
            URLQueryItem(name: "user_id", value: "eq.\(userID.uuidString)"),
            URLQueryItem(name: "huddle_id", value: missing.postgrestInList),
        ]) {
            // A copy wrapped for an older key of ours can't be opened; it
            // stays until a member re-shares it for the current one.
            for row in rows where row.recipientPublicKey == myPublicKey {
                guard let key = try? PhotoCrypto.unwrapHuddleKey(
                    .init(wrappedKey: row.wrappedKey, ephemeralPublicKey: row.ephemeralPublicKey),
                    with: identity, huddleID: row.huddleId, recipientID: userID
                ) else { continue }
                huddleKeys[row.huddleId] = key
                gained = true
            }
            let held = Set(rows.map(\.huddleId))
            for huddleID in missing where !held.contains(huddleID) {
                if await createFirstHuddleKey(huddleID, userID: userID, identity: identity) {
                    gained = true
                }
            }
        }

        for huddleID in huddleIDs {
            if let key = huddleKeys[huddleID] {
                await share(key, huddleID: huddleID)
            }
        }
        // Lets photos that showed the locked placeholder try again.
        if gained { session.photoKeysVersion += 1 }
    }

    /// The huddle's first key, wrapped for this user. The RPC refuses (false)
    /// once any member holds a copy — a huddle key is shared, never replaced.
    /// (A member who joined with an invite already has the key; one who
    /// joined with an old code gets it from `share` on a member's device.)
    private func createFirstHuddleKey(
        _ huddleID: UUID,
        userID: UUID,
        identity: Curve25519.KeyAgreement.PrivateKey
    ) async -> Bool {
        let key = PhotoCrypto.makeHuddleKey()
        guard let wrapped = try? PhotoCrypto.wrapHuddleKey(
            key, for: identity.publicKey, huddleID: huddleID, recipientID: userID
        ) else { return false }
        let created: Bool? = try? await client.rpc("init_huddle_key", params: [
            "p_huddle": huddleID.uuidString,
            "p_wrapped_key": wrapped.wrappedKey,
            "p_ephemeral_public_key": wrapped.ephemeralPublicKey,
            "p_recipient_public_key": PhotoCrypto.encode(identity.publicKey),
        ])
        guard created == true else { return false }
        huddleKeys[huddleID] = key
        return true
    }

    /// The fallback for members without a working copy — no copy (joined with
    /// an old code, or their own copy never reached the server) or only a
    /// stale one (they re-keyed): wraps the huddle key for each of them.
    private func share(_ huddleKey: SymmetricKey, huddleID: UUID) async {
        guard let recipients: [KeyRecipientDTO] = try? await client.rpc(
            "huddle_key_recipients", params: ["p_huddle": huddleID.uuidString]
        ) else { return }
        for recipient in recipients {
            guard let publicKey = try? PhotoCrypto.publicKey(from: recipient.publicKey),
                  let wrapped = try? PhotoCrypto.wrapHuddleKey(
                      huddleKey, for: publicKey, huddleID: huddleID, recipientID: recipient.userId
                  )
            else { continue }
            // One at a time: a refused share (say they re-keyed a moment
            // ago) mustn't hold up the other members.
            try? await client.rpcVoid("share_huddle_key", params: [
                "p_huddle": huddleID.uuidString,
                "p_user": recipient.userId.uuidString,
                "p_wrapped_key": wrapped.wrappedKey,
                "p_ephemeral_public_key": wrapped.ephemeralPublicKey,
                "p_recipient_public_key": recipient.publicKey,
            ])
        }
    }

    // MARK: - Invites

    /// The huddle's invite code, for showing and sharing. When the huddle has
    /// no new-format invite — it still runs on an old secret-less code, or
    /// its invite went with a replaced key — this issues one, sealed with the
    /// huddle key, which retires the old code. nil when this device can't
    /// open the huddle's key (or the code) right now.
    func inviteCode(for huddleID: UUID) async throws -> InviteCode? {
        if let code = inviteCodes[huddleID] { return code }
        guard let huddleKey = await huddleKeyForUpload(huddleID) else { return nil }
        // Rarely more than once: another member's app may issue the invite
        // first, or a fresh lookup may already be taken.
        for _ in 0..<3 {
            let rows: [HuddleInviteDTO] = try await client.rpc(
                "huddle_invite", params: ["p_huddle": huddleID.uuidString]
            )
            guard let row = rows.first else { return nil }
            if let sealedSecret = row.sealedSecret {
                let code = try? InviteCrypto.openCode(
                    sealedSecret: sealedSecret, lookup: row.lookup, huddleKey: huddleKey, huddleID: huddleID
                )
                inviteCodes[huddleID] = code
                return code
            }
            let code = InviteCode.generate()
            do {
                let created: Bool = try await client.rpc(
                    "create_huddle_invite", params: try inviteParams(code, huddleKey: huddleKey, huddleID: huddleID)
                )
                if created {
                    inviteCodes[huddleID] = code
                    return code
                }
            } catch let SupabaseClient.ClientError.http(_, message) where message.contains("invite_code_taken") {
                continue
            }
        }
        return nil
    }

    /// The keeper's reset: a new code, and the old one (with its sealed copy
    /// of the huddle key) stops working at once.
    func resetInviteCode(for huddleID: UUID) async throws -> InviteCode {
        guard let huddleKey = await huddleKeyForUpload(huddleID) else { throw PhotoKeyError.huddleKeyUnavailable }
        var attempt = 0
        while true {
            attempt += 1
            let code = InviteCode.generate()
            do {
                try await client.rpcVoid(
                    "reset_huddle_invite", params: try inviteParams(code, huddleKey: huddleKey, huddleID: huddleID)
                )
                inviteCodes[huddleID] = code
                return code
            } catch let SupabaseClient.ClientError.http(_, message) where message.contains("invite_code_taken") && attempt < 3 {
                continue
            }
        }
    }

    private func inviteParams(_ code: InviteCode, huddleKey: SymmetricKey, huddleID: UUID) throws -> [String: String] {
        let sealed = try InviteCrypto.seal(huddleKey, code: code, huddleID: huddleID)
        return [
            "p_huddle": huddleID.uuidString,
            "p_lookup": code.lookup,
            "p_proof": sealed.proof,
            "p_salt": sealed.salt,
            "p_sealed_key": sealed.sealedKey,
            "p_sealed_secret": sealed.sealedSecret,
        ]
    }

    /// Takes the huddle key from a redeemed invite: opened here with the
    /// code's secret, then wrapped for this user and stored as their own copy,
    /// so their access never depends on the invite again. No other member
    /// needs to be online. False if the sealed copy doesn't open.
    func acceptInvite(_ code: InviteCode, redemption: InviteRedemptionDTO) async -> Bool {
        let huddleID = redemption.joinedHuddleId
        guard let key = try? InviteCrypto.openHuddleKey(
            sealedKey: redemption.inviteSealedKey, salt: redemption.inviteSalt, code: code, huddleID: huddleID
        ) else { return false }
        huddleKeys[huddleID] = key
        inviteCodes[huddleID] = code
        unsavedOwnCopies.insert(huddleID)
        if let userID = await client.currentUserID {
            await ensureIdentity(for: userID)
            if publishedUserID == userID, let identity = localIdentity(for: userID) {
                await saveOwnCopies(userID: userID, identity: identity)
            }
        }
        session.photoKeysVersion += 1
        return true
    }

    /// Stores this user's own wrapped copy of each key that came from an
    /// invite. One that fails stays queued for the next sync.
    private func saveOwnCopies(userID: UUID, identity: Curve25519.KeyAgreement.PrivateKey) async {
        for huddleID in unsavedOwnCopies {
            guard let key = huddleKeys[huddleID],
                  let wrapped = try? PhotoCrypto.wrapHuddleKey(
                      key, for: identity.publicKey, huddleID: huddleID, recipientID: userID
                  )
            else { continue }
            do {
                // False means a working copy was already there: done either way.
                let _: Bool = try await client.rpc("save_own_huddle_key", params: [
                    "p_huddle": huddleID.uuidString,
                    "p_wrapped_key": wrapped.wrappedKey,
                    "p_ephemeral_public_key": wrapped.ephemeralPublicKey,
                    "p_recipient_public_key": PhotoCrypto.encode(identity.publicKey),
                ])
                unsavedOwnCopies.remove(huddleID)
            } catch {
                // Retried by the next sync.
            }
        }
    }

    // MARK: - Reports

    /// The key a report discloses: this one photo's own key, when this device
    /// can open the photo; nil otherwise (the report still goes through).
    func disclosedPhotoKey(huddleID: UUID?, wrappedPhotoKey: String?) -> String? {
        guard let huddleID, let wrappedPhotoKey, let huddleKey = huddleKeys[huddleID] else { return nil }
        return try? PhotoCrypto.disclosedPhotoKey(wrappedPhotoKey, huddleKey: huddleKey)
    }

    // MARK: - Session lifecycle

    /// Sign-out: drop what's held in memory. The identity key stays in the
    /// Keychain — deleting it would lose access to every huddle.
    func reset() {
        identity = nil
        publishedUserID = nil
        huddleKeys = [:]
        inviteCodes = [:]
        unsavedOwnCopies = []
    }

    /// Account deletion: the identity key goes too. (Its `user_keys` /
    /// `huddle_keys` rows cascade with the auth user.)
    func forgetIdentity(for userID: UUID) {
        identityStore.delete(for: userID)
        reset()
    }
}

import CryptoKit
import Foundation

enum PhotoKeyError: LocalizedError {
    case huddleKeyUnavailable
    case photoTooLarge

    var errorDescription: String? {
        switch self {
        case .huddleKeyUnavailable:
            "This huddle's key hasn't reached this device yet. It's shared automatically when another member opens HuddlePal — try again soon."
        case .photoTooLarge:
            "That photo is too large to upload."
        }
    }
}

/// Live end-to-end key management (the scheme is in `PhotoCrypto`): this
/// device's identity key, the huddle keys it has unwrapped — in memory only,
/// never UserDefaults or SwiftData — and the automatic sharing of huddle keys
/// with members still waiting for one. Every network step is best effort:
/// the next foreground or huddle open retries it.
@MainActor
final class LivePhotoKeyring {
    private let client: SupabaseClient
    private let session: AppSession
    private let identityStore: IdentityKeyStoring

    private var identity: (userID: UUID, key: Curve25519.KeyAgreement.PrivateKey)?
    /// The user whose public key the server is known to hold, this launch.
    private var publishedUserID: UUID?
    private var huddleKeys: [UUID: SymmetricKey] = [:]

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
    /// once any member holds a copy — a huddle key is shared, never replaced,
    /// so a member who just joined simply keeps waiting for a share.
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

    /// Wraps the huddle key for every member the server says is waiting: no
    /// copy yet (just joined) or only a stale one (they re-keyed).
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
    }

    /// Account deletion: the identity key goes too. (Its `user_keys` /
    /// `huddle_keys` rows cascade with the auth user.)
    func forgetIdentity(for userID: UUID) {
        identityStore.delete(for: userID)
        reset()
    }
}

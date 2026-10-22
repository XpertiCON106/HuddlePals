import CryptoKit
import Foundation

/// The invite layer of end-to-end encryption (`PhotoCrypto` has the rest).
/// An invite code's secret (`InviteCode`) never reaches the server. From it,
/// the inviting and the joining device each derive, with HKDF-SHA256:
///  • the proof: what the joiner shows `redeem_huddle_invite`. The server
///    keeps only its SHA-256, enough to check a code but not to forge one,
///    and the proof opens nothing (a separate derivation from the key below);
///  • the wrapping key, with a random salt stored beside it: AES-GCM seals
///    the huddle key with it into `huddle_invite_keys.sealed_key`.
/// The secret itself is kept on the server sealed with the huddle key
/// (`sealed_secret`), so every member's app can show and share the code.
/// Both derivations are bound to the code's lookup, and the wrapping key to
/// the huddle, so a sealed copy can't be passed off as another huddle's.
/// Wire format: base64 (standard alphabet, padded), like `PhotoCrypto`.
enum InviteCrypto {
    /// What the inviting app uploads; the secret is not part of it.
    struct SealedInvite: Equatable {
        /// The proof itself: the server stores only its SHA-256.
        let proof: String
        /// 32 random bytes: the wrapping key's HKDF salt.
        let salt: String
        /// AES-GCM combined box of the huddle key, under the wrapping key.
        let sealedKey: String
        /// AES-GCM combined box of the secret, under the huddle key.
        let sealedSecret: String
    }

    enum CryptoError: Error {
        case malformed
    }

    /// Domain separation for what's sealed: the huddle key under the
    /// wrapping key, and the secret under the huddle key (which also seals
    /// photo keys, under its own label).
    private static let sealedKeyContext = Data("huddlepal.invite.v1/sealed-key".utf8)

    static func proof(for code: InviteCode) -> String {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: secretKey(code),
            info: Data("huddlepal.invite.v1/proof/\(code.lookup)".utf8),
            outputByteCount: 32
        )
        return rawBytes(of: key).base64EncodedString()
    }

    /// Seals `huddleKey` for whoever holds `code`, and `code`'s secret for
    /// whoever holds `huddleKey`.
    static func seal(_ huddleKey: SymmetricKey, code: InviteCode, huddleID: UUID) throws -> SealedInvite {
        let salt = rawBytes(of: SymmetricKey(size: .bits256))
        let wrapped = try AES.GCM.seal(
            rawBytes(of: huddleKey),
            using: wrappingKey(code, salt: salt, huddleID: huddleID),
            authenticating: sealedKeyContext
        )
        let secret = try AES.GCM.seal(
            Data(code.secret.utf8),
            using: huddleKey,
            authenticating: secretContext(lookup: code.lookup, huddleID: huddleID)
        )
        return SealedInvite(
            proof: proof(for: code),
            salt: salt.base64EncodedString(),
            sealedKey: try combined(wrapped).base64EncodedString(),
            sealedSecret: try combined(secret).base64EncodedString()
        )
    }

    /// The joining side: the huddle key from a redeemed invite. Throws for a
    /// wrong code or a damaged copy.
    static func openHuddleKey(sealedKey: String, salt: String, code: InviteCode, huddleID: UUID) throws -> SymmetricKey {
        guard let box = Data(base64Encoded: sealedKey), let saltBytes = Data(base64Encoded: salt) else {
            throw CryptoError.malformed
        }
        let raw = try AES.GCM.open(
            AES.GCM.SealedBox(combined: box),
            using: wrappingKey(code, salt: saltBytes, huddleID: huddleID),
            authenticating: sealedKeyContext
        )
        guard raw.count == 32 else { throw CryptoError.malformed }
        return SymmetricKey(data: raw)
    }

    /// A member's side: the full code, from the lookup and the sealed secret.
    static func openCode(sealedSecret: String, lookup: String, huddleKey: SymmetricKey, huddleID: UUID) throws -> InviteCode {
        guard let box = Data(base64Encoded: sealedSecret) else { throw CryptoError.malformed }
        let raw = try AES.GCM.open(
            AES.GCM.SealedBox(combined: box),
            using: huddleKey,
            authenticating: secretContext(lookup: lookup, huddleID: huddleID)
        )
        guard let secret = String(data: raw, encoding: .utf8),
              let code = InviteCode(lookup: lookup.uppercased(), secret: secret) else { throw CryptoError.malformed }
        return code
    }

    // MARK: - Helpers

    private static func secretKey(_ code: InviteCode) -> SymmetricKey {
        SymmetricKey(data: Data(code.secret.utf8))
    }

    private static func wrappingKey(_ code: InviteCode, salt: Data, huddleID: UUID) -> SymmetricKey {
        // Lowercased, as in PhotoCrypto: Postgres prints uuids lowercase.
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: secretKey(code),
            salt: salt,
            info: Data("huddlepal.invite.v1/huddle-key/\(huddleID.uuidString.lowercased())/\(code.lookup)".utf8),
            outputByteCount: 32
        )
    }

    private static func secretContext(lookup: String, huddleID: UUID) -> Data {
        Data("huddlepal.invite.v1/secret/\(huddleID.uuidString.lowercased())/\(lookup.uppercased())".utf8)
    }

    private static func rawBytes(of key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    private static func combined(_ box: AES.GCM.SealedBox) throws -> Data {
        guard let combined = box.combined else { throw CryptoError.malformed }
        return combined
    }
}

import CryptoKit
import Foundation

/// End-to-end encryption for deposit photos — CryptoKit primitives only.
/// Three layers, so the backend operator never holds a key that opens a photo:
///  • identity key: each user's Curve25519 key-agreement pair. The private
///    half stays in the user's (iCloud) Keychain; the public half is in
///    `user_keys`.
///  • huddle key: one random 256-bit key per huddle, stored once per member in
///    `huddle_keys`, wrapped to that member's public key (ECIES: ephemeral
///    X25519 agreement → HKDF-SHA256 → AES-GCM).
///  • photo key: a fresh random key per photo. The photo is AES-GCM sealed
///    with it (the `combined` box — nonce ‖ ciphertext ‖ tag — is exactly
///    what Storage holds), and the photo key is sealed with the huddle key onto
///    the deposit row. Per-photo keys let a report disclose one photo without
///    exposing the rest of the huddle.
/// Wire format: every key and box is base64 (standard alphabet, padded).
enum PhotoCrypto {
    /// `deposits.enc_version` for photos sealed this way.
    static let formatVersion = 1

    enum CryptoError: Error {
        case malformed
    }

    // MARK: - Identity keys

    static func encode(_ publicKey: Curve25519.KeyAgreement.PublicKey) -> String {
        publicKey.rawRepresentation.base64EncodedString()
    }

    static func publicKey(from base64: String) throws -> Curve25519.KeyAgreement.PublicKey {
        guard let raw = Data(base64Encoded: base64) else { throw CryptoError.malformed }
        return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
    }

    // MARK: - Huddle keys

    /// One member's copy of a huddle key, as stored in `huddle_keys`.
    struct WrappedHuddleKey: Equatable {
        /// AES-GCM combined box of the 32 huddle-key bytes.
        let wrappedKey: String
        /// The sender's one-time public key for the agreement.
        let ephemeralPublicKey: String
    }

    static func makeHuddleKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    /// Wraps `huddleKey` so only the holder of `recipient`'s private key can
    /// open it. The derivation is bound to the huddle and the recipient, so a
    /// copy can't be replayed onto another huddle or member.
    static func wrapHuddleKey(
        _ huddleKey: SymmetricKey,
        for recipient: Curve25519.KeyAgreement.PublicKey,
        huddleID: UUID,
        recipientID: UUID
    ) throws -> WrappedHuddleKey {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let wrappingKey = deriveWrappingKey(
            secret, ephemeral: ephemeral.publicKey, recipient: recipient,
            huddleID: huddleID, recipientID: recipientID
        )
        let box = try AES.GCM.seal(rawBytes(of: huddleKey), using: wrappingKey)
        return WrappedHuddleKey(
            wrappedKey: try combined(box).base64EncodedString(),
            ephemeralPublicKey: encode(ephemeral.publicKey)
        )
    }

    static func unwrapHuddleKey(
        _ wrapped: WrappedHuddleKey,
        with identity: Curve25519.KeyAgreement.PrivateKey,
        huddleID: UUID,
        recipientID: UUID
    ) throws -> SymmetricKey {
        let ephemeral = try publicKey(from: wrapped.ephemeralPublicKey)
        let secret = try identity.sharedSecretFromKeyAgreement(with: ephemeral)
        let wrappingKey = deriveWrappingKey(
            secret, ephemeral: ephemeral, recipient: identity.publicKey,
            huddleID: huddleID, recipientID: recipientID
        )
        return try openKey(wrapped.wrappedKey, using: wrappingKey)
    }

    private static func deriveWrappingKey(
        _ secret: SharedSecret,
        ephemeral: Curve25519.KeyAgreement.PublicKey,
        recipient: Curve25519.KeyAgreement.PublicKey,
        huddleID: UUID,
        recipientID: UUID
    ) -> SymmetricKey {
        // Lowercased: Postgres renders uuids lowercase, Swift uppercase — the
        // bytes hashed here must never depend on which side printed the id.
        let info = "huddlepal.e2ee.v1/huddle-key/\(huddleID.uuidString.lowercased())/\(recipientID.uuidString.lowercased())"
        return secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: ephemeral.rawRepresentation + recipient.rawRepresentation,
            sharedInfo: Data(info.utf8),
            outputByteCount: 32
        )
    }

    // MARK: - Photos

    /// A photo ready to deposit.
    struct SealedPhoto {
        /// The Storage object: AES-GCM combined box of the JPEG.
        let ciphertext: Data
        /// `deposits.wrapped_photo_key`: the photo key sealed with the huddle key.
        let wrappedPhotoKey: String
    }

    /// Domain separation: the huddle key seals photo keys only under this
    /// label, so anything else ever sealed with it can't pass as a photo key.
    private static let photoKeyContext = Data("huddlepal.e2ee.v1/photo-key".utf8)

    static func sealPhoto(_ jpeg: Data, huddleKey: SymmetricKey) throws -> SealedPhoto {
        let photoKey = SymmetricKey(size: .bits256)
        let photo = try AES.GCM.seal(jpeg, using: photoKey)
        let wrapped = try AES.GCM.seal(rawBytes(of: photoKey), using: huddleKey, authenticating: photoKeyContext)
        return SealedPhoto(
            ciphertext: try combined(photo),
            wrappedPhotoKey: try combined(wrapped).base64EncodedString()
        )
    }

    // MARK: - Videos

    /// A video ready to deposit: its poster (a JPEG) and its clip (an MP4),
    /// each AES-GCM sealed with the same fresh photo key under its own random
    /// nonce. One wrapped key opens both, so a report discloses one key for
    /// the whole video, and an app build from before videos opens the poster
    /// as a photo.
    struct SealedVideo {
        /// The Storage object at `storage_path`.
        let posterCiphertext: Data
        /// The Storage object at `video_path`.
        let clipCiphertext: Data
        /// `deposits.wrapped_photo_key`: the photo key sealed with the huddle key.
        let wrappedPhotoKey: String
    }

    static func sealVideo(poster: Data, clip: Data, huddleKey: SymmetricKey) throws -> SealedVideo {
        let photoKey = SymmetricKey(size: .bits256)
        let wrapped = try AES.GCM.seal(rawBytes(of: photoKey), using: huddleKey, authenticating: photoKeyContext)
        return SealedVideo(
            posterCiphertext: try combined(AES.GCM.seal(poster, using: photoKey)),
            clipCiphertext: try combined(AES.GCM.seal(clip, using: photoKey)),
            wrappedPhotoKey: try combined(wrapped).base64EncodedString()
        )
    }

    // MARK: - Opening

    static func unwrapPhotoKey(_ wrappedPhotoKey: String, huddleKey: SymmetricKey) throws -> SymmetricKey {
        try openKey(wrappedPhotoKey, using: huddleKey, authenticating: photoKeyContext)
    }

    /// Opens a photo, or either half of a video: the same box under the
    /// same key.
    static func openPhoto(_ ciphertext: Data, photoKey: SymmetricKey) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: photoKey)
    }

    static func openPhoto(_ ciphertext: Data, wrappedPhotoKey: String, huddleKey: SymmetricKey) throws -> Data {
        try openPhoto(ciphertext, photoKey: unwrapPhotoKey(wrappedPhotoKey, huddleKey: huddleKey))
    }

    /// `reports.photo_key`: the one key a report hands the operator. It opens
    /// that photo's Storage object (tools/decrypt_reported_photo), or a
    /// video's poster and clip, and nothing else — not the huddle key, not
    /// any other deposit.
    static func disclosedPhotoKey(_ wrappedPhotoKey: String, huddleKey: SymmetricKey) throws -> String {
        rawBytes(of: try unwrapPhotoKey(wrappedPhotoKey, huddleKey: huddleKey)).base64EncodedString()
    }

    // MARK: - Helpers

    private static func rawBytes(of key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    private static func combined(_ box: AES.GCM.SealedBox) throws -> Data {
        // Always non-nil with the default 12-byte nonce.
        guard let combined = box.combined else { throw CryptoError.malformed }
        return combined
    }

    private static func openKey(
        _ base64: String,
        using key: SymmetricKey,
        authenticating context: Data = Data()
    ) throws -> SymmetricKey {
        guard let data = Data(base64Encoded: base64) else { throw CryptoError.malformed }
        let raw = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: context)
        guard raw.count == 32 else { throw CryptoError.malformed }
        return SymmetricKey(data: raw)
    }
}

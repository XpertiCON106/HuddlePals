import CryptoKit
import Foundation
import SwiftData
import XCTest

@testable import HuddlePal

/// End-to-end photo encryption (`PhotoCrypto`), no network: huddle-key wrap /
/// unwrap, photo seal / open, wrong keys failing cleanly, and a report's key
/// disclosure opening exactly one photo. Plus the store carrying the wrapped
/// photo key from a deposit row onto the model. (Huddles are never named by
/// type here — the module shares the name.)
@MainActor
final class PhotoEncryptionTests: XCTestCase {
    private let huddleID = UUID()
    private let aliceID = UUID()
    private let alice = Curve25519.KeyAgreement.PrivateKey()
    private var jpeg: Data!

    override func setUp() async throws {
        try await super.setUp()
        jpeg = PlaceholderImageGenerator.jpegData(seed: 7)
    }

    private func wrapForAlice(_ huddleKey: SymmetricKey) throws -> PhotoCrypto.WrappedHuddleKey {
        try PhotoCrypto.wrapHuddleKey(huddleKey, for: alice.publicKey, huddleID: huddleID, recipientID: aliceID)
    }

    // MARK: Huddle keys

    func testHuddleKeyWrapUnwrapRoundTrip() throws {
        let huddleKey = PhotoCrypto.makeHuddleKey()
        let wrapped = try wrapForAlice(huddleKey)
        let unwrapped = try PhotoCrypto.unwrapHuddleKey(wrapped, with: alice, huddleID: huddleID, recipientID: aliceID)
        XCTAssertEqual(unwrapped, huddleKey)

        // Shareable through the server: the public key survives its base64 form.
        let published = try PhotoCrypto.publicKey(from: PhotoCrypto.encode(alice.publicKey))
        XCTAssertEqual(published.rawRepresentation, alice.publicKey.rawRepresentation)
    }

    func testWrappedHuddleKeyMatchesTheDatabaseFormats() throws {
        let wrapped = try wrapForAlice(PhotoCrypto.makeHuddleKey())
        // Mirrors the check constraints in schema.sql / the migration.
        XCTAssertNotNil(wrapped.wrappedKey.range(of: #"^[A-Za-z0-9+/]{80}$"#, options: .regularExpression))
        XCTAssertNotNil(wrapped.ephemeralPublicKey.range(of: #"^[A-Za-z0-9+/]{43}=$"#, options: .regularExpression))
        XCTAssertNotNil(PhotoCrypto.encode(alice.publicKey).range(of: #"^[A-Za-z0-9+/]{43}=$"#, options: .regularExpression))
    }

    func testHuddleKeyOpensOnlyForItsRecipientHuddleAndMember() throws {
        let wrapped = try wrapForAlice(PhotoCrypto.makeHuddleKey())
        let mallory = Curve25519.KeyAgreement.PrivateKey()
        XCTAssertThrowsError(
            try PhotoCrypto.unwrapHuddleKey(wrapped, with: mallory, huddleID: huddleID, recipientID: aliceID),
            "another identity key can't open Alice's copy"
        )
        XCTAssertThrowsError(
            try PhotoCrypto.unwrapHuddleKey(wrapped, with: alice, huddleID: UUID(), recipientID: aliceID),
            "a copy can't be replayed onto another huddle"
        )
        XCTAssertThrowsError(
            try PhotoCrypto.unwrapHuddleKey(wrapped, with: alice, huddleID: huddleID, recipientID: UUID()),
            "a copy can't be replayed onto another member"
        )
    }

    // MARK: Photos

    func testPhotoSealOpenRoundTrip() throws {
        let huddleKey = PhotoCrypto.makeHuddleKey()
        let sealed = try PhotoCrypto.sealPhoto(jpeg, huddleKey: huddleKey)

        XCTAssertNotEqual(sealed.ciphertext, jpeg)
        XCTAssertFalse(sealed.ciphertext.starts(with: [0xFF, 0xD8, 0xFF]), "Storage must not hold a JPEG")
        XCTAssertEqual(sealed.ciphertext.count, jpeg.count + 28, "GCM adds only its nonce and tag")
        XCTAssertNotNil(sealed.wrappedPhotoKey.range(of: #"^[A-Za-z0-9+/]{80}$"#, options: .regularExpression))

        let opened = try PhotoCrypto.openPhoto(sealed.ciphertext, wrappedPhotoKey: sealed.wrappedPhotoKey, huddleKey: huddleKey)
        XCTAssertEqual(opened, jpeg)
    }

    func testEveryPhotoGetsItsOwnKey() throws {
        let huddleKey = PhotoCrypto.makeHuddleKey()
        let first = try PhotoCrypto.sealPhoto(jpeg, huddleKey: huddleKey)
        let second = try PhotoCrypto.sealPhoto(jpeg, huddleKey: huddleKey)
        XCTAssertNotEqual(first.wrappedPhotoKey, second.wrappedPhotoKey)
        XCTAssertNotEqual(first.ciphertext, second.ciphertext)
    }

    func testWrongKeysFailCleanly() throws {
        let huddleKey = PhotoCrypto.makeHuddleKey()
        let sealed = try PhotoCrypto.sealPhoto(jpeg, huddleKey: huddleKey)

        XCTAssertThrowsError(
            try PhotoCrypto.openPhoto(sealed.ciphertext, wrappedPhotoKey: sealed.wrappedPhotoKey, huddleKey: PhotoCrypto.makeHuddleKey()),
            "another huddle's key"
        )
        var tampered = sealed.ciphertext
        tampered[tampered.count / 2] ^= 0x01
        XCTAssertThrowsError(
            try PhotoCrypto.openPhoto(tampered, wrappedPhotoKey: sealed.wrappedPhotoKey, huddleKey: huddleKey),
            "a modified file"
        )
        XCTAssertThrowsError(
            try PhotoCrypto.openPhoto(Data([1, 2, 3]), wrappedPhotoKey: sealed.wrappedPhotoKey, huddleKey: huddleKey),
            "a truncated file"
        )
        XCTAssertThrowsError(
            try PhotoCrypto.openPhoto(sealed.ciphertext, wrappedPhotoKey: "not base64!", huddleKey: huddleKey),
            "a malformed wrapped key"
        )
    }

    // MARK: Reports

    func testReportDisclosureOpensOnlyThatPhoto() throws {
        let huddleKey = PhotoCrypto.makeHuddleKey()
        let reported = try PhotoCrypto.sealPhoto(jpeg, huddleKey: huddleKey)
        let other = try PhotoCrypto.sealPhoto(PlaceholderImageGenerator.jpegData(seed: 8), huddleKey: huddleKey)

        let disclosed = try PhotoCrypto.disclosedPhotoKey(reported.wrappedPhotoKey, huddleKey: huddleKey)
        XCTAssertNotNil(disclosed.range(of: #"^[A-Za-z0-9+/]{43}=$"#, options: .regularExpression), "reports.photo_key format")
        let photoKey = SymmetricKey(data: try XCTUnwrap(Data(base64Encoded: disclosed)))

        // What tools/decrypt_reported_photo does: open the Storage bytes directly.
        XCTAssertEqual(try PhotoCrypto.openPhoto(reported.ciphertext, photoKey: photoKey), jpeg)
        XCTAssertThrowsError(try PhotoCrypto.openPhoto(other.ciphertext, photoKey: photoKey), "another photo stays sealed")
        XCTAssertThrowsError(
            try PhotoCrypto.unwrapPhotoKey(other.wrappedPhotoKey, huddleKey: photoKey),
            "the disclosed key is no huddle key"
        )
        XCTAssertNotEqual(photoKey, huddleKey)
    }

    // MARK: Identity key storage

    /// If the stored key couldn't be found again, every launch would mint a
    /// new identity and strand every huddle key wrapped for the last one.
    func testIdentityKeySurvivesInTheKeychainUntilDeleted() throws {
        let store = IdentityKeychain()
        let userID = UUID()
        defer { store.delete(for: userID) }

        XCTAssertNil(store.load(for: userID))
        let key = Curve25519.KeyAgreement.PrivateKey()
        XCTAssertTrue(store.save(key, for: userID))
        XCTAssertEqual(store.load(for: userID)?.rawRepresentation, key.rawRepresentation)
        XCTAssertNil(store.load(for: UUID()), "one item per account")

        store.delete(for: userID)
        XCTAssertNil(store.load(for: userID))
    }

    // MARK: Sync

    func testStoreCarriesTheWrappedPhotoKeyOntoTheDeposit() throws {
        let container = try ModelContainer(
            for: Schema(HuddleSchema.models),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let store = SupabaseStore(context: container.mainContext)
        let huddle = try store.apply(HuddleDTO(
            id: huddleID, name: "Sealed", emoji: "🔒", inviteCode: "SEAL42",
            notificationHour: 19, streakCount: 0
        ))
        let sealed = try PhotoCrypto.sealPhoto(jpeg, huddleKey: PhotoCrypto.makeHuddleKey())
        let current = UUID(), future = UUID()
        let json = """
        [
          {"id": "\(current)", "huddle_id": "\(huddleID)", "author_id": null,
           "storage_path": "\(huddleID)/a.jpg", "caption": null, "day_key": "2026-10-19",
           "wrapped_photo_key": "\(sealed.wrappedPhotoKey)", "enc_version": 1},
          {"id": "\(future)", "huddle_id": "\(huddleID)", "author_id": null,
           "storage_path": "\(huddleID)/b.jpg", "caption": null, "day_key": "2026-10-19",
           "wrapped_photo_key": "\(sealed.wrappedPhotoKey)", "enc_version": 2}
        ]
        """
        let dtos = try SupabaseClient.makeDecoder().decode([DepositDTO].self, from: Data(json.utf8))
        try store.applyDeposits(dtos, reactions: [], comments: [], to: huddle)
        try store.save()

        let byID = Dictionary(uniqueKeysWithValues: huddle.deposits.map { ($0.id, $0) })
        XCTAssertEqual(byID[current]?.wrappedPhotoKey, sealed.wrappedPhotoKey)
        XCTAssertNil(byID[future]?.wrappedPhotoKey, "a format this build can't open renders locked")
    }
}

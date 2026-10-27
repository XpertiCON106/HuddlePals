import CryptoKit
import Foundation
import SwiftData
import XCTest

@testable import HuddlePal

/// Instant join: invite codes that carry the huddle key, sealed for the
/// code's secret (`InviteCode`, `InviteCrypto`, the keyring's invite paths).
/// The live flows run against `FakeHuddleServer`, an in-process stand-in for
/// the Supabase functions that never sees a secret either, so "no other
/// member online" is literal: nothing on Ada's side runs while Ben joins.
@MainActor
final class InviteKeyTests: XCTestCase {
    private let huddleID = UUID()
    private let adaID = UUID()
    private let adaIdentity = Curve25519.KeyAgreement.PrivateKey()
    private var huddleKey: SymmetricKey!
    private var container: ModelContainer!
    private var store: SupabaseStore!
    private var session: AppSession!
    private var ben: User!
    private var server: FakeHuddleServer!
    private var cachedPaths: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        huddleKey = PhotoCrypto.makeHuddleKey()
        container = try LiveStub.inMemoryContainer()
        store = SupabaseStore(context: container.mainContext)
        session = AppSession()
        ben = User(displayName: "Ben", avatarColorHex: "0091FF")
        container.mainContext.insert(ben)
        server = FakeHuddleServer(huddleID: huddleID, keeperID: adaID)
        // Ada created the huddle: her public key and her copy of its key.
        server.setUserKey(PhotoCrypto.encode(adaIdentity.publicKey), for: adaID)
        let adaCopy = try PhotoCrypto.wrapHuddleKey(huddleKey, for: adaIdentity.publicKey, huddleID: huddleID, recipientID: adaID)
        server.setKeyCopy(.init(
            wrappedKey: adaCopy.wrappedKey, ephemeralPublicKey: adaCopy.ephemeralPublicKey,
            recipientPublicKey: PhotoCrypto.encode(adaIdentity.publicKey)
        ), for: adaID)
    }

    override func tearDown() async throws {
        // The live media cache is the mock's Documents folder: tidy only our files.
        let cache = MockMediaService()
        for path in cachedPaths { cache.deleteImage(at: path) }
        StubURLProtocol.reset()
        KeychainStore.delete(key: LiveStub.sessionKey)
        try await super.tearDown()
    }

    // MARK: - The code

    func testACodeIsALookupPlusAtLeast128BitsOfSecretInTheUnambiguousAlphabet() {
        XCTAssertGreaterThanOrEqual(Double(InviteCode.secretLength) * log2(Double(InviteCode.alphabet.count)), 128)
        XCTAssertFalse(InviteCode.alphabet.contains { "01ILO".contains($0) }, "no ambiguous glyphs")
        var lookups = Set<String>()
        for _ in 0..<50 {
            let code = InviteCode.generate()
            XCTAssertEqual(code.compact.count, 32)
            XCTAssertTrue(code.compact.allSatisfy { InviteCode.alphabet.contains($0) })
            XCTAssertEqual(code.lookup, String(code.compact.prefix(6)))
            XCTAssertNotNil(code.displayed.range(of: #"^([A-Z0-9]{4}-){7}[A-Z0-9]{4}$"#, options: .regularExpression))
            lookups.insert(code.lookup)
        }
        XCTAssertGreaterThan(lookups.count, 45, "random, not a counter")
    }

    func testACodeParsesHoweverItsPastedOrTyped() {
        let code = InviteCode.generate()
        for text in [code.compact, code.displayed, code.displayed.lowercased(), " \(code.displayedOnTwoLines) ", code.displayed.replacingOccurrences(of: "-", with: " ")] {
            XCTAssertEqual(InviteCode(text), code, text)
        }
        XCTAssertNil(InviteCode(String(code.compact.dropLast())))
        XCTAssertNil(InviteCode(code.compact + "A"))
        XCTAssertNil(InviteCode(String(code.compact.dropLast()) + "0"), "0 isn't in the alphabet")
    }

    func testOldSixCharacterCodesAreRecognisedAsOld() {
        XCTAssertTrue(InviteCode.isLegacy("crew42"))
        XCTAssertTrue(InviteCode.isLegacy(" PASTA7 "))
        XCTAssertFalse(InviteCode.isLegacy("CREW4"))
        XCTAssertFalse(InviteCode.isLegacy(InviteCode.generate().compact))
        XCTAssertNil(InviteCode("CREW42"))
    }

    // MARK: - The crypto

    func testASealedInviteMatchesTheDatabaseFormatsAndCarriesNoSecret() throws {
        let code = InviteCode.generate()
        let sealed = try InviteCrypto.seal(huddleKey, code: code, huddleID: huddleID)
        // Mirrors huddle_invite_keys' check constraints and invite_proof_hash.
        XCTAssertNotNil(sealed.proof.range(of: #"^[A-Za-z0-9+/]{43}=$"#, options: .regularExpression))
        XCTAssertNotNil(sealed.salt.range(of: #"^[A-Za-z0-9+/]{43}=$"#, options: .regularExpression))
        XCTAssertNotNil(sealed.sealedKey.range(of: #"^[A-Za-z0-9+/]{80}$"#, options: .regularExpression))
        XCTAssertNotNil(sealed.sealedSecret.range(of: #"^[A-Za-z0-9+/]{72}$"#, options: .regularExpression))
        let uploaded = [sealed.proof, sealed.salt, sealed.sealedKey, sealed.sealedSecret].joined()
        XCTAssertFalse(uploaded.contains(code.secret))
        XCTAssertNotEqual(try InviteCrypto.seal(huddleKey, code: code, huddleID: huddleID).salt, sealed.salt, "a fresh salt each time")
    }

    func testTheHuddleKeyOpensOnlyWithTheRightCodeForTheRightHuddle() throws {
        let code = InviteCode.generate()
        let sealed = try InviteCrypto.seal(huddleKey, code: code, huddleID: huddleID)
        XCTAssertEqual(
            try InviteCrypto.openHuddleKey(sealedKey: sealed.sealedKey, salt: sealed.salt, code: code, huddleID: huddleID),
            huddleKey
        )
        let wrongSecret = try XCTUnwrap(InviteCode(lookup: code.lookup, secret: InviteCode.generate().secret))
        XCTAssertThrowsError(try InviteCrypto.openHuddleKey(sealedKey: sealed.sealedKey, salt: sealed.salt, code: wrongSecret, huddleID: huddleID), "wrong secret")
        XCTAssertThrowsError(try InviteCrypto.openHuddleKey(sealedKey: sealed.sealedKey, salt: sealed.salt, code: code, huddleID: UUID()), "another huddle")
        XCTAssertThrowsError(try InviteCrypto.openHuddleKey(sealedKey: sealed.sealedKey, salt: InviteCrypto.seal(huddleKey, code: code, huddleID: huddleID).salt, code: code, huddleID: huddleID), "another salt")
        XCTAssertThrowsError(try InviteCrypto.openHuddleKey(sealedKey: "not base64!", salt: sealed.salt, code: code, huddleID: huddleID))
    }

    func testMembersRecoverTheWholeCodeFromTheSealedSecret() throws {
        let code = InviteCode.generate()
        let sealed = try InviteCrypto.seal(huddleKey, code: code, huddleID: huddleID)
        XCTAssertEqual(try InviteCrypto.openCode(sealedSecret: sealed.sealedSecret, lookup: code.lookup, huddleKey: huddleKey, huddleID: huddleID), code)
        XCTAssertThrowsError(try InviteCrypto.openCode(sealedSecret: sealed.sealedSecret, lookup: code.lookup, huddleKey: PhotoCrypto.makeHuddleKey(), huddleID: huddleID), "only with the huddle key")
        XCTAssertThrowsError(try InviteCrypto.openCode(sealedSecret: sealed.sealedSecret, lookup: InviteCode.generate().lookup, huddleKey: huddleKey, huddleID: huddleID), "bound to its lookup")
        // The huddle key seals photo keys too: a sealed secret never passes as one.
        XCTAssertThrowsError(try PhotoCrypto.unwrapPhotoKey(sealed.sealedSecret, huddleKey: huddleKey))
    }

    func testTheProofNeedsTheWholeCodeAndIsNoKey() throws {
        let code = InviteCode.generate()
        let proof = InviteCrypto.proof(for: code)
        XCTAssertEqual(InviteCrypto.proof(for: code), proof, "both sides derive the same")
        XCTAssertNotEqual(InviteCrypto.proof(for: try XCTUnwrap(InviteCode(lookup: code.lookup, secret: InviteCode.generate().secret))), proof)
        XCTAssertNotEqual(InviteCrypto.proof(for: try XCTUnwrap(InviteCode(lookup: InviteCode.generate().lookup, secret: code.secret))), proof)
        let sealed = try InviteCrypto.seal(huddleKey, code: code, huddleID: huddleID)
        let proofAsKey = SymmetricKey(data: try XCTUnwrap(Data(base64Encoded: proof)))
        XCTAssertThrowsError(try AES.GCM.open(AES.GCM.SealedBox(combined: try XCTUnwrap(Data(base64Encoded: sealed.sealedKey))), using: proofAsKey), "the proof the server sees opens nothing")
    }

    // MARK: - Joining (live, against the fake server)

    func testJoiningWithNoOtherMemberOnlineOpensAnExistingPhoto() async throws {
        let code = try installInvite()
        let photo = try storeAdasPhoto()
        let (client, keyring, identities) = try await signIn(ben.id, token: "ben")
        StubURLProtocol.respond(with: server.handle)

        let huddle = try await huddleService(client, keyring).joinHuddle(inviteCode: code.displayed, user: ben)

        XCTAssertEqual(huddle.id, huddleID)
        let opened = await LiveMediaService(client: client, keyring: keyring).loadDepositPhoto(
            at: photo.cachePath, huddleID: huddleID, wrappedPhotoKey: photo.sealed.wrappedPhotoKey
        )
        XCTAssertEqual(opened, photo.jpeg, "Ada's photo opens the moment Ben joins")
        XCTAssertEqual(session.photoKeysVersion, 1, "locked placeholders retry")

        // Ben's own copy is on the server, wrapped for his key: the invite isn't needed again.
        let copy = try XCTUnwrap(server.keyCopy(for: ben.id))
        let benIdentity = try XCTUnwrap(identities.load(for: ben.id))
        XCTAssertEqual(copy.recipientPublicKey, PhotoCrypto.encode(benIdentity.publicKey))
        XCTAssertEqual(try PhotoCrypto.unwrapHuddleKey(
            .init(wrappedKey: copy.wrappedKey, ephemeralPublicKey: copy.ephemeralPublicKey),
            with: benIdentity, huddleID: huddleID, recipientID: ben.id
        ), huddleKey)

        let paths = StubURLProtocol.requests.map { $0.url!.path }
        for waiting in ["huddle_key_recipients", "share_huddle_key", "/huddle_keys"] {
            XCTAssertFalse(paths.contains { $0.hasSuffix(waiting) }, "no other member involved: \(waiting)")
        }
        assertServerNeverSaw(code)
    }

    func testPostingAPhotoRightAfterJoining() async throws {
        let code = try installInvite()
        let (client, keyring, _) = try await signIn(ben.id, token: "ben")
        StubURLProtocol.respond(with: server.handle)
        let huddle = try await huddleService(client, keyring).joinHuddle(inviteCode: code.compact, user: ben)

        let jpeg = PlaceholderImageGenerator.jpegData(seed: 11)
        let path = "\(huddleID.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
        let stored = try await LiveMediaService(client: client, keyring: keyring).saveDepositPhoto(jpeg, preferredName: path, huddleID: huddleID)
        cachedPaths.append(stored.path)
        let deposit = try await LiveDepositService(client: client, store: store, keyring: keyring).createDeposit(
            in: huddle, author: ben, localImagePath: stored.path, wrappedPhotoKey: stored.wrappedPhotoKey,
            caption: "first day", dayKey: "2026-10-22"
        )

        XCTAssertEqual(deposit.wrappedPhotoKey, stored.wrappedPhotoKey)
        let uploaded = try XCTUnwrap(server.object(at: path))
        XCTAssertNotEqual(uploaded, jpeg, "Storage gets ciphertext")
        let wrappedPhotoKey = try XCTUnwrap(stored.wrappedPhotoKey)
        XCTAssertEqual(try PhotoCrypto.openPhoto(uploaded, wrappedPhotoKey: wrappedPhotoKey, huddleKey: huddleKey), jpeg, "and Ada can open it")
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.url!.path.hasSuffix("/huddle_keys") }, "sealed with the invite's key, no sync needed")
        assertServerNeverSaw(code)
    }

    func testPostingAVideoRightAfterJoining() async throws {
        let code = try installInvite()
        let (client, keyring, _) = try await signIn(ben.id, token: "ben")
        StubURLProtocol.respond(with: server.handle)
        let huddle = try await huddleService(client, keyring).joinHuddle(inviteCode: code.compact, user: ben)

        let clip = try await ClipPreparer.placeholder(seed: 12)
        let base = "\(huddleID.uuidString.lowercased())/\(UUID().uuidString.lowercased())"
        let media = LiveMediaService(client: client, keyring: keyring)
        let stored = try await media.saveDepositVideo(poster: clip.poster, clip: clip.clip, baseName: base, huddleID: huddleID)
        cachedPaths += [stored.posterPath, stored.videoPath]
        let deposit = try await LiveDepositService(client: client, store: store, keyring: keyring).createDeposit(
            in: huddle, author: ben, localImagePath: stored.posterPath, wrappedPhotoKey: stored.wrappedPhotoKey,
            caption: nil, dayKey: "2026-10-22",
            video: DepositVideo(localVideoPath: stored.videoPath, durationMs: clip.durationMs)
        )

        XCTAssertTrue(deposit.isVideo)
        XCTAssertEqual(deposit.localVideoPath, stored.videoPath)
        let row = try XCTUnwrap(server.lastDeposit)
        XCTAssertEqual(row["media_type"] as? String, "video")
        XCTAssertEqual(row["storage_path"] as? String, "\(base).jpg", "the poster where a photo goes")
        XCTAssertEqual(row["video_path"] as? String, "\(base).mp4", "the clip next to it")
        XCTAssertEqual(row["duration_ms"] as? Int, clip.durationMs)

        let uploads = StubURLProtocol.requests
            .filter { $0.httpMethod == "POST" && $0.url!.path.hasPrefix("/storage/v1/object/deposits/") }
            .map { $0.url!.pathExtension }
        XCTAssertEqual(uploads, ["jpg", "mp4"], "the poster first")
        let poster = try XCTUnwrap(server.object(at: "\(base).jpg"))
        let uploadedClip = try XCTUnwrap(server.object(at: "\(base).mp4"))
        XCTAssertNotEqual(uploadedClip, clip.clip, "Storage gets ciphertext")
        let wrapped = try XCTUnwrap(stored.wrappedPhotoKey)
        XCTAssertEqual(try PhotoCrypto.openPhoto(poster, wrappedPhotoKey: wrapped, huddleKey: huddleKey), clip.poster)
        XCTAssertEqual(try PhotoCrypto.openPhoto(uploadedClip, wrappedPhotoKey: wrapped, huddleKey: huddleKey), clip.clip, "Ada can play it")

        let played = await media.loadDepositPhoto(at: stored.videoPath, huddleID: huddleID, wrappedPhotoKey: wrapped)
        XCTAssertEqual(played, clip.clip, "opened from the cache, in memory")
        assertServerNeverSaw(code)
    }

    func testAVideoAfterPlusEndedIsRefusedAndNothingIsPosted() async throws {
        let code = try installInvite()
        let (client, keyring, _) = try await signIn(ben.id, token: "ben")
        StubURLProtocol.respond(with: server.handle)
        let huddle = try await huddleService(client, keyring).joinHuddle(inviteCode: code.compact, user: ben)
        let media = LiveMediaService(client: client, keyring: keyring)
        let deposits = LiveDepositService(client: client, store: store, keyring: keyring)
        let clip = try await ClipPreparer.placeholder(seed: 13)

        // Plus ended before the clip went up: Storage refuses it.
        server.setPlus(false)
        let refusedBase = "\(huddleID.uuidString.lowercased())/\(UUID().uuidString.lowercased())"
        do {
            _ = try await media.saveDepositVideo(poster: clip.poster, clip: clip.clip, baseName: refusedBase, huddleID: huddleID)
            XCTFail("Storage takes a clip only with Plus")
        } catch DepositError.videoNeedsPlus {}
        cachedPaths.append(LiveMediaService.cachePath(forStoragePath: "\(refusedBase).jpg"))
        XCTAssertNil(server.object(at: "\(refusedBase).mp4"))

        // Plus ended between the upload and the row: the database refuses it.
        server.setPlus(true)
        let base = "\(huddleID.uuidString.lowercased())/\(UUID().uuidString.lowercased())"
        let stored = try await media.saveDepositVideo(poster: clip.poster, clip: clip.clip, baseName: base, huddleID: huddleID)
        cachedPaths += [stored.posterPath, stored.videoPath]
        server.setPlus(false)
        do {
            try await deposits.createDeposit(
                in: huddle, author: ben, localImagePath: stored.posterPath, wrappedPhotoKey: stored.wrappedPhotoKey,
                caption: nil, dayKey: "2026-10-22",
                video: DepositVideo(localVideoPath: stored.videoPath, durationMs: clip.durationMs)
            )
            XCTFail("the insert policy takes a video only with Plus")
        } catch DepositError.videoNeedsPlus {}
        XCTAssertNil(server.lastDeposit, "nothing posted")
        XCTAssertTrue(huddle.deposits.isEmpty)

        // A photo for the day still goes up, and carries no video fields.
        let jpeg = PlaceholderImageGenerator.jpegData(seed: 14)
        let photo = try await media.saveDepositPhoto(jpeg, preferredName: "\(huddleID.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg", huddleID: huddleID)
        cachedPaths.append(photo.path)
        try await deposits.createDeposit(
            in: huddle, author: ben, localImagePath: photo.path, wrappedPhotoKey: photo.wrappedPhotoKey,
            caption: nil, dayKey: "2026-10-22"
        )
        let row = try XCTUnwrap(server.lastDeposit)
        XCTAssertNil(row["media_type"], "a photo row is what it always was")
        XCTAssertNil(row["video_path"])
        XCTAssertNil(row["duration_ms"])
    }

    func testAWrongSecretFailsCleanly() async throws {
        let code = try installInvite()
        let guess = try XCTUnwrap(InviteCode(lookup: code.lookup, secret: InviteCode.generate().secret))
        let (client, keyring, _) = try await signIn(ben.id, token: "ben")
        StubURLProtocol.respond(with: server.handle)

        do {
            _ = try await huddleService(client, keyring).joinHuddle(inviteCode: guess.displayed, user: ben)
            XCTFail("a wrong secret must not join")
        } catch HuddleServiceError.inviteCodeNotFound {}

        XCTAssertFalse(server.isMember(ben.id))
        XCTAssertEqual(server.misses, 1, "counted towards the guess limit")
        XCTAssertNil(keyring.cachedHuddleKey(for: huddleID))
        XCTAssertNil(try store.huddle(id: huddleID), "nothing of the huddle on this device")
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.url!.path.hasSuffix("save_own_huddle_key") })
    }

    func testADamagedInviteLeavesTheHuddleAgain() async throws {
        // The server takes the proof, but its sealed copy was made for another code.
        let code = InviteCode.generate()
        let other = try InviteCrypto.seal(huddleKey, code: InviteCode.generate(), huddleID: huddleID)
        server.setInvite(.init(
            lookup: code.lookup, proof: InviteCrypto.proof(for: code), salt: other.salt,
            sealedKey: other.sealedKey, sealedSecret: other.sealedSecret
        ))
        let (client, keyring, _) = try await signIn(ben.id, token: "ben")
        StubURLProtocol.respond(with: server.handle)

        do {
            _ = try await huddleService(client, keyring).joinHuddle(inviteCode: code.displayed, user: ben)
            XCTFail("a key that doesn't open must not leave Ben in the huddle")
        } catch HuddleServiceError.inviteUnusable {}

        XCTAssertFalse(server.isMember(ben.id), "left again")
        XCTAssertNil(keyring.cachedHuddleKey(for: huddleID))
    }

    func testARevokedInviteFails() async throws {
        let old = try installInvite()
        let (_, adaKeyring) = try await signInAda()
        let (benClient, benKeyring, _) = try await signIn(ben.id, token: "ben")
        StubURLProtocol.respond(with: server.handle)

        let fresh = try await adaKeyring.resetInviteCode(for: huddleID)

        XCTAssertNotEqual(fresh, old)
        do {
            _ = try await huddleService(benClient, benKeyring).joinHuddle(inviteCode: old.displayed, user: ben)
            XCTFail("the revoked code must fail")
        } catch HuddleServiceError.inviteCodeNotFound {}
        XCTAssertFalse(server.isMember(ben.id))

        _ = try await huddleService(benClient, benKeyring).joinHuddle(inviteCode: fresh.displayed, user: ben)
        XCTAssertEqual(benKeyring.cachedHuddleKey(for: huddleID), huddleKey)
        assertServerNeverSaw(old)
        assertServerNeverSaw(fresh)
    }

    func testKeyRotationReissuesTheInviteSealedWithTheNewKey() async throws {
        let old = try installInvite()
        // The huddle's key was replaced (nobody left held the old one): the
        // server dropped the invite sealing the old key, and Ada holds the new one.
        let newKey = PhotoCrypto.makeHuddleKey()
        let adaCopy = try PhotoCrypto.wrapHuddleKey(newKey, for: adaIdentity.publicKey, huddleID: huddleID, recipientID: adaID)
        server.setKeyCopy(.init(
            wrappedKey: adaCopy.wrappedKey, ephemeralPublicKey: adaCopy.ephemeralPublicKey,
            recipientPublicKey: PhotoCrypto.encode(adaIdentity.publicKey)
        ), for: adaID)
        server.dropInvite()
        let (_, adaKeyring) = try await signInAda()
        let (benClient, benKeyring, _) = try await signIn(ben.id, token: "ben")
        StubURLProtocol.respond(with: server.handle)

        let issued = try await adaKeyring.inviteCode(for: huddleID)
        let reissued = try XCTUnwrap(issued)

        XCTAssertNotEqual(reissued, old)
        do {
            _ = try await huddleService(benClient, benKeyring).joinHuddle(inviteCode: old.displayed, user: ben)
            XCTFail("the old code no longer hands out a key")
        } catch HuddleServiceError.inviteCodeNotFound {}
        _ = try await huddleService(benClient, benKeyring).joinHuddle(inviteCode: reissued.displayed, user: ben)
        XCTAssertEqual(benKeyring.cachedHuddleKey(for: huddleID), newKey, "the new copy carries the new key")
    }

    func testMembersSeeTheHuddlesCodeWithoutReissuingIt() async throws {
        let code = try installInvite()
        let (_, adaKeyring) = try await signInAda()
        StubURLProtocol.respond(with: server.handle)

        let shown = try await adaKeyring.inviteCode(for: huddleID)
        XCTAssertEqual(shown, code)
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.url!.path.hasSuffix("create_huddle_invite") })
    }

    func testOpeningAHuddleStillOnAnOldCodeQuietlyIssuesANewFormatInvite() async throws {
        server.setLegacy()
        let (adaClient, adaKeyring) = try await signInAda()
        StubURLProtocol.respond(with: server.handle)
        let huddle = try store.apply(server.huddleDTO)

        _ = try await LiveDepositService(client: adaClient, store: store, keyring: adaKeyring).deposits(in: huddle)
        for _ in 0..<100 where server.activeInviteLookup == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let lookup = try XCTUnwrap(server.activeInviteLookup, "a new-format invite was issued")
        XCTAssertFalse(server.isLegacy, "the old code is retired")
        let shown = try await adaKeyring.inviteCode(for: huddleID)
        let code = try XCTUnwrap(shown)
        XCTAssertEqual(code.lookup, lookup)
        let sealed = try XCTUnwrap(server.invite)
        XCTAssertEqual(try InviteCrypto.openHuddleKey(sealedKey: sealed.sealedKey, salt: sealed.salt, code: code, huddleID: huddleID), huddleKey)
        assertServerNeverSaw(code)
    }

    func testAnOwnCopyThatDidntSaveIsRetriedByTheNextSync() async throws {
        let code = try installInvite()
        let (client, keyring, _) = try await signIn(ben.id, token: "ben")
        server.failNextSaveOwnCopy()
        StubURLProtocol.respond(with: server.handle)

        _ = try await huddleService(client, keyring).joinHuddle(inviteCode: code.displayed, user: ben)
        XCTAssertNil(server.keyCopy(for: ben.id))
        XCTAssertEqual(keyring.cachedHuddleKey(for: huddleID), huddleKey, "joined and reading all the same")

        await keyring.sync(huddleIDs: [huddleID])
        XCTAssertNotNil(server.keyCopy(for: ben.id), "saved on the next pass")
    }

    // MARK: - Helpers

    private func huddleService(_ client: SupabaseClient, _ keyring: LivePhotoKeyring) -> LiveHuddleService {
        LiveHuddleService(client: client, store: store, engine: HuddleEngine(), dateProvider: AppDateProvider(), keyring: keyring)
    }

    /// Ada (offline from here on) issued an invite.
    @discardableResult
    private func installInvite() throws -> InviteCode {
        let code = InviteCode.generate()
        let sealed = try InviteCrypto.seal(huddleKey, code: code, huddleID: huddleID)
        server.setInvite(.init(
            lookup: code.lookup, proof: sealed.proof, salt: sealed.salt,
            sealedKey: sealed.sealedKey, sealedSecret: sealed.sealedSecret
        ))
        return code
    }

    private struct StoredPhoto {
        let jpeg: Data
        let sealed: PhotoCrypto.SealedPhoto
        let cachePath: String
    }

    /// A photo Ada posted before Ben joined: in Storage, as ciphertext.
    private func storeAdasPhoto() throws -> StoredPhoto {
        let jpeg = PlaceholderImageGenerator.jpegData(seed: 3)
        let sealed = try PhotoCrypto.sealPhoto(jpeg, huddleKey: huddleKey)
        let path = "\(huddleID.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
        server.putObject(sealed.ciphertext, at: path)
        let cachePath = LiveMediaService.cachePath(forStoragePath: path)
        cachedPaths.append(cachePath)
        return StoredPhoto(jpeg: jpeg, sealed: sealed, cachePath: cachePath)
    }

    private func signIn(_ userID: UUID, token: String) async throws -> (SupabaseClient, LivePhotoKeyring, InMemoryIdentityStore) {
        let client = try await LiveStub.signedInClient(userID: userID, accessToken: token)
        server.addUser(userID, token: token)
        let identities = InMemoryIdentityStore()
        return (client, LivePhotoKeyring(client: client, session: session, identityStore: identities), identities)
    }

    private func signInAda() async throws -> (SupabaseClient, LivePhotoKeyring) {
        let (client, _, identities) = try await signIn(adaID, token: "ada")
        _ = identities.save(adaIdentity, for: adaID)
        return (client, LivePhotoKeyring(client: client, session: AppSession(), identityStore: identities))
    }

    /// What reached the server: never the secret, the whole code, or the huddle key.
    private func assertServerNeverSaw(_ code: InviteCode, file: StaticString = #filePath, line: UInt = #line) {
        let rawKey = huddleKey.withUnsafeBytes { Data($0) }.base64EncodedString()
        for request in StubURLProtocol.requests {
            let sent = request.url!.absoluteString + String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            for secret in [code.secret, code.compact, code.displayed, rawKey] {
                XCTAssertFalse(sent.contains(secret), "\(request.url!.path) carried a secret", file: file, line: line)
            }
        }
    }
}

/// The Supabase functions the invite flows use, in process: redeem checks
/// the proof's hash, sealed copies come back as stored, and nothing here can
/// open them. Requests are answered on URLSession's threads, hence the lock.
final class FakeHuddleServer: @unchecked Sendable {
    struct Invite {
        var lookup: String
        var proof: String
        var salt: String
        var sealedKey: String
        var sealedSecret: String
    }

    struct KeyCopy {
        var wrappedKey: String
        var ephemeralPublicKey: String
        var recipientPublicKey: String
    }

    private let lock = NSLock()
    let huddleID: UUID
    private let keeperID: UUID
    private var activeInvite: Invite?
    private var legacy = false
    private var lookup = "OLDC0D"
    private var members: [UUID]
    private var tokens: [String: UUID] = [:]
    private var userKeys: [UUID: String] = [:]
    private var keyCopies: [UUID: KeyCopy] = [:]
    private var objects: [String: Data] = [:]
    private var missCount = 0
    private var failSaveOwnCopy = false
    /// Whether the caller has Plus: without it Storage refuses a .mp4 and
    /// the deposits insert policy a video row (migration 013).
    private var plus = true
    private var acceptedDeposit: [String: Any]?

    init(huddleID: UUID, keeperID: UUID) {
        self.huddleID = huddleID
        self.keeperID = keeperID
        members = [keeperID]
    }

    // MARK: State, for tests

    func addUser(_ id: UUID, token: String) { lock.withLock { tokens[token] = id } }
    func setUserKey(_ key: String, for id: UUID) { lock.withLock { userKeys[id] = key } }
    func setKeyCopy(_ copy: KeyCopy, for id: UUID) { lock.withLock { keyCopies[id] = copy } }
    func setInvite(_ invite: Invite) { lock.withLock { activeInvite = invite; lookup = invite.lookup; legacy = false } }
    func dropInvite() { lock.withLock { activeInvite = nil } }
    func setLegacy() { lock.withLock { activeInvite = nil; legacy = true; lookup = "CREW42" } }
    func putObject(_ data: Data, at path: String) { lock.withLock { objects[path] = data } }
    func failNextSaveOwnCopy() { lock.withLock { failSaveOwnCopy = true } }
    func setPlus(_ on: Bool) { lock.withLock { plus = on } }
    /// The last deposit row the server took, as the app sent it.
    var lastDeposit: [String: Any]? { lock.withLock { acceptedDeposit } }
    /// Joined with an old code (or the server says so): no copy of the key.
    func addMember(_ id: UUID) { lock.withLock { if !members.contains(id) { members.append(id) } } }
    func removeKeyCopy(for id: UUID) { lock.withLock { keyCopies[id] = nil } }
    func keyCopy(for id: UUID) -> KeyCopy? { lock.withLock { keyCopies[id] } }
    func object(at path: String) -> Data? { lock.withLock { objects[path] } }
    func isMember(_ id: UUID) -> Bool { lock.withLock { members.contains(id) } }
    var misses: Int { lock.withLock { missCount } }
    var invite: Invite? { lock.withLock { activeInvite } }
    var activeInviteLookup: String? { lock.withLock { activeInvite?.lookup } }
    var isLegacy: Bool { lock.withLock { legacy } }

    var huddleDTO: HuddleDTO {
        lock.withLock {
            HuddleDTO(id: huddleID, name: "Family", emoji: "🏔", inviteCode: lookup, notificationHour: 19, streakCount: 0)
        }
    }

    // MARK: Requests

    func handle(_ request: URLRequest) -> StubURLProtocol.Reply {
        lock.withLock { route(request) }
    }

    private func route(_ request: URLRequest) -> StubURLProtocol.Reply {
        let url = request.url!
        let path = url.path
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
        let token = (request.value(forHTTPHeaderField: "Authorization") ?? "").replacingOccurrences(of: "Bearer ", with: "")
        guard let caller = tokens[token] else { return .init(status: 401, body: LiveStub.json(["message": "JWT"])) }
        let string = { (key: String) in body[key] as? String ?? "" }

        switch (request.httpMethod ?? "GET", path) {
        case ("POST", "/rest/v1/rpc/redeem_huddle_invite"):
            guard let invite = activeInvite,
                  invite.lookup.uppercased() == string("p_lookup").uppercased(),
                  Self.hash(string("p_proof")) == Self.hash(invite.proof) else {
                missCount += 1
                return json([])
            }
            if members.contains(caller) { return LiveStub.postgrestError("already_member") }
            members.append(caller)
            return json([[
                "joined_huddle_id": huddleID.uuidString.lowercased(),
                "invite_salt": invite.salt, "invite_sealed_key": invite.sealedKey,
            ]])
        case ("POST", "/rest/v1/rpc/save_own_huddle_key"):
            if failSaveOwnCopy {
                failSaveOwnCopy = false
                return .init(status: 503, body: LiveStub.json(["message": "unavailable"]))
            }
            guard members.contains(caller) else { return LiveStub.postgrestError("not_a_member") }
            keyCopies[caller] = KeyCopy(
                wrappedKey: string("p_wrapped_key"), ephemeralPublicKey: string("p_ephemeral_public_key"),
                recipientPublicKey: string("p_recipient_public_key")
            )
            return .init(body: Data("true".utf8))
        case ("POST", "/rest/v1/rpc/huddle_invite"):
            guard members.contains(caller) else { return json([]) }
            let sealedSecret: Any = activeInvite.map { $0.sealedSecret } ?? NSNull()
            return json([["lookup": lookup, "legacy": legacy, "sealed_secret": sealedSecret]])
        case ("POST", "/rest/v1/rpc/create_huddle_invite"):
            guard activeInvite == nil else { return .init(body: Data("false".utf8)) }
            activeInvite = invite(from: string)
            lookup = string("p_lookup")
            legacy = false
            return .init(body: Data("true".utf8))
        case ("POST", "/rest/v1/rpc/reset_huddle_invite"):
            guard caller == keeperID else { return LiveStub.postgrestError("not_keeper") }
            activeInvite = invite(from: string)
            lookup = string("p_lookup")
            legacy = false
            return .init(body: Data("null".utf8))
        case ("POST", "/rest/v1/rpc/huddle_key_recipients"):
            // Fellow members with a published key and no working copy.
            guard members.contains(caller) else { return json([]) }
            return json(members.compactMap { member -> [String: String]? in
                guard member != caller, let key = userKeys[member],
                      keyCopies[member]?.recipientPublicKey != key else { return nil }
                return ["user_id": member.uuidString, "public_key": key]
            })
        case ("POST", "/rest/v1/rpc/share_huddle_key"):
            guard members.contains(caller) else { return LiveStub.postgrestError("not_a_member") }
            guard let recipient = UUID(uuidString: string("p_user")), members.contains(recipient) else {
                return LiveStub.postgrestError("recipient_not_member")
            }
            guard userKeys[recipient] == string("p_recipient_public_key") else {
                return LiveStub.postgrestError("stale_public_key")
            }
            keyCopies[recipient] = KeyCopy(
                wrappedKey: string("p_wrapped_key"), ephemeralPublicKey: string("p_ephemeral_public_key"),
                recipientPublicKey: string("p_recipient_public_key")
            )
            return .init(status: 204, body: Data())
        case ("POST", "/rest/v1/rpc/init_huddle_key"):
            return .init(body: Data("false".utf8))
        case ("GET", "/rest/v1/user_keys"):
            let id = UUID(uuidString: query["user_id"]?.replacingOccurrences(of: "eq.", with: "") ?? "")
            return json(id.flatMap { id in userKeys[id].map { [["user_id": id.uuidString, "public_key": $0]] } } ?? [])
        case ("POST", "/rest/v1/user_keys"):
            userKeys[caller] = string("public_key")
            return json([["user_id": caller.uuidString, "public_key": string("public_key")]])
        case ("GET", "/rest/v1/huddle_keys"):
            guard let copy = keyCopies[caller] else { return json([]) }
            return json([[
                "huddle_id": huddleID.uuidString, "user_id": caller.uuidString, "wrapped_key": copy.wrappedKey,
                "ephemeral_public_key": copy.ephemeralPublicKey, "recipient_public_key": copy.recipientPublicKey,
            ]])
        case ("GET", "/rest/v1/huddles"):
            guard members.contains(caller) else { return json([]) }
            return json([[
                "id": huddleID.uuidString, "name": "Family", "emoji": "🏔", "invite_code": lookup,
                "notification_hour": 19, "streak_count": 0, "created_at": "2026-10-01T09:00:00Z",
            ]])
        case ("GET", "/rest/v1/memberships"):
            return json(members.map { [
                "id": UUID().uuidString, "user_id": $0.uuidString, "huddle_id": huddleID.uuidString,
                "role": $0 == keeperID ? "keeper" : "member", "skip_tokens_remaining": 2,
            ] })
        case ("DELETE", "/rest/v1/memberships"):
            members.removeAll { $0 == caller }
            return .init(status: 204, body: Data())
        case ("GET", "/rest/v1/profiles"):
            return json(members.map { ["id": $0.uuidString, "display_name": $0 == keeperID ? "Ada" : "Ben", "avatar_color_hex": "E5484D"] })
        case ("POST", "/rest/v1/deposits"):
            if body["media_type"] as? String == "video", !plus {
                return .init(status: 403, body: LiveStub.json([
                    "code": "42501", "message": "new row violates row-level security policy for table \"deposits\"",
                ]))
            }
            acceptedDeposit = body
            var row = body
            row["id"] = UUID().uuidString
            row["created_at"] = "2026-10-22T09:00:00Z"
            return json([row])
        case ("GET", "/rest/v1/deposits"), ("GET", "/rest/v1/reactions"), ("GET", "/rest/v1/comments"):
            return json([])
        case ("GET", let p) where p.hasPrefix("/storage/v1/object/authenticated/deposits/"):
            let key = String(p.dropFirst("/storage/v1/object/authenticated/deposits/".count))
            guard let data = objects[key] else { return .init(status: 404, body: LiveStub.json(["message": "not found"])) }
            return .init(body: data)
        case ("POST", let p) where p.hasPrefix("/storage/v1/object/deposits/"):
            if p.lowercased().hasSuffix(".mp4"), !plus {
                // What Supabase Storage answers when its insert policy says no.
                return .init(status: 400, body: LiveStub.json([
                    "statusCode": "403", "error": "Unauthorized", "message": "new row violates row-level security policy",
                ]))
            }
            objects[String(p.dropFirst("/storage/v1/object/deposits/".count))] = request.httpBody ?? Data()
            return json(["Key": p])
        default:
            return .init(status: 404, body: LiveStub.json(["message": "no route for \(path)"]))
        }
    }

    private func invite(from string: (String) -> String) -> Invite {
        Invite(
            lookup: string("p_lookup"), proof: string("p_proof"), salt: string("p_salt"),
            sealedKey: string("p_sealed_key"), sealedSecret: string("p_sealed_secret")
        )
    }

    /// The server keeps only this (invite_proof_hash).
    private static func hash(_ proof: String) -> Data? {
        Data(base64Encoded: proof).map { Data(SHA256.hash(data: $0)) }
    }

    private func json(_ object: Any) -> StubURLProtocol.Reply {
        .init(body: LiveStub.json(object))
    }
}

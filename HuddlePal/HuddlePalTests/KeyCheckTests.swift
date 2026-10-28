import CryptoKit
import Foundation
import XCTest

@testable import HuddlePal

/// Key codes (`KeyCode`, the keyring's share pass): a huddle key goes to a
/// key the server lists only once a member has compared codes with that
/// person. `FakeHuddleServer` plays the server, including one that swaps a
/// member's key or adds a member of its own.
@MainActor
final class KeyCheckTests: XCTestCase {
    private let huddleID = UUID()
    private let adaID = UUID()
    private let benID = UUID()
    private let adaIdentity = Curve25519.KeyAgreement.PrivateKey()
    private let benIdentity = Curve25519.KeyAgreement.PrivateKey()
    private var huddleKey: SymmetricKey!
    private var server: FakeHuddleServer!
    private var adaChecks: InMemoryVerifiedKeys!

    override func setUp() async throws {
        try await super.setUp()
        huddleKey = PhotoCrypto.makeHuddleKey()
        server = FakeHuddleServer(huddleID: huddleID, keeperID: adaID)
        server.setUserKey(PhotoCrypto.encode(adaIdentity.publicKey), for: adaID)
        let adaCopy = try PhotoCrypto.wrapHuddleKey(huddleKey, for: adaIdentity.publicKey, huddleID: huddleID, recipientID: adaID)
        server.setKeyCopy(.init(
            wrappedKey: adaCopy.wrappedKey, ephemeralPublicKey: adaCopy.ephemeralPublicKey,
            recipientPublicKey: PhotoCrypto.encode(adaIdentity.publicKey)
        ), for: adaID)
        // Ben joined with an old code: a member with a published key, no copy.
        server.addMember(benID)
        server.setUserKey(PhotoCrypto.encode(benIdentity.publicKey), for: benID)
        adaChecks = InMemoryVerifiedKeys()
    }

    override func tearDown() async throws {
        StubURLProtocol.reset()
        KeychainStore.delete(key: LiveStub.sessionKey)
        try await super.tearDown()
    }

    // MARK: The code

    func testACodeIsSixGroupsOfFiveDigitsTiedToTheKeyAndTheAccount() {
        let code = KeyCode.code(for: benIdentity.publicKey, userID: benID)
        XCTAssertNotNil(code.wholeMatch(of: /\d{5}( \d{5}){5}/), code)
        XCTAssertEqual(code, KeyCode.code(for: benIdentity.publicKey, userID: benID), "the same every time")
        XCTAssertNotEqual(code, KeyCode.code(for: adaIdentity.publicKey, userID: benID), "another key, another code")
        XCTAssertNotEqual(code, KeyCode.code(for: benIdentity.publicKey, userID: adaID), "another account, another code")
    }

    func testCheckedKeysSurviveInTheKeychainUntilTheAccountGoes() {
        let owner = UUID()
        let store = VerifiedKeychain()
        let key = PhotoCrypto.encode(benIdentity.publicKey)
        XCTAssertFalse(store.contains(key, member: benID, owner: owner))
        store.add(key, member: benID, owner: owner)
        XCTAssertTrue(store.contains(key, member: benID, owner: owner))
        XCTAssertFalse(store.contains(key, member: adaID, owner: owner), "checked for Ben only")
        store.removeAll(owner: owner)
        XCTAssertFalse(store.contains(key, member: benID, owner: owner))
    }

    // MARK: Sharing waits for a check

    func testAKeyTheServerListsWaitsForACodeCheck() async throws {
        let ada = try await signInAda()
        StubURLProtocol.respond(with: server.handle)

        await ada.sync(huddleIDs: [huddleID])

        XCTAssertNil(server.keyCopy(for: benID), "nothing shared on the server's word")
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.url!.path.hasSuffix("share_huddle_key") })
        XCTAssertEqual(ada.keyChecks(for: huddleID), [KeyCheck(
            userID: benID,
            publicKey: PhotoCrypto.encode(benIdentity.publicKey),
            code: KeyCode.code(for: benIdentity.publicKey, userID: benID)
        )])
    }

    func testTheCodeAdaChecksIsTheOneOnBensPhone() async throws {
        let ada = try await signInAda()
        let ben = try await signInBen()
        StubURLProtocol.respond(with: server.handle)

        await ada.sync(huddleIDs: [huddleID])
        let shownToAda = try XCTUnwrap(ada.keyChecks(for: huddleID).first).code
        let onBensPhone = await ben.ownKeyCode()

        XCTAssertEqual(shownToAda, onBensPhone)
    }

    func testConfirmingSharesTheKeyAndBenOpensIt() async throws {
        let ada = try await signInAda()
        let ben = try await signInBen()
        StubURLProtocol.respond(with: server.handle)
        await ada.sync(huddleIDs: [huddleID])

        try await ada.confirmKeyCheck(try XCTUnwrap(ada.keyChecks(for: huddleID).first), huddleID: huddleID)
        await ben.sync(huddleIDs: [huddleID])

        XCTAssertEqual(ben.cachedHuddleKey(for: huddleID), huddleKey)
        XCTAssertEqual(ada.keyChecks(for: huddleID), [])
        XCTAssertTrue(adaChecks.contains(PhotoCrypto.encode(benIdentity.publicKey), member: benID, owner: adaID))
    }

    func testACheckedKeyGetsTheHuddleKeyAgainWithoutAsking() async throws {
        let ada = try await signInAda()
        StubURLProtocol.respond(with: server.handle)
        await ada.sync(huddleIDs: [huddleID])
        try await ada.confirmKeyCheck(try XCTUnwrap(ada.keyChecks(for: huddleID).first), huddleID: huddleID)
        server.removeKeyCopy(for: benID)

        await ada.sync(huddleIDs: [huddleID])

        XCTAssertNotNil(server.keyCopy(for: benID))
        XCTAssertEqual(ada.keyChecks(for: huddleID), [])
    }

    // MARK: A server that lies

    func testAKeyTheServerSwapsInForBenIsNotShared() async throws {
        let ada = try await signInAda()
        StubURLProtocol.respond(with: server.handle)
        await ada.sync(huddleIDs: [huddleID])
        let realCheck = try XCTUnwrap(ada.keyChecks(for: huddleID).first)
        try await ada.confirmKeyCheck(realCheck, huddleID: huddleID)

        let impostor = Curve25519.KeyAgreement.PrivateKey()
        server.setUserKey(PhotoCrypto.encode(impostor.publicKey), for: benID)
        await ada.sync(huddleIDs: [huddleID])

        XCTAssertEqual(server.keyCopy(for: benID)?.recipientPublicKey, PhotoCrypto.encode(benIdentity.publicKey),
                       "Ben's copy is still the one wrapped for his real key")
        let newCheck = try XCTUnwrap(ada.keyChecks(for: huddleID).first)
        XCTAssertNotEqual(newCheck.code, realCheck.code, "Ben's own phone would show a different code")
    }

    func testAMemberTheServerAddsGetsNothingUnchecked() async throws {
        let mallory = UUID()
        let malloryKey = Curve25519.KeyAgreement.PrivateKey()
        server.addMember(mallory)
        server.setUserKey(PhotoCrypto.encode(malloryKey.publicKey), for: mallory)
        let ada = try await signInAda()
        StubURLProtocol.respond(with: server.handle)

        await ada.sync(huddleIDs: [huddleID])

        XCTAssertNil(server.keyCopy(for: mallory))
        XCTAssertEqual(Set(ada.keyChecks(for: huddleID).map(\.userID)), [benID, mallory])
    }

    func testACheckWhoseCodeIsntItsKeysIsRefused() async throws {
        let ada = try await signInAda()
        StubURLProtocol.respond(with: server.handle)
        await ada.sync(huddleIDs: [huddleID])
        let real = try XCTUnwrap(ada.keyChecks(for: huddleID).first)
        let forged = KeyCheck(userID: real.userID, publicKey: real.publicKey, code: "00000 00000 00000 00000 00000 00000")

        do {
            try await ada.confirmKeyCheck(forged, huddleID: huddleID)
            XCTFail("a code that isn't the key's must not share anything")
        } catch PhotoKeyError.keyChanged {}
        XCTAssertNil(server.keyCopy(for: benID))
    }

    func testAKeyThatChangedWhileBeingCheckedIsReportedAsChanged() async throws {
        let ada = try await signInAda()
        StubURLProtocol.respond(with: server.handle)
        await ada.sync(huddleIDs: [huddleID])
        let check = try XCTUnwrap(ada.keyChecks(for: huddleID).first)
        server.setUserKey(PhotoCrypto.encode(Curve25519.KeyAgreement.PrivateKey().publicKey), for: benID)

        do {
            try await ada.confirmKeyCheck(check, huddleID: huddleID)
            XCTFail("the server refuses a key that's no longer Ben's")
        } catch PhotoKeyError.keyChanged {}
        XCTAssertNil(server.keyCopy(for: benID))
    }

    // MARK: Helpers

    private func signInAda() async throws -> LivePhotoKeyring {
        let client = try await LiveStub.signedInClient(userID: adaID, accessToken: "ada")
        server.addUser(adaID, token: "ada")
        let identities = InMemoryIdentityStore()
        _ = identities.save(adaIdentity, for: adaID)
        return LivePhotoKeyring(client: client, session: AppSession(), identityStore: identities, verifiedKeys: adaChecks)
    }

    private func signInBen() async throws -> LivePhotoKeyring {
        let client = try await LiveStub.signedInClient(userID: benID, accessToken: "ben")
        server.addUser(benID, token: "ben")
        let identities = InMemoryIdentityStore()
        _ = identities.save(benIdentity, for: benID)
        return LivePhotoKeyring(client: client, session: AppSession(), identityStore: identities, verifiedKeys: InMemoryVerifiedKeys())
    }
}

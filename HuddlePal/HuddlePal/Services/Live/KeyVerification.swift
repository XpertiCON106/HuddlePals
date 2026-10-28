import CryptoKit
import Foundation
import Security

/// The code two people compare to confirm a member's identity key: 30 digits
/// in six groups of five, from SHA-256 over the account and its public key.
/// A member shows their own (Profile → Key code); someone checking them sees
/// the code of the key the server lists for them. Equal codes mean the server
/// is handing out that person's real key, not one it slipped in — the one
/// thing end-to-end encryption can't take on trust from the server.
enum KeyCode {
    private static let label = Data("HuddlePals key code v1".utf8)

    static func code(for publicKey: Curve25519.KeyAgreement.PublicKey, userID: UUID) -> String {
        var input = label
        input.append(Data(userID.uuidString.lowercased().utf8))
        input.append(publicKey.rawRepresentation)
        let digest = Array(SHA256.hash(data: input))
        // Five bytes per group, reduced to five digits: about 99 bits in all.
        return (0..<6).map { group in
            let value = digest[(group * 5)..<(group * 5 + 5)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            return String(format: "%05llu", value % 100_000)
        }
        .joined(separator: " ")
    }
}

/// The member keys an account has confirmed by comparing key codes. The
/// keyring shares a huddle key automatically only with a key in here; any
/// other waits for someone to check it. Base64 public keys, as `user_keys`
/// holds them.
protocol VerifiedKeyStoring {
    func contains(_ publicKey: String, member: UUID, owner: UUID) -> Bool
    func add(_ publicKey: String, member: UUID, owner: UUID)
    func removeAll(owner: UUID)
}

/// Confirmed keys in the Keychain, one item per account. Synchronizable like
/// the identity key, so a check made on one of the user's devices holds on
/// the others; only account deletion removes it.
struct VerifiedKeychain: VerifiedKeyStoring {
    private static let service = "com.huddlepals.ios.verified-keys"

    func contains(_ publicKey: String, member: UUID, owner: UUID) -> Bool {
        load(owner)[member.uuidString.lowercased()]?.contains(publicKey) == true
    }

    func add(_ publicKey: String, member: UUID, owner: UUID) {
        var keys = load(owner)
        keys[member.uuidString.lowercased(), default: []].insert(publicKey)
        save(keys, owner: owner)
    }

    func removeAll(owner: UUID) {
        SecItemDelete(Self.query(for: owner) as CFDictionary)
    }

    private func load(_ owner: UUID) -> [String: Set<String>] {
        var query = Self.query(for: owner)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return [:] }
        return (try? JSONDecoder().decode([String: Set<String>].self, from: data)) ?? [:]
    }

    private func save(_ keys: [String: Set<String>], owner: UUID) {
        guard let data = try? JSONEncoder().encode(keys) else { return }
        removeAll(owner: owner)
        var attributes = Self.query(for: owner)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecAttrSynchronizable as String] = kCFBooleanTrue
        if SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess { return }
        // No iCloud Keychain here: keep it on this device.
        attributes[kSecAttrSynchronizable as String] = kCFBooleanFalse
        SecItemAdd(attributes as CFDictionary, nil)
    }

    /// Matches the item whether or not it is synchronizable.
    private static func query(for owner: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: owner.uuidString.lowercased(),
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
    }
}

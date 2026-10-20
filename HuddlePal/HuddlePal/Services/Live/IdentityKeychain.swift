import CryptoKit
import Foundation
import Security

/// Where a user's E2EE identity private key lives. A protocol so the keyring
/// can be exercised without a real Keychain.
protocol IdentityKeyStoring {
    func load(for userID: UUID) -> Curve25519.KeyAgreement.PrivateKey?
    /// False when the key could not be persisted — the caller must then not
    /// publish it, or the device would lose access on the next launch.
    func save(_ key: Curve25519.KeyAgreement.PrivateKey, for userID: UUID) -> Bool
    func delete(for userID: UUID)
}

/// The identity key in the Keychain, one item per account. Unlike the
/// session (`KeychainStore`, ThisDeviceOnly) it is synchronizable: iCloud
/// Keychain carries it to the user's other devices and it survives a
/// reinstall — losing it means waiting for a huddle member to re-share every
/// huddle key. Only account deletion removes it, never sign-out.
struct IdentityKeychain: IdentityKeyStoring {
    private static let service = "com.huddlepals.app.identity"

    func load(for userID: UUID) -> Curve25519.KeyAgreement.PrivateKey? {
        var query = Self.query(for: userID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
    }

    func save(_ key: Curve25519.KeyAgreement.PrivateKey, for userID: UUID) -> Bool {
        delete(for: userID)
        var attributes = Self.query(for: userID)
        attributes[kSecValueData as String] = key.rawRepresentation
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecAttrSynchronizable as String] = kCFBooleanTrue
        if SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess { return true }
        // Some environments (e.g. no iCloud Keychain entitlement) refuse a
        // synchronizable item; a device-local copy still beats no key.
        attributes[kSecAttrSynchronizable as String] = kCFBooleanFalse
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    func delete(for userID: UUID) {
        SecItemDelete(Self.query(for: userID) as CFDictionary)
    }

    /// Matches the item whether or not it is synchronizable.
    private static func query(for userID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: userID.uuidString.lowercased(),
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
    }
}

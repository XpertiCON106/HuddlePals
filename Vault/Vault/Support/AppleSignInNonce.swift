import CryptoKit
import Foundation
import Security

/// Replay protection for native Sign in with Apple: a random nonce is
/// generated per attempt, its SHA-256 goes into the Apple request, and the
/// raw value goes to Supabase, which verifies the pair inside the returned
/// identity token.
enum AppleSignInNonce {
    static func random(length: Int = 32) -> String {
        let charset = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-._")
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        if status != errSecSuccess {
            // SecRandom failing is effectively unheard of; fall back to
            // SystemRandomNumberGenerator rather than crash mid-sign-in.
            bytes = (0..<length).map { _ in UInt8.random(in: .min ... .max) }
        }
        return String(bytes.map { charset[Int($0) % charset.count] })
    }

    static func sha256Hex(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

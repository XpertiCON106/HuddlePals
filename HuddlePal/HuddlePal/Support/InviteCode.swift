import Foundation

/// A huddle invite code: a 6-character lookup part, the only part the server
/// stores, and a 26-character secret that stays with the people sharing the
/// code. In live mode the secret opens a sealed copy of the huddle key
/// (`InviteCrypto`), so whoever holds the code can join and see every photo
/// straight away, while the server can't. Both parts use the unambiguous
/// alphabet (no 0/O, 1/I/L); the code reads as eight groups of four.
///
/// Codes from before invites carried a secret are exactly 6 characters; the
/// app no longer joins with them (`isLegacy`).
struct InviteCode: Hashable {
    static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    static let lookupLength = 6
    /// 26 characters of a 31-letter alphabet: 26 × log2(31) ≈ 128.8 bits.
    static let secretLength = 26
    static let length = lookupLength + secretLength

    /// Matched (case-insensitively) against `huddles.invite_code`.
    let lookup: String
    /// Never sent to the server, in any form it could reverse.
    let secret: String

    init?(lookup: String, secret: String) {
        guard lookup.count == Self.lookupLength, secret.count == Self.secretLength,
              (lookup + secret).allSatisfy({ Self.alphabet.contains($0) }) else { return nil }
        self.lookup = lookup
        self.secret = secret
    }

    /// Parses a typed, pasted or linked code: case, spaces and dashes don't
    /// matter. nil for anything that isn't a whole new-format code.
    init?(_ text: String) {
        let normalized = Self.normalized(text)
        guard normalized.count == Self.length else { return nil }
        self.init(
            lookup: String(normalized.prefix(Self.lookupLength)),
            secret: String(normalized.dropFirst(Self.lookupLength))
        )
    }

    /// A fresh code. `randomElement()` draws from `SystemRandomNumberGenerator`,
    /// which is cryptographically secure on Apple platforms, without modulo bias.
    static func generate() -> InviteCode {
        func random(_ count: Int) -> String {
            String((0..<count).map { _ in alphabet.randomElement()! })
        }
        return InviteCode(lookup: random(lookupLength), secret: random(secretLength))!
    }

    /// An old secret-less code (6 characters of the alphabet).
    static func isLegacy(_ text: String) -> Bool {
        let characters = Self.normalized(text)
        return characters.count == lookupLength && characters.allSatisfy { alphabet.contains($0) }
    }

    static func normalized(_ text: String) -> String {
        text.uppercased().filter { !$0.isWhitespace && $0 != "-" }
    }

    /// The 32 characters with nothing in between, as in an invite link.
    var compact: String { lookup + secret }

    /// "ABCD-EFGH-…": eight groups of four.
    var displayed: String { groups.joined(separator: "-") }

    /// Four groups per line, for large type.
    var displayedOnTwoLines: String {
        groups.prefix(4).joined(separator: "-") + "\n" + groups.suffix(4).joined(separator: "-")
    }

    private var groups: [String] {
        let characters = Array(compact)
        return stride(from: 0, to: characters.count, by: 4).map { String(characters[$0..<$0 + 4]) }
    }
}

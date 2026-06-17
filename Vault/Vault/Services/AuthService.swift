import Foundation
import SwiftData

// MARK: - Auth surface

/// Where a verification code gets sent.
enum OTPDestination: Equatable, Hashable {
    case email(String)
    case phone(String)

    var displayValue: String {
        switch self {
        case .email(let address): address
        case .phone(let number): number
        }
    }
}

/// Where the app should route after an auth step.
enum AuthSessionState {
    /// No session — show sign-in.
    case signedOut
    /// Authenticated, but no profile yet — finish onboarding.
    /// `suggestedName` carries Apple's full name when available.
    case needsProfile(suggestedName: String?)
    /// Fully signed in.
    case signedIn(User)
}

enum AuthError: LocalizedError {
    case invalidEmail
    case invalidPhone
    case invalidCode
    case notAuthenticated
    case provider(String)

    var errorDescription: String? {
        switch self {
        case .invalidEmail: "That doesn't look like an email address."
        case .invalidPhone: "Use the full international format, like +14155550123."
        case .invalidCode: "That code didn't match — or it expired. Check it or request a fresh one."
        case .notAuthenticated: "You're not signed in."
        case .provider(let message): message
        }
    }
}

enum AuthValidation {
    static func normalizedEmail(_ raw: String) -> String? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = cleaned.split(separator: "@")
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
              !parts[1].hasPrefix("."), !parts[1].hasSuffix(".")
        else { return nil }
        return cleaned
    }

    /// E.164: leading "+", 8–15 digits. Spaces, dashes, dots, and parens
    /// are stripped so "+1 (415) 555-0123" works.
    static func normalizedPhone(_ raw: String) -> String? {
        let cleaned = String(raw.filter { !$0.isWhitespace && !"-().".contains($0) })
        guard cleaned.hasPrefix("+") else { return nil }
        let digits = cleaned.dropFirst()
        guard (8...15).contains(digits.count), digits.allSatisfy(\.isNumber) else { return nil }
        return cleaned
    }
}

@MainActor
protocol AuthServiceProtocol: AnyObject {
    /// Session state at launch (restores a persisted session if present).
    func currentState() async throws -> AuthSessionState
    /// Sends a 6-digit verification code to the email or phone.
    func requestCode(to destination: OTPDestination) async throws
    /// Exchanges destination + code for a session.
    func verifyCode(_ code: String, for destination: OTPDestination) async throws -> AuthSessionState
    /// Native Sign in with Apple: exchanges the identity token for a session.
    func signInWithApple(idToken: String, nonce: String, suggestedName: String?) async throws -> AuthSessionState
    /// Creates the profile for a freshly authenticated account.
    func completeProfile(displayName: String, avatarColorHex: String) async throws -> User
    /// Updates the editable profile: name, identity color, bio (≤160),
    /// and up to 3 profile photo paths.
    func updateProfile(
        user: User,
        displayName: String,
        avatarColorHex: String,
        bio: String?,
        photoPaths: [String]
    ) async throws
    func signOut() async throws
    /// Permanently deletes the signed-in account. Deposited photos remain in
    /// shared vaults as "Former member" (the archive is permanent); the
    /// user's profile, avatar, and login are removed and they're signed out.
    func deleteAccount() async throws
}

extension AuthValidation {
    static let bioLimit = 160
    static let maxProfilePhotos = 3

    static func sanitizedBio(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(bioLimit))
    }
}

// MARK: - Mock

/// Offline stand-in that mirrors the real flow exactly: codes are "sent"
/// (always `123456`), identities map to local users, and sign-out sticks
/// until the next sign-in. First launch auto-signs-in the seeded "You" so
/// the LOCKED mechanic shows immediately.
@MainActor
final class MockAuthService: AuthServiceProtocol {
    /// Every mock "delivery" uses this code.
    static let mockCode = "123456"

    private static let currentUserIDKey = "vault.mock.currentUserID"
    private static let signedOutKey = "vault.mock.signedOutExplicitly"
    private static let identityPrefix = "vault.mock.identity."
    private static let pendingIdentityKey = "vault.mock.pendingIdentity"

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// Called by the seeder when the mock world is rebuilt.
    static func resetForReseed() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: signedOutKey)
        defaults.removeObject(forKey: pendingIdentityKey)
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(identityPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    func currentState() async throws -> AuthSessionState {
        let users = try context.fetch(FetchDescriptor<User>())
        if let stored = UserDefaults.standard.string(forKey: Self.currentUserIDKey),
           let id = UUID(uuidString: stored),
           let user = users.first(where: { $0.id == id }) {
            return .signedIn(user)
        }
        // A sign-up that got as far as verification but never finished the
        // profile resumes there, exactly like the live service.
        if UserDefaults.standard.string(forKey: Self.pendingIdentityKey) != nil {
            return .needsProfile(suggestedName: nil)
        }
        // Auto-sign-in the seeded user — unless they explicitly signed out,
        // in which case the sign-in flow shows.
        if !UserDefaults.standard.bool(forKey: Self.signedOutKey),
           let seeded = users.first(where: { $0.displayName == SeedDataService.currentUserName }) {
            persist(seeded)
            return .signedIn(seeded)
        }
        return .signedOut
    }

    func requestCode(to destination: OTPDestination) async throws {
        // TODO: BACKEND — the live service sends a real code via GoTrue.
        // DEBUG only: never log the destination (PII) or code in a shipped
        // build. The mock code is fixed and shown in the onboarding UI.
        #if DEBUG
        print("[MockAuth] Verification code for \(destination.displayValue): \(Self.mockCode)")
        #endif
    }

    func verifyCode(_ code: String, for destination: OTPDestination) async throws -> AuthSessionState {
        guard code == Self.mockCode else { throw AuthError.invalidCode }
        return try signIn(identityKey: identityKey(for: destination), suggestedName: nil)
    }

    func signInWithApple(idToken: String, nonce: String, suggestedName: String?) async throws -> AuthSessionState {
        try signIn(identityKey: Self.identityPrefix + "apple", suggestedName: suggestedName)
    }

    func completeProfile(displayName: String, avatarColorHex: String) async throws -> User {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = User(displayName: trimmed, avatarColorHex: avatarColorHex)
        context.insert(user)
        try context.save()
        if let pendingIdentity = UserDefaults.standard.string(forKey: Self.pendingIdentityKey) {
            UserDefaults.standard.set(user.id.uuidString, forKey: pendingIdentity)
            UserDefaults.standard.removeObject(forKey: Self.pendingIdentityKey)
        }
        persist(user)
        return user
    }

    func updateProfile(
        user: User,
        displayName: String,
        avatarColorHex: String,
        bio: String?,
        photoPaths: [String]
    ) async throws {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { user.displayName = trimmed }
        user.avatarColorHex = avatarColorHex
        user.bio = AuthValidation.sanitizedBio(bio)
        user.profilePhotoPaths = Array(photoPaths.prefix(AuthValidation.maxProfilePhotos))
        try context.save()
    }

    func signOut() async throws {
        UserDefaults.standard.removeObject(forKey: Self.currentUserIDKey)
        UserDefaults.standard.set(true, forKey: Self.signedOutKey)
    }

    func deleteAccount() async throws {
        // No backend in mock mode: drop the session and the identity→user
        // mappings for the current user so they can't sign back in as them.
        // (Live mode removes the server account, avatars, and Apple token.)
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: Self.currentUserIDKey) {
            for (key, value) in defaults.dictionaryRepresentation()
            where key.hasPrefix(Self.identityPrefix) && (value as? String) == stored {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.removeObject(forKey: Self.currentUserIDKey)
        defaults.set(true, forKey: Self.signedOutKey)
    }

    // MARK: Internals

    /// Returning identity → signed in; new identity → profile step, with
    /// the identity parked until `completeProfile` claims it.
    private func signIn(identityKey: String, suggestedName: String?) throws -> AuthSessionState {
        UserDefaults.standard.removeObject(forKey: Self.signedOutKey)
        let users = try context.fetch(FetchDescriptor<User>())
        if let stored = UserDefaults.standard.string(forKey: identityKey),
           let id = UUID(uuidString: stored),
           let user = users.first(where: { $0.id == id }) {
            persist(user)
            return .signedIn(user)
        }
        UserDefaults.standard.set(identityKey, forKey: Self.pendingIdentityKey)
        return .needsProfile(suggestedName: suggestedName)
    }

    private func identityKey(for destination: OTPDestination) -> String {
        switch destination {
        case .email(let address): Self.identityPrefix + "email." + address
        case .phone(let number): Self.identityPrefix + "phone." + number
        }
    }

    private func persist(_ user: User) {
        UserDefaults.standard.set(user.id.uuidString, forKey: Self.currentUserIDKey)
    }
}

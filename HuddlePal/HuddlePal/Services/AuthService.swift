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
    /// A restored account made before birthday screening. It cannot enter
    /// the app until its birthday has been saved and checked.
    case needsBirthday(User)
    /// Fully signed in.
    case signedIn(User)
}

enum AuthError: LocalizedError {
    case invalidEmail
    case invalidPhone
    case invalidCode
    case notAuthenticated
    /// A birthday under the Terms' minimum age (`Birthday.minimumAge`).
    case underMinimumAge
    case birthdayImmutable
    case provider(String)

    var errorDescription: String? {
        switch self {
        case .invalidEmail: "That doesn't look like an email address."
        case .invalidPhone: "Enter a 10-digit US or Canadian number, or start with + and your country code."
        case .invalidCode: "That code didn't match — or it expired. Check it or request a fresh one."
        case .notAuthenticated: "You're not signed in."
        case .underMinimumAge: "HuddlePals is for people \(Birthday.minimumAge) or older."
        case .birthdayImmutable: "Your birthday has already been saved and can't be changed."
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

    /// E.164 from whatever the user typed. A number starting with "+" is a
    /// full international number (8–15 digits). Anything else is US/Canada,
    /// so nobody has to type "+1": 10 digits, or 11 starting with that 1.
    /// Spaces, dashes, dots, and parens are ignored.
    static func normalizedPhone(_ raw: String) -> String? {
        let cleaned = String(raw.filter { !$0.isWhitespace && !"-().".contains($0) })
        let isInternational = cleaned.hasPrefix("+")
        let digits = isInternational ? String(cleaned.dropFirst()) : cleaned
        guard !digits.isEmpty, digits.allSatisfy(\.isASCIIDigit) else { return nil }
        if isInternational {
            return (8...15).contains(digits.count) ? "+" + digits : nil
        }
        switch digits.count {
        case 10: return "+1" + digits
        case 11 where digits.hasPrefix("1"): return "+" + digits
        default: return nil
        }
    }

    /// As-you-type display for the phone field. US/Canada numbers become
    /// "(415) 555-0123" (a leading country-code 1 is dropped — the field
    /// shows "+1" itself); never ends on a punctuation mark, so backspace
    /// always deletes a digit. "+…" international numbers keep the user's
    /// own spacing, minus anything that can't be part of a number.
    static func formattedPhoneInput(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("+") {
            return "+" + trimmed.dropFirst().filter { $0.isASCIIDigit || " -().".contains($0) }
        }
        var digits = Array(raw.filter(\.isASCIIDigit))
        // No US area code starts with 1, so a leading 1 is the country code.
        if digits.first == "1" { digits.removeFirst() }
        digits = Array(digits.prefix(10))
        switch digits.count {
        case 0...3:
            return String(digits)
        case 4...6:
            return "(\(String(digits[0..<3]))) \(String(digits[3...]))"
        default:
            return "(\(String(digits[0..<3]))) \(String(digits[3..<6]))-\(String(digits[6...]))"
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

@MainActor
protocol AuthServiceProtocol: AnyObject {
    /// Local credential presence only: enough to offer sign-out or account
    /// deletion while age-blocked, never evidence of app eligibility.
    func hasStoredSession() async -> Bool
    /// Session state at launch (restores a persisted session if present).
    func currentState() async throws -> AuthSessionState
    /// Sends a verification code to the email or phone.
    func requestCode(to destination: OTPDestination) async throws
    /// How many digits that code has — a per-project backend setting, so
    /// the code entry must never assume 6.
    func codeLength(for destination: OTPDestination) -> Int
    /// Exchanges destination + code for a session.
    func verifyCode(_ code: String, for destination: OTPDestination) async throws -> AuthSessionState
    /// Native Sign in with Apple: exchanges the identity token for a session.
    func signInWithApple(idToken: String, nonce: String, suggestedName: String?) async throws -> AuthSessionState
    /// Creates the profile and its eligible birthday together. A profile
    /// without a confirmed birthday cannot activate an app session.
    func completeProfile(displayName: String, avatarColorHex: String, birthday: Birthday) async throws -> User
    /// Updates the editable profile: name, identity color, bio (≤50),
    /// and up to 3 profile photo paths.
    func updateProfile(
        user: User,
        displayName: String,
        avatarColorHex: String,
        bio: String?,
        photoPaths: [String]
    ) async throws
    /// The signed-in account's birthday, which only its owner can read; nil
    /// when it was never given (accounts from before it was asked for).
    func birthday() async throws -> Birthday?
    /// Saves it once. The same birthday may be retried; changing an existing
    /// birthday or submitting one under the minimum age is refused.
    func saveBirthday(_ birthday: Birthday) async throws
    func signOut() async throws
    /// Permanently deletes the signed-in account. Deposited photos remain in
    /// shared huddles as "Former member" (the archive is permanent); the
    /// user's profile, avatar, and login are removed and they're signed out.
    /// `appleAuthorizationCode` is a fresh Sign in with Apple code (from
    /// `AppleReauthenticating`) the server uses to revoke the app's Apple
    /// tokens; nil when Apple couldn't confirm the person, and the account
    /// is deleted all the same.
    func deleteAccount(appleAuthorizationCode: String?) async throws
    /// After sign-out or deletion, once the session is cleared: forgets
    /// everything that account could see on this device (synced rows, cached
    /// photos), so the next person to sign in finds none of it.
    func removeLocalData() throws
}

extension AuthServiceProtocol {
    func hasStoredSession() async -> Bool { false }
}

extension AuthValidation {
    /// The app's limit for a display name; the database allows 40, which an
    /// older name keeps until it's edited.
    static let displayNameLimit = 10
    /// The app's limit; the database allows 160. An older, longer bio is
    /// shown cut to this in Profile, and saved so with the next change.
    static let bioLimit = 30
    static let maxProfilePhotos = 3

    static func sanitizedBio(_ raw: String?) -> String? {
        guard let raw else { return nil }
        // Trimmed again once it's cut: a cut can end on a space, and the
        // same bio must come out the same every time (or Profile would see
        // a change that isn't one).
        let cut = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(serverLength: bioLimit)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cut.isEmpty ? nil : cut
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

    private static let currentUserIDKey = "huddlepal.mock.currentUserID"
    private static let signedOutKey = "huddlepal.mock.signedOutExplicitly"
    private static let identityPrefix = "huddlepal.mock.identity."
    private static let pendingIdentityKey = "huddlepal.mock.pendingIdentity"

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func hasStoredSession() async -> Bool {
        let defaults = UserDefaults.standard
        return defaults.string(forKey: Self.currentUserIDKey) != nil
            || defaults.string(forKey: Self.pendingIdentityKey) != nil
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
            return try checkedState(for: user)
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
            return try checkedState(for: seeded)
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

    func codeLength(for destination: OTPDestination) -> Int {
        Self.mockCode.count
    }

    func verifyCode(_ code: String, for destination: OTPDestination) async throws -> AuthSessionState {
        guard code == Self.mockCode else { throw AuthError.invalidCode }
        return try signIn(identityKey: identityKey(for: destination), suggestedName: nil)
    }

    func signInWithApple(idToken: String, nonce: String, suggestedName: String?) async throws -> AuthSessionState {
        try signIn(identityKey: Self.identityPrefix + "apple", suggestedName: suggestedName)
    }

    func completeProfile(displayName: String, avatarColorHex: String, birthday: Birthday) async throws -> User {
        guard birthday.isValid,
              birthday.isOldEnough(on: .now, calendar: Birthday.eligibilityCalendar) else {
            throw AuthError.underMinimumAge
        }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = User(displayName: trimmed, avatarColorHex: avatarColorHex)
        context.insert(user)
        try context.save()
        Self.storeBirthday(birthday, for: user.id)
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

    // Birthdays: this device stands in for the server.
    private static let birthdayPrefix = "huddlepal.mock.birthday."

    /// The seeder gives the seeded accounts theirs.
    static func storeBirthday(_ birthday: Birthday, for userID: UUID) {
        UserDefaults.standard.set(birthday.isoDate, forKey: birthdayPrefix + userID.uuidString)
    }

    func birthday() async throws -> Birthday? {
        guard let id = UserDefaults.standard.string(forKey: Self.currentUserIDKey) else {
            throw AuthError.notAuthenticated
        }
        return UserDefaults.standard.string(forKey: Self.birthdayPrefix + id).flatMap(Birthday.init(isoDate:))
    }

    func saveBirthday(_ birthday: Birthday) async throws {
        guard let id = UserDefaults.standard.string(forKey: Self.currentUserIDKey) else {
            throw AuthError.notAuthenticated
        }
        guard birthday.isValid,
              birthday.isOldEnough(on: .now, calendar: Birthday.eligibilityCalendar) else {
            throw AuthError.underMinimumAge
        }
        let key = Self.birthdayPrefix + id
        if let saved = UserDefaults.standard.string(forKey: key), saved != birthday.isoDate {
            throw AuthError.birthdayImmutable
        }
        UserDefaults.standard.set(birthday.isoDate, forKey: key)
    }

    func signOut() async throws {
        UserDefaults.standard.removeObject(forKey: Self.currentUserIDKey)
        UserDefaults.standard.removeObject(forKey: Self.pendingIdentityKey)
        UserDefaults.standard.set(true, forKey: Self.signedOutKey)
    }

    func deleteAccount(appleAuthorizationCode: String?) async throws {
        // No backend in mock mode: drop the session and the identity→user
        // mappings for the current user so they can't sign back in as them.
        // (Live mode removes the server account and avatars, and revokes the
        // Apple tokens with the code; here it has nowhere to go.)
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: Self.currentUserIDKey) {
            for (key, value) in defaults.dictionaryRepresentation()
            where key.hasPrefix(Self.identityPrefix) && (value as? String) == stored {
                defaults.removeObject(forKey: key)
            }
            defaults.removeObject(forKey: Self.birthdayPrefix + stored)
        }
        defaults.removeObject(forKey: Self.currentUserIDKey)
        defaults.removeObject(forKey: Self.pendingIdentityKey)
        defaults.set(true, forKey: Self.signedOutKey)
    }

    /// Nothing to forget: the seeded world is the mock's whole data set and
    /// lives on this device by design.
    func removeLocalData() throws {}

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
            return try checkedState(for: user)
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

    private func checkedState(for user: User) throws -> AuthSessionState {
        guard let raw = UserDefaults.standard.string(forKey: Self.birthdayPrefix + user.id.uuidString),
              let birthday = Birthday(isoDate: raw) else {
            return .needsBirthday(user)
        }
        guard birthday.isValid,
              birthday.isOldEnough(on: .now, calendar: Birthday.eligibilityCalendar) else {
            throw AuthError.underMinimumAge
        }
        return .signedIn(user)
    }
}

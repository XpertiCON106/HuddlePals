import Foundation
import SwiftData

/// Real accounts via Supabase GoTrue: Sign in with Apple (native id_token
/// exchange), plus email and SMS with 6-digit verification codes, and email
/// with a password for accounts made in the dashboard. Sessions persist in
/// the Keychain, so sign out / sign back in lands on the same account from
/// any method tied to the same identity.
@MainActor
final class LiveAuthService: AuthServiceProtocol {
    private let client: SupabaseClient
    private let store: SupabaseStore
    private let keyring: LivePhotoKeyring
    private let media: LiveMediaService
    private let emailCodeLength: Int
    private let phoneCodeLength: Int

    init(
        client: SupabaseClient,
        store: SupabaseStore,
        keyring: LivePhotoKeyring,
        media: LiveMediaService,
        config: BackendConfig
    ) {
        self.client = client
        self.store = store
        self.keyring = keyring
        self.media = media
        emailCodeLength = config.emailCodeLength
        phoneCodeLength = config.phoneCodeLength
    }

    func codeLength(for destination: OTPDestination) -> Int {
        switch destination {
        case .email: emailCodeLength
        case .phone: phoneCodeLength
        }
    }

    func hasStoredSession() async -> Bool {
        await client.currentUserID != nil
    }

    func currentState() async throws -> AuthSessionState {
        // A cached profile is not evidence of age eligibility. If the
        // server cannot confirm it, retain the auth token for retry while
        // keeping the app session closed.
        guard let session = try await client.validSession() else { return .signedOut }
        return try await state(for: session, suggestedName: nil)
    }

    func requestCode(to destination: OTPDestination) async throws {
        do {
            switch destination {
            case .email(let address):
                try await client.sendOTP(email: address)
            case .phone(let number):
                try await client.sendOTP(phone: number)
            }
        } catch let SupabaseClient.ClientError.http(_, message) {
            // Typical causes: GoTrue rate limit ("you can only request this
            // once every 60 seconds") or the phone provider being disabled.
            throw AuthError.provider(message)
        }
    }

    func verifyCode(_ code: String, for destination: OTPDestination) async throws -> AuthSessionState {
        do {
            let session: SupabaseClient.Session
            switch destination {
            case .email(let address):
                session = try await client.verifyOTP(type: "email", email: address, token: code)
            case .phone(let number):
                session = try await client.verifyOTP(type: "sms", phone: number, token: code)
            }
            return try await state(for: session, suggestedName: nil)
        } catch let SupabaseClient.ClientError.http(status, message) {
            if status == 401 || status == 403
                || message.localizedCaseInsensitiveContains("expired or is invalid") {
                throw AuthError.invalidCode
            }
            throw AuthError.provider(message)
        }
    }

    func signInWithApple(idToken: String, nonce: String, suggestedName: String?) async throws -> AuthSessionState {
        do {
            let session = try await client.signInWithApple(idToken: idToken, nonce: nonce)
            return try await state(for: session, suggestedName: suggestedName)
        } catch let SupabaseClient.ClientError.http(_, message) {
            throw AuthError.provider(message)
        }
    }

    func signInWithPassword(email: String, password: String) async throws -> AuthSessionState {
        do {
            let session = try await client.signInWithPassword(email: email, password: password)
            return try await state(for: session, suggestedName: nil)
        } catch let SupabaseClient.ClientError.http(status, message) {
            // GoTrue says the same for a wrong password and an unknown email.
            if status == 400, message.localizedCaseInsensitiveContains("invalid login credentials") {
                throw AuthError.invalidCredentials
            }
            throw AuthError.provider(message)
        }
    }

    func signsInWithApple() async -> Bool {
        await client.signsInWithApple
    }

    func completeProfile(displayName: String, avatarColorHex: String, birthday: Birthday) async throws -> User {
        guard birthday.isValid,
              birthday.isOldEnough(on: .now, calendar: Birthday.eligibilityCalendar) else {
            throw AuthError.underMinimumAge
        }
        guard try await client.validSession() != nil else {
            throw AuthError.notAuthenticated
        }
        let saved: [ProfileDTO]
        do {
            saved = try await client.rpc("complete_profile", params: [
                "p_display_name": displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                "p_avatar_color_hex": avatarColorHex,
                "p_birth_date": birthday.isoDate,
            ])
        } catch {
            throw Self.birthdayError(error)
        }
        guard let dto = saved.first else {
            throw AuthError.provider("Your profile couldn't be created. Please try again.")
        }
        let user = try store.apply(dto)
        try store.save()
        await keyring.ensureIdentity(for: user.id)
        return user
    }

    func birthday() async throws -> Birthday? {
        guard let session = try await client.validSession() else {
            throw AuthError.notAuthenticated
        }
        let rows: [BirthdayDTO] = try await client.select("profile_birthdates", query: [
            URLQueryItem(name: "user_id", value: "eq.\(session.userId.uuidString)"),
        ])
        guard let row = rows.first else { return nil }
        guard let birthday = Birthday(isoDate: row.birthDate), birthday.isValid else {
            throw AuthError.provider("Your birthday couldn't be confirmed. Please try again.")
        }
        return birthday
    }

    func saveBirthday(_ birthday: Birthday) async throws {
        guard birthday.isValid,
              birthday.isOldEnough(on: .now, calendar: Birthday.eligibilityCalendar) else {
            throw AuthError.underMinimumAge
        }
        guard try await client.validSession() != nil else {
            throw AuthError.notAuthenticated
        }
        do {
            try await client.rpcVoid("save_birthday", params: ["p_birth_date": birthday.isoDate])
        } catch {
            throw Self.birthdayError(error)
        }
    }

    func updateProfile(
        user: User,
        displayName: String,
        avatarColorHex: String,
        bio: String?,
        photoPaths: [String]
    ) async throws {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let dto = ProfileDTO(
            id: user.id,
            displayName: trimmed.isEmpty ? user.displayName : trimmed,
            avatarColorHex: avatarColorHex,
            bio: AuthValidation.sanitizedBio(bio),
            photoPaths: Array(photoPaths.prefix(AuthValidation.maxProfilePhotos)),
            createdAt: nil
        )
        let saved: [ProfileDTO] = try await client.upsert("profiles", values: dto, onConflict: "id")
        if let updated = saved.first {
            try store.apply(updated)
            try store.save()
        }
    }

    func signOut() async throws {
        await client.signOut()
        // Keeps the identity key in the Keychain: signing back in must still
        // open every huddle.
        keyring.reset()
    }

    func deleteAccount(appleAuthorizationCode: String?) async throws {
        // The edge function trades the code for the app's Apple tokens and
        // revokes them, deletes avatar objects, releases the deposit photos
        // this user uploaded, and deletes the auth user (cascades the profile
        // and the user's user_keys / huddle_keys rows; deposits/comments keep
        // their rows as "Former member"). Then drop the local session and
        // identity key.
        let userID = await client.currentUserID
        let body = try SupabaseClient.makeEncoder().encode(
            DeleteAccountRequestDTO(authorizationCode: appleAuthorizationCode)
        )
        try await client.invokeFunction("delete-account", body: body)
        if let userID { keyring.forgetIdentity(for: userID) }
        await client.signOut()
    }

    /// The synced store holds co-members' profiles, captions and comments;
    /// the cache holds every huddle photo (ciphertext) and profile photo
    /// (plaintext) this account opened.
    func removeLocalData() throws {
        try store.removeAllLocalData()
        media.removeLocalCache()
    }

    /// A profile and confirmed eligible birthday are both required before
    /// publishing a key or opening the app session.
    private func state(
        for session: SupabaseClient.Session,
        suggestedName: String?
    ) async throws -> AuthSessionState {
        let profiles: [ProfileDTO] = try await client.select("profiles", query: [
            URLQueryItem(name: "id", value: "eq.\(session.userId.uuidString)"),
        ])
        guard let dto = profiles.first else {
            return .needsProfile(suggestedName: suggestedName)
        }
        let user = try store.apply(dto)
        try store.save()
        guard let birthday = try await birthday() else { return .needsBirthday(user) }
        guard birthday.isOldEnough(on: .now, calendar: Birthday.eligibilityCalendar) else {
            return .ageRestricted(user)
        }
        await keyring.ensureIdentity(for: session.userId)
        return .signedIn(user)
    }

    private static func birthdayError(_ error: Error) -> Error {
        guard case SupabaseClient.ClientError.http(_, let message) = error else { return error }
        if message.contains("birthday_immutable") { return AuthError.birthdayImmutable }
        if message.contains("under_minimum_age") { return AuthError.underMinimumAge }
        return error
    }
}

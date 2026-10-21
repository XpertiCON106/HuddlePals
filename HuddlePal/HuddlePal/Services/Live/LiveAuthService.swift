import Foundation
import SwiftData

/// Real accounts via Supabase GoTrue: Sign in with Apple (native id_token
/// exchange), plus email and SMS with 6-digit verification codes. Sessions
/// persist in the Keychain, so sign out / sign back in lands on the same
/// account from any method tied to the same identity.
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

    func currentState() async throws -> AuthSessionState {
        do {
            guard let session = try await client.validSession() else { return .signedOut }
            return try await state(for: session, suggestedName: nil)
        } catch where Self.isTransient(error) {
            // Offline (or the server is down) at launch: a stored session
            // stays signed in on the cached profile instead of landing on
            // sign-in. Screens show their last synced state and retry.
            if let userID = await client.currentUserID, let user = try store.user(id: userID) {
                return .signedIn(user)
            }
            throw error
        }
    }

    /// A failure that says nothing about the session itself.
    private static func isTransient(_ error: Error) -> Bool {
        if error is URLError { return true }
        if case SupabaseClient.ClientError.http(let status, _) = error {
            return status >= 500 || status == 429 || status == 408
        }
        return false
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

    func completeProfile(displayName: String, avatarColorHex: String) async throws -> User {
        guard let session = try await client.validSession() else {
            throw AuthError.notAuthenticated
        }
        let dto = ProfileDTO(
            id: session.userId,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            avatarColorHex: avatarColorHex,
            createdAt: nil
        )
        let saved: [ProfileDTO] = try await client.upsert("profiles", values: dto, onConflict: "id")
        let user = try store.apply(saved.first ?? dto)
        try store.save()
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

    /// Authenticated → signed in if the profile row exists, otherwise the
    /// onboarding profile step.
    private func state(
        for session: SupabaseClient.Session,
        suggestedName: String?
    ) async throws -> AuthSessionState {
        // First sign-in on this device creates the E2EE identity key and
        // publishes its public half. Not awaited: sign-in mustn't wait on it,
        // and the huddle-key sync retries it anyway.
        let keyring = keyring
        Task { await keyring.ensureIdentity(for: session.userId) }
        let profiles: [ProfileDTO] = try await client.select("profiles", query: [
            URLQueryItem(name: "id", value: "eq.\(session.userId.uuidString)"),
        ])
        guard let dto = profiles.first else {
            return .needsProfile(suggestedName: suggestedName)
        }
        let user = try store.apply(dto)
        try store.save()
        return .signedIn(user)
    }
}

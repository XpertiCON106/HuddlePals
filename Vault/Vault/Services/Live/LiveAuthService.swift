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

    init(client: SupabaseClient, store: SupabaseStore) {
        self.client = client
        self.store = store
    }

    func currentState() async throws -> AuthSessionState {
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

    func completeProfile(displayName: String, avatarColorHex: String) async throws -> User {
        guard let session = try await client.validSession() else {
            throw AuthError.notAuthenticated
        }
        let dto = ProfileDTO(
            id: session.userID,
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
    }

    func deleteAccount() async throws {
        // The edge function revokes the Apple token, deletes avatar objects,
        // and deletes the auth user (cascades the profile; deposits/comments
        // keep their rows as "Former member"). Then drop the local session.
        try await client.invokeFunction("delete-account")
        await client.signOut()
    }

    /// Authenticated → signed in if the profile row exists, otherwise the
    /// onboarding profile step.
    private func state(
        for session: SupabaseClient.Session,
        suggestedName: String?
    ) async throws -> AuthSessionState {
        let profiles: [ProfileDTO] = try await client.select("profiles", query: [
            URLQueryItem(name: "id", value: "eq.\(session.userID.uuidString)"),
        ])
        guard let dto = profiles.first else {
            return .needsProfile(suggestedName: suggestedName)
        }
        let user = try store.apply(dto)
        try store.save()
        return .signedIn(user)
    }
}

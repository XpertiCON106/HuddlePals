import Foundation
import SwiftData

@MainActor
protocol AuthServiceProtocol: AnyObject {
    /// Restores the persisted session, if any. The mock auto-signs-in the
    /// seeded "You" user on first launch.
    func restoreSession() async throws -> User?
    func signIn(displayName: String, avatarColorHex: String) async throws -> User
    func updateProfile(user: User, displayName: String, avatarColorHex: String) async throws
    func signOut() async throws
}

// MARK: - Mock

@MainActor
final class MockAuthService: AuthServiceProtocol {
    private static let currentUserIDKey = "vault.mock.currentUserID"

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func restoreSession() async throws -> User? {
        // TODO: BACKEND — replace with Supabase session restore
        // (supabase.auth.session) and a profile fetch keyed by auth uid.
        let users = try context.fetch(FetchDescriptor<User>())
        if let stored = UserDefaults.standard.string(forKey: Self.currentUserIDKey),
           let id = UUID(uuidString: stored),
           let user = users.first(where: { $0.id == id }) {
            return user
        }
        // Auto-sign-in the seeded current user so first launch lands
        // directly in the LOCKED vault.
        if let seeded = users.first(where: { $0.displayName == SeedDataService.currentUserName }) {
            persist(seeded)
            return seeded
        }
        return nil
    }

    func signIn(displayName: String, avatarColorHex: String) async throws -> User {
        // TODO: BACKEND — replace with Supabase sign-in (magic link / Apple)
        // followed by an upsert into a `profiles` table.
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let users = try context.fetch(FetchDescriptor<User>())
        let user: User
        if let existing = users.first(where: { $0.displayName == trimmed }) {
            existing.avatarColorHex = avatarColorHex
            user = existing
        } else {
            user = User(displayName: trimmed, avatarColorHex: avatarColorHex)
            context.insert(user)
        }
        try context.save()
        persist(user)
        return user
    }

    func updateProfile(user: User, displayName: String, avatarColorHex: String) async throws {
        // TODO: BACKEND — push profile changes to the `profiles` table.
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { user.displayName = trimmed }
        user.avatarColorHex = avatarColorHex
        try context.save()
    }

    func signOut() async throws {
        // TODO: BACKEND — supabase.auth.signOut(); local cache stays so the
        // user can sign back in offline.
        UserDefaults.standard.removeObject(forKey: Self.currentUserIDKey)
    }

    private func persist(_ user: User) {
        UserDefaults.standard.set(user.id.uuidString, forKey: Self.currentUserIDKey)
    }
}

import Foundation

/// Where this device's APNs token is registered, so the server can send it
/// the account's activity notifications. Live: the `device_tokens` table
/// (each user manages only their own rows). The decision of when to register
/// lives in `PushCoordinator`.
@MainActor
protocol PushTokenServiceProtocol: AnyObject {
    /// Registers (or refreshes) this device's token for the signed-in user.
    func register(token: String, environment: PushEnvironment) async throws
    /// Removes this device's token: it stops getting the account's
    /// notifications. Needs the session, so it runs before signing out.
    func unregister(token: String) async throws
}

// MARK: - Mock

/// Offline stand-in: remembers registrations in memory. There's no server
/// to send a notification from.
@MainActor
final class MockPushTokenService: PushTokenServiceProtocol {
    private(set) var registered: [String: PushEnvironment] = [:]

    func register(token: String, environment: PushEnvironment) async throws {
        registered[token] = environment
    }

    func unregister(token: String) async throws {
        registered[token] = nil
    }
}

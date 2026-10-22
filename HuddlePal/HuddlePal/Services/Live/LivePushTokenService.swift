import Foundation

/// `device_tokens` over PostgREST. The send-push edge function reads it (as
/// the service role) when a database trigger reports new activity.
@MainActor
final class LivePushTokenService: PushTokenServiceProtocol {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    /// An upsert, so a re-registration refreshes `updated_at` (set by the
    /// server): a token on file for two accounts notifies only the newer.
    func register(token: String, environment: PushEnvironment) async throws {
        guard let userID = await client.currentUserID else { throw SupabaseClient.ClientError.notAuthenticated }
        let _: [DeviceTokenDTO] = try await client.upsert(
            "device_tokens",
            values: DeviceTokenDTO(userId: userID, token: token, environment: environment.rawValue),
            onConflict: "user_id,token"
        )
    }

    func unregister(token: String) async throws {
        try await client.delete("device_tokens", query: [
            URLQueryItem(name: "token", value: "eq.\(token)"),
        ])
    }
}

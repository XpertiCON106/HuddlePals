import Foundation

/// `terms_acceptances` over PostgREST. The server sets `recorded_at`; the
/// app can't (it holds no grant on that column).
@MainActor
final class LiveTermsRecordService: TermsRecordServiceProtocol {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    /// ON CONFLICT DO NOTHING: an existing record for this version stays as
    /// it was (the table has no UPDATE policy).
    func record(version: String, acceptedAt: Date, appVersion: String) async throws {
        guard let userID = await client.currentUserID else { throw SupabaseClient.ClientError.notAuthenticated }
        let _: [TermsAcceptanceDTO] = try await client.upsert(
            "terms_acceptances",
            values: TermsAcceptanceDTO(userId: userID, version: version, acceptedAt: acceptedAt, appVersion: appVersion),
            onConflict: "user_id,version",
            ignoreDuplicates: true
        )
    }
}

import Foundation

@MainActor
final class LiveModerationService: ModerationServiceProtocol {
    private let client: SupabaseClient
    private let session: AppSession
    private let keyring: LivePhotoKeyring

    init(client: SupabaseClient, session: AppSession, keyring: LivePhotoKeyring) {
        self.client = client
        self.session = session
        self.keyring = keyring
    }

    func report(deposit: Deposit, reason: String?) async throws {
        guard let reporter = session.currentUser?.id else { throw SupabaseClient.ClientError.notAuthenticated }
        struct NewReport: Encodable {
            let reporterId: UUID
            let depositId: UUID
            let reportedUserId: UUID?
            let reason: String?
            let photoKey: String?
        }
        let _: [ReportDTO] = try await client.upsert("reports", values: NewReport(
            reporterId: reporter,
            depositId: deposit.id,
            reportedUserId: deposit.author?.id,
            reason: reason?.trimmingCharacters(in: .whitespacesAndNewlines),
            // Photos are end-to-end encrypted, so the operator can review
            // only what a report discloses: this one photo's own key (never
            // the huddle key). See tools/decrypt_reported_photo.
            photoKey: keyring.disclosedPhotoKey(
                huddleID: deposit.huddle?.id,
                wrappedPhotoKey: deposit.wrappedPhotoKey
            )
        ))
    }

    func block(_ user: User) async throws {
        guard let blocker = session.currentUser?.id else { throw SupabaseClient.ClientError.notAuthenticated }
        struct NewBlock: Encodable {
            let blockerId: UUID
            let blockedId: UUID
        }
        let _: [BlockDTO] = try await client.upsert(
            "blocks",
            values: NewBlock(blockerId: blocker, blockedId: user.id),
            onConflict: "blocker_id,blocked_id"
        )
    }

    func unblock(_ user: User) async throws {
        guard let blocker = session.currentUser?.id else { return }
        try await client.delete("blocks", query: [
            URLQueryItem(name: "blocker_id", value: "eq.\(blocker.uuidString)"),
            URLQueryItem(name: "blocked_id", value: "eq.\(user.id.uuidString)"),
        ])
    }

    func blockedUserIDs() async throws -> Set<UUID> {
        guard let blocker = session.currentUser?.id else { return [] }
        let rows: [BlockDTO] = try await client.select("blocks", query: [
            URLQueryItem(name: "blocker_id", value: "eq.\(blocker.uuidString)"),
        ])
        return Set(rows.map(\.blockedId))
    }
}

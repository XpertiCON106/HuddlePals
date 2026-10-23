import Foundation

/// Where an account's agreement to the Terms is recorded. Live: the
/// `terms_acceptances` table (each user writes only their own rows, and the
/// server stamps the time it stored one). When to record lives in
/// `TermsRecorder`.
@MainActor
protocol TermsRecordServiceProtocol: AnyObject {
    /// Records that the signed-in account agreed to `version` at
    /// `acceptedAt`. Recording the same version again changes nothing.
    func record(version: String, acceptedAt: Date, appVersion: String) async throws
}

// MARK: - Mock

/// In-memory stand-in: the offline world has no server to prove anything to.
@MainActor
final class MockTermsRecordService: TermsRecordServiceProtocol {
    struct Record: Equatable {
        let version: String
        let acceptedAt: Date
        let appVersion: String
    }

    private(set) var records: [Record] = []
    /// Makes the next `record` fail, as an offline request would.
    var failNext = false

    func record(version: String, acceptedAt: Date, appVersion: String) async throws {
        if failNext {
            failNext = false
            throw URLError(.notConnectedToInternet)
        }
        records.append(Record(version: version, acceptedAt: acceptedAt, appVersion: appVersion))
    }
}

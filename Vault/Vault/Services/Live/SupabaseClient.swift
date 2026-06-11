import Foundation

/// Zero-dependency Supabase client over URLSession, speaking the stable
/// REST surfaces directly: GoTrue (auth), PostgREST (rows + RPC), and
/// Storage (objects). Covers exactly what Vault needs — not a general SDK.
final class SupabaseClient {
    struct Session: Codable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
        let userID: UUID

        var isExpired: Bool { Date() > expiresAt.addingTimeInterval(-60) }
    }

    enum ClientError: LocalizedError {
        case notAuthenticated
        case http(status: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .notAuthenticated:
                return "Not signed in."
            case .http(let status, let message):
                return message.isEmpty ? "Server error (\(status))." : message
            }
        }
    }

    private let config: BackendConfig
    private let urlSession: URLSession
    private var session: Session?
    private static let sessionKey = "supabase.session"

    let decoder: JSONDecoder
    let encoder: JSONEncoder

    init(config: BackendConfig, urlSession: URLSession = .shared) {
        self.config = config
        self.urlSession = urlSession

        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = Self.isoFractional.date(from: raw) ?? Self.isoPlain.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unparseable date: \(raw)"
            ))
        }
        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601

        if let data = KeychainStore.load(key: Self.sessionKey),
           let saved = try? decoder.decode(Session.self, from: data) {
            session = saved
        }
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // MARK: - Auth (GoTrue)

    private struct AuthResponse: Decodable {
        struct AuthUser: Decodable { let id: UUID }
        let accessToken: String
        let refreshToken: String
        let expiresIn: Double
        let user: AuthUser
    }

    var currentUserID: UUID? { session?.userID }

    private struct OTPRequest: Encodable {
        let email: String?
        let phone: String?
        let createUser: Bool
    }

    private struct VerifyOTPRequest: Encodable {
        let type: String
        let email: String?
        let phone: String?
        let token: String
    }

    private struct IdTokenRequest: Encodable {
        let provider: String
        let idToken: String
        let nonce: String
    }

    /// Sends a 6-digit code. Exactly one of email/phone must be set.
    /// Email codes require the Supabase "Magic Link" template to contain
    /// {{ .Token }}; phone codes require a configured SMS provider.
    func sendOTP(email: String? = nil, phone: String? = nil) async throws {
        try await authRequestVoid(
            path: "otp",
            body: OTPRequest(email: email, phone: phone, createUser: true)
        )
    }

    /// Exchanges destination + code for a session. `type` is "email" for
    /// email codes and "sms" for phone codes.
    func verifyOTP(type: String, email: String? = nil, phone: String? = nil, token: String) async throws -> Session {
        let response: AuthResponse = try await authRequest(
            path: "verify",
            body: VerifyOTPRequest(type: type, email: email, phone: phone, token: token)
        )
        return storeSession(from: response)
    }

    /// Native Sign in with Apple: trades the ASAuthorization identity token
    /// (plus the raw nonce whose SHA-256 was sent to Apple) for a session.
    func signInWithApple(idToken: String, nonce: String) async throws -> Session {
        let response: AuthResponse = try await authRequest(
            path: "token?grant_type=id_token",
            body: IdTokenRequest(provider: "apple", idToken: idToken, nonce: nonce)
        )
        return storeSession(from: response)
    }

    /// Returns a valid session, transparently refreshing an expired token.
    func validSession() async throws -> Session? {
        guard let session else { return nil }
        guard session.isExpired else { return session }
        do {
            let response: AuthResponse = try await authRequest(
                path: "token?grant_type=refresh_token",
                body: ["refresh_token": session.refreshToken]
            )
            return storeSession(from: response)
        } catch {
            // Refresh token revoked/expired — surface as signed out.
            clearSession()
            return nil
        }
    }

    func signOut() async {
        if let session, !session.isExpired {
            var request = makeRequest(url: authURL(path: "logout"), method: "POST")
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
            _ = try? await urlSession.data(for: request)
        }
        clearSession()
    }

    private func storeSession(from response: AuthResponse) -> Session {
        let new = Session(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresAt: Date().addingTimeInterval(response.expiresIn),
            userID: response.user.id
        )
        session = new
        if let data = try? encoder.encode(new) {
            KeychainStore.save(data, key: Self.sessionKey)
        }
        return new
    }

    private func clearSession() {
        session = nil
        KeychainStore.delete(key: Self.sessionKey)
    }

    private func authRequestVoid<B: Encodable>(path: String, body: B) async throws {
        var request = makeRequest(url: authURL(path: path), method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await urlSession.data(for: request)
        try check(response, data: data)
    }

    private func authRequest<B: Encodable, R: Decodable>(path: String, body: B) async throws -> R {
        var request = makeRequest(url: authURL(path: path), method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await urlSession.data(for: request)
        try check(response, data: data)
        return try decoder.decode(R.self, from: data)
    }

    private func authURL(path: String) -> URL {
        URL(string: "\(config.url.absoluteString)/auth/v1/\(path)")!
    }

    // MARK: - PostgREST

    func select<R: Decodable>(_ table: String, query: [URLQueryItem]) async throws -> [R] {
        let data = try await rest(table: table, method: "GET", query: query, body: nil)
        return try decoder.decode([R].self, from: data)
    }

    @discardableResult
    func upsert<B: Encodable, R: Decodable>(
        _ table: String,
        values: B,
        onConflict: String? = nil
    ) async throws -> [R] {
        var query: [URLQueryItem] = []
        var prefer = "return=representation"
        if let onConflict {
            query.append(URLQueryItem(name: "on_conflict", value: onConflict))
            prefer += ",resolution=merge-duplicates"
        }
        let data = try await rest(
            table: table, method: "POST", query: query,
            body: try encoder.encode(values), prefer: prefer
        )
        return try decoder.decode([R].self, from: data)
    }

    func update<B: Encodable>(_ table: String, values: B, query: [URLQueryItem]) async throws {
        _ = try await rest(
            table: table, method: "PATCH", query: query,
            body: try encoder.encode(values), prefer: "return=minimal"
        )
    }

    func delete(_ table: String, query: [URLQueryItem]) async throws {
        _ = try await rest(table: table, method: "DELETE", query: query, body: nil, prefer: "return=minimal")
    }

    func rpc<R: Decodable>(_ function: String, params: [String: String]) async throws -> R {
        let data = try await rest(
            table: "rpc/\(function)", method: "POST", query: [],
            body: try encoder.encode(params)
        )
        return try decoder.decode(R.self, from: data)
    }

    func rpcVoid(_ function: String, params: [String: String]) async throws {
        _ = try await rest(
            table: "rpc/\(function)", method: "POST", query: [],
            body: try encoder.encode(params)
        )
    }

    private func rest(
        table: String,
        method: String,
        query: [URLQueryItem],
        body: Data?,
        prefer: String? = nil
    ) async throws -> Data {
        guard let session = try await validSession() else { throw ClientError.notAuthenticated }
        var components = URLComponents(
            url: config.url.appendingPathComponent("rest/v1/\(table)"),
            resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty { components.queryItems = query }
        var request = makeRequest(url: components.url!, method: method)
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(prefer ?? "return=representation", forHTTPHeaderField: "Prefer")
        request.httpBody = body
        let (data, response) = try await urlSession.data(for: request)
        try check(response, data: data)
        return data
    }

    // MARK: - Storage

    func uploadObject(bucket: String, path: String, data: Data, contentType: String) async throws {
        guard let session = try await validSession() else { throw ClientError.notAuthenticated }
        let url = config.url.appendingPathComponent("storage/v1/object/\(bucket)/\(path)")
        var request = makeRequest(url: url, method: "POST")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "x-upsert")
        request.httpBody = data
        let (responseData, response) = try await urlSession.data(for: request)
        try check(response, data: responseData)
    }

    func downloadObject(bucket: String, path: String) async throws -> Data {
        guard let session = try await validSession() else { throw ClientError.notAuthenticated }
        let url = config.url.appendingPathComponent("storage/v1/object/authenticated/\(bucket)/\(path)")
        var request = makeRequest(url: url, method: "GET")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        try check(response, data: data)
        return data
    }

    // MARK: - Shared

    private func makeRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        return request
    }

    private struct ErrorBody: Decodable {
        let message: String?
        let msg: String?
        let errorDescription: String?
    }

    private func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }
        let parsed = try? decoder.decode(ErrorBody.self, from: data)
        let message = parsed?.message ?? parsed?.msg ?? parsed?.errorDescription
            ?? String(data: data, encoding: .utf8) ?? ""
        throw ClientError.http(status: http.statusCode, message: message)
    }
}

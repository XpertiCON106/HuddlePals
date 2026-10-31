import Foundation

/// Zero-dependency Supabase client over URLSession, speaking the stable
/// REST surfaces directly: GoTrue (auth), PostgREST (rows + RPC), and
/// Storage (objects). Covers exactly what HuddlePals needs — not a general SDK.
/// An actor: `session` is read and written from concurrent refresh flows
/// (huddle list, home, reminders), so access must be serialized.
actor SupabaseClient {
    struct Session: Codable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
        /// `Id`, never `ID`: the snake-case encoder writes "user_id", which
        /// decodes back only to `userId`. A `userID` here silently failed to
        /// decode, so every relaunch looked signed out.
        let userId: UUID
        /// How the account signs in, as GoTrue lists it ("apple", "email").
        /// nil in sessions saved before it was kept: those were all Apple's.
        var providers: [String]? = nil

        var isExpired: Bool { Date() > expiresAt.addingTimeInterval(-60) }
        var signsInWithApple: Bool { providers?.contains("apple") ?? true }
    }

    enum ClientError: LocalizedError {
        case notAuthenticated
        case invalidURL
        case http(status: Int, message: String)

        /// User-facing copy — deliberately generic so raw PostgREST/GoTrue
        /// detail (constraint names, internals) never reaches the UI. The
        /// raw `message` stays available as the associated value for the
        /// services that map specific server errors to typed app errors.
        var errorDescription: String? {
            switch self {
            case .notAuthenticated:
                return "Not signed in."
            case .invalidURL:
                return "Something went wrong. Please try again."
            case .http(let status, _):
                // 401: the token itself was refused. 403 is PostgREST's answer
                // to an access rule saying no (e.g. a huddle you've left), not
                // an expired session.
                if status == 401 {
                    return "Your session has expired. Please sign in again."
                }
                if status == 403 {
                    return "You don't have access to that any more."
                }
                return "Something went wrong. Please try again."
            }
        }
    }

    private let config: BackendConfig
    private let urlSession: URLSession
    private var session: Session?
    /// Keychain account holding the session. Tests use their own, so a run
    /// never clears a real sign-in on the simulator.
    private let sessionKey: String

    let decoder: JSONDecoder
    let encoder: JSONEncoder

    /// No HTTP cache: `URLSession.shared` keeps responses (rows with
    /// captions and comments, profile photos) on disk under Library/Caches,
    /// where sign-out can't reach them. Photos have their own cache.
    static func makeURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    /// Called when the server ends the session (a refused refresh token, e.g.
    /// after signing out everywhere), so the app returns to sign-in instead
    /// of failing every request with "Not signed in".
    private let onSessionEnded: @Sendable () -> Void

    init(
        config: BackendConfig,
        urlSession: URLSession = SupabaseClient.makeURLSession(),
        onSessionEnded: @escaping @Sendable () -> Void = {},
        sessionKey: String = "supabase.session"
    ) {
        self.config = config
        self.urlSession = urlSession
        self.onSessionEnded = onSessionEnded
        self.sessionKey = sessionKey
        decoder = Self.makeDecoder()
        encoder = Self.makeEncoder()

        if let data = KeychainStore.load(key: sessionKey),
           let saved = try? decoder.decode(Session.self, from: data) {
            session = saved
        }
    }

    /// The wire + Keychain JSON decoding: snake_case keys, ISO-8601 dates
    /// with or without fractional seconds. Shared with tests.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = isoFractional.date(from: raw) ?? isoPlain.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unparseable date: \(raw)"
            ))
        }
        return decoder
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
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
        struct AuthUser: Decodable {
            struct AppMetadata: Decodable { let providers: [String]? }
            let id: UUID
            let appMetadata: AppMetadata?
        }
        let accessToken: String
        let refreshToken: String
        let expiresIn: Double
        let user: AuthUser
    }

    var currentUserID: UUID? { session?.userId }
    var signsInWithApple: Bool { session?.signsInWithApple ?? true }

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

    private struct PasswordRequest: Encodable {
        let email: String
        let password: String
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

    /// Email and password, for an account made with a password in the
    /// Supabase dashboard (App Review's demo account). The app never makes one.
    func signInWithPassword(email: String, password: String) async throws -> Session {
        let response: AuthResponse = try await authRequest(
            path: "token?grant_type=password",
            body: PasswordRequest(email: email, password: password)
        )
        return storeSession(from: response)
    }

    /// An in-flight token refresh, shared by concurrent callers — GoTrue
    /// refresh tokens are single-use, so two parallel refreshes with the
    /// same token would invalidate the session.
    private var refreshTask: Task<Session?, Error>?

    /// Returns a valid session, transparently refreshing an expired token.
    /// nil means definitively signed out; a transient failure (offline,
    /// server error) throws instead, so callers never destroy a session
    /// that would refresh fine once connectivity returns.
    func validSession() async throws -> Session? {
        guard let session else { return nil }
        guard session.isExpired else { return session }
        if let refreshTask {
            return try await refreshTask.value
        }
        let task = Task<Session?, Error> { [refreshToken = session.refreshToken] in
            do {
                let response: AuthResponse = try await authRequest(
                    path: "token?grant_type=refresh_token",
                    body: ["refresh_token": refreshToken]
                )
                return storeSession(from: response)
            } catch ClientError.http(let status, _) where Self.refusesSession(status) {
                // Refresh token revoked/expired — surface as signed out.
                clearSession()
                onSessionEnded()
                return nil
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    /// A 4xx answer to a refresh means the token is no good, except a
    /// timeout (408) or GoTrue's rate limit (429): those say nothing about
    /// the session, and signing out on them would wipe a valid one.
    static func refusesSession(_ status: Int) -> Bool {
        (400..<500).contains(status) && status != 408 && status != 429
    }

    func signOut() async {
        if let session, !session.isExpired, let url = try? authURL(path: "logout") {
            var request = makeRequest(url: url, method: "POST")
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
            _ = try? await urlSession.data(for: request)
        }
        clearSession()
    }

    // MARK: - Edge functions

    /// Invokes a deployed edge function with the current user's bearer token.
    func invokeFunction(_ name: String, body: Data? = nil) async throws {
        guard let session = try await validSession() else { throw ClientError.notAuthenticated }
        let url = config.url.appendingPathComponent("functions/v1/\(name)")
        var request = makeRequest(url: url, method: "POST")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body ?? Data("{}".utf8)
        let (data, response) = try await urlSession.data(for: request)
        try check(response, data: data)
    }

    private func storeSession(from response: AuthResponse) -> Session {
        let new = Session(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresAt: Date().addingTimeInterval(response.expiresIn),
            userId: response.user.id,
            providers: response.user.appMetadata?.providers
        )
        session = new
        if let data = try? encoder.encode(new) {
            KeychainStore.save(data, key: sessionKey)
        }
        return new
    }

    private func clearSession() {
        session = nil
        KeychainStore.delete(key: sessionKey)
    }

    private func authRequestVoid<B: Encodable>(path: String, body: B) async throws {
        var request = makeRequest(url: try authURL(path: path), method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await urlSession.data(for: request)
        try check(response, data: data)
    }

    private func authRequest<B: Encodable, R: Decodable>(path: String, body: B) async throws -> R {
        var request = makeRequest(url: try authURL(path: path), method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await urlSession.data(for: request)
        try check(response, data: data)
        return try decoder.decode(R.self, from: data)
    }

    private func authURL(path: String) throws -> URL {
        guard let url = URL(string: "\(config.url.absoluteString)/auth/v1/\(path)") else {
            throw ClientError.invalidURL
        }
        return url
    }

    // MARK: - PostgREST

    func select<R: Decodable>(_ table: String, query: [URLQueryItem]) async throws -> [R] {
        let data = try await rest(table: table, method: "GET", query: query, body: nil)
        return try decoder.decode([R].self, from: data)
    }

    /// Rows asked for per request by `selectAll`. PostgREST cuts every
    /// response at the project's max-rows setting (Supabase default 1000) and
    /// silently drops the rest, so a read that can grow without bound must page.
    static let pageSize = 500

    /// Every row matching `query`, fetched a page at a time in a stable order.
    /// Oldest first, so rows inserted mid-read land on a later page instead of
    /// shifting earlier ones out of the result.
    func selectAll<R: Decodable>(
        _ table: String,
        query: [URLQueryItem],
        order: String = "created_at.asc,id.asc"
    ) async throws -> [R] {
        var rows: [R] = []
        while true {
            let page: [R] = try await select(table, query: query + [
                URLQueryItem(name: "order", value: order),
                URLQueryItem(name: "limit", value: String(Self.pageSize)),
                URLQueryItem(name: "offset", value: String(rows.count)),
            ])
            rows += page
            if page.count < Self.pageSize { return rows }
        }
    }

    /// `ignoreDuplicates`: an existing row is left alone (ON CONFLICT DO
    /// NOTHING, which returns no row) instead of merged (DO UPDATE, which
    /// needs an UPDATE policy: reactions and blocks deliberately have none).
    @discardableResult
    func upsert<B: Encodable, R: Decodable>(
        _ table: String,
        values: B,
        onConflict: String? = nil,
        ignoreDuplicates: Bool = false
    ) async throws -> [R] {
        var query: [URLQueryItem] = []
        var prefer = "return=representation"
        if let onConflict {
            query.append(URLQueryItem(name: "on_conflict", value: onConflict))
            prefer += ignoreDuplicates ? ",resolution=ignore-duplicates" : ",resolution=merge-duplicates"
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
        guard var components = URLComponents(
            url: config.url.appendingPathComponent("rest/v1/\(table)"),
            resolvingAgainstBaseURL: false
        ) else { throw ClientError.invalidURL }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw ClientError.invalidURL }
        var request = makeRequest(url: url, method: method)
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(prefer ?? "return=representation", forHTTPHeaderField: "Prefer")
        request.httpBody = body
        let (data, response) = try await urlSession.data(for: request)
        try check(response, data: data)
        return data
    }

    // MARK: - Storage

    /// Insert-only upload. Deliberately no `x-upsert`: every caller writes a
    /// fresh UUID path, an upsert would need an UPDATE storage policy that
    /// huddle paths don't (and mustn't) have, and overwriting is exactly what
    /// once-and-permanent forbids.
    func uploadObject(bucket: String, path: String, data: Data, contentType: String) async throws {
        guard let session = try await validSession() else { throw ClientError.notAuthenticated }
        let url = config.url.appendingPathComponent("storage/v1/object/\(bucket)/\(path)")
        var request = makeRequest(url: url, method: "POST")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
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

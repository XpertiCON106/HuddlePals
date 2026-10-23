import CryptoKit
import Foundation
import SwiftData

@testable import HuddlePal

/// Answers the live services' HTTP requests in-process, so what GoTrue,
/// PostgREST and Storage send back (status codes, error bodies, row caps)
/// can be pinned in tests with no server and no network. Every request is
/// logged for assertions.
final class StubURLProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var body = Data("[]".utf8)
        /// Fail the request the way URLSession does when offline.
        var error: URLError?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: ((URLRequest) -> Reply)?
    nonisolated(unsafe) private static var log: [URLRequest] = []

    static func respond(with handler: @escaping (URLRequest) -> Reply) {
        lock.withLock {
            self.handler = handler
            log = []
        }
    }

    static var requests: [URLRequest] { lock.withLock { log } }

    static func reset() {
        lock.withLock {
            handler = nil
            log = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recorded = request
        // URLSession moves the body into a stream before protocols see it.
        if recorded.httpBody == nil, let stream = request.httpBodyStream {
            recorded.httpBody = Data(reading: stream)
        }
        let reply = Self.lock.withLock { () -> Reply in
            Self.log.append(recorded)
            return Self.handler?(recorded) ?? Reply()
        }
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension Data {
    init(reading stream: InputStream) {
        self.init()
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            append(buffer, count: count)
        }
    }
}

/// Wiring for live-service tests against `StubURLProtocol`.
enum LiveStub {
    static let config = BackendConfig(url: URL(string: "https://stub.invalid")!, anonKey: "anon-key")
    /// Not the app's own "supabase.session": a test run must never clear a
    /// real sign-in on the simulator it runs on.
    static let sessionKey = "supabase.session.tests"

    static func urlSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// A client holding a fresh session for `userID`, signed in through a
    /// stubbed email-code verify. Clears any Keychain session first. Give two
    /// clients different `accessToken`s to tell their requests apart.
    static func signedInClient(
        userID: UUID = UUID(),
        expiresIn: Int = 3600,
        accessToken: String = "access",
        onSessionEnded: @escaping @Sendable () -> Void = {}
    ) async throws -> SupabaseClient {
        KeychainStore.delete(key: sessionKey)
        let client = SupabaseClient(
            config: config, urlSession: urlSession(), onSessionEnded: onSessionEnded, sessionKey: sessionKey
        )
        StubURLProtocol.respond { _ in
            Reply(body: json([
                "access_token": accessToken, "refresh_token": "refresh", "expires_in": expiresIn,
                "user": ["id": userID.uuidString],
            ]))
        }
        _ = try await client.verifyOTP(type: "email", email: "me@example.test", token: "123456")
        return client
    }

    typealias Reply = StubURLProtocol.Reply

    static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    /// A PostgREST error body, as raised by `raise exception '<message>'`.
    static func postgrestError(_ message: String, status: Int = 400) -> Reply {
        Reply(status: status, body: json(["code": "P0001", "message": message, "details": NSNull(), "hint": NSNull()]))
    }

    static func inMemoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(HuddleSchema.models),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }
}

/// Identity keys in memory, so keyring tests never touch the Keychain.
final class InMemoryIdentityStore: IdentityKeyStoring {
    private var keys: [UUID: Curve25519.KeyAgreement.PrivateKey] = [:]

    func load(for userID: UUID) -> Curve25519.KeyAgreement.PrivateKey? { keys[userID] }

    func save(_ key: Curve25519.KeyAgreement.PrivateKey, for userID: UUID) -> Bool {
        keys[userID] = key
        return true
    }

    func delete(for userID: UUID) { keys[userID] = nil }
}

/// Key-code checks in memory, for the same reason.
final class InMemoryVerifiedKeys: VerifiedKeyStoring {
    private var keys: [UUID: [UUID: Set<String>]] = [:]

    func contains(_ publicKey: String, member: UUID, owner: UUID) -> Bool {
        keys[owner]?[member]?.contains(publicKey) == true
    }

    func add(_ publicKey: String, member: UUID, owner: UUID) {
        keys[owner, default: [:]][member, default: []].insert(publicKey)
    }

    func removeAll(owner: UUID) { keys[owner] = nil }
}

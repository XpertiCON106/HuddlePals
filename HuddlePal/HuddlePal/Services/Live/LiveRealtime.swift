import Foundation

/// Supabase Realtime over a WebSocket, with no SDK: one channel for the
/// Postgres changes to deposits, comments and reactions (migration 017 puts
/// them in the `supabase_realtime` publication). Realtime checks each row
/// against the table's RLS with this account's token, so only rows it can
/// read arrive; its own changes are skipped. Each change goes to the
/// listeners as the huddle it's in. Connected while signed in and in the
/// foreground; a heartbeat keeps it open (and hands Realtime a refreshed
/// token), and when it drops it reconnects, waiting longer each time.
@MainActor
final class LiveRealtime: LiveUpdatesProtocol {
    nonisolated static let topic = "realtime:huddlepals"
    nonisolated static let tables = ["deposits", "comments", "reactions"]

    private let socketURL: URL?
    private let client: SupabaseClient
    private let store: SupabaseStore
    private let session: AppSession
    private let urlSession = URLSession(configuration: .ephemeral)

    private var listeners: [UUID: AsyncStream<UUID?>.Continuation] = [:]
    private var connection: Task<Void, Never>?
    private var isActive = false
    private var ref = 0

    init(config: BackendConfig, client: SupabaseClient, store: SupabaseStore, session: AppSession) {
        socketURL = Self.socketURL(for: config)
        self.client = client
        self.store = store
        self.session = session
    }

    /// `wss://<project>/realtime/v1/websocket?apikey=…&vsn=1.0.0`.
    nonisolated static func socketURL(for config: BackendConfig) -> URL? {
        var components = URLComponents(
            url: config.url.appendingPathComponent("realtime/v1/websocket"), resolvingAgainstBaseURL: false
        )
        components?.scheme = config.url.scheme == "http" ? "ws" : "wss"
        components?.queryItems = [
            URLQueryItem(name: "apikey", value: config.anonKey),
            URLQueryItem(name: "vsn", value: "1.0.0"),
        ]
        return components?.url
    }

    // MARK: Listeners

    func changes() -> AsyncStream<UUID?> {
        let (stream, continuation) = AsyncStream.makeStream(of: UUID?.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        listeners[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.listeners[id] = nil }
        }
        return stream
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        connection?.cancel()
        connection = active ? Task { [weak self] in await self?.stayConnected() } : nil
    }

    // MARK: Connection

    /// Connects, and reconnects when the connection ends, a second later at
    /// first and up to a minute, until it's no longer wanted.
    private func stayConnected() async {
        var wait = 1.0
        while !Task.isCancelled, isActive {
            if (try? await listen()) == true { wait = 1 }
            guard !Task.isCancelled, isActive else { return }
            try? await Task.sleep(for: .seconds(wait))
            wait = min(wait * 2, 60)
        }
    }

    /// One connection: join the channel, then pass changes on until it
    /// closes. True if it joined (so the next try needn't wait long).
    private func listen() async throws -> Bool {
        guard let socketURL, var token = try await client.validSession()?.accessToken else { return false }
        let socket = urlSession.webSocketTask(with: socketURL)
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }
        try await send(Self.joinMessage(token: token, ref: nextRef()), on: socket)

        let heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard let self, !Task.isCancelled else { return }
                try? await self.send(Self.message(topic: "phoenix", event: "heartbeat", payload: [:], ref: self.nextRef()), on: socket)
                // A refreshed token goes to Realtime before the old one runs out.
                if let fresh = try? await self.client.validSession()?.accessToken, fresh != token {
                    token = fresh
                    try? await self.send(
                        Self.message(topic: Self.topic, event: "access_token", payload: ["access_token": fresh], ref: self.nextRef()),
                        on: socket
                    )
                }
            }
        }
        defer { heartbeat.cancel() }

        var joined = false
        while !Task.isCancelled {
            let message = try await socket.receive()
            guard case .string(let text) = message else { continue }
            if Self.isJoinReply(text) { joined = true }
            if let change = Self.change(in: text) { deliver(change) }
        }
        return joined
    }

    private func send(_ message: [String: Any], on socket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: message)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func nextRef() -> String {
        ref += 1
        return String(ref)
    }

    /// To the listeners: the change's huddle, unless it's this account's own.
    func deliver(_ change: Change) {
        if let me = session.currentUser?.id, change.actorID == me { return }
        let huddleID = change.huddleID ?? change.depositID.flatMap { try? store.deposit(id: $0)?.huddle?.id }
        for listener in listeners.values { listener.yield(huddleID) }
    }

    // MARK: Messages

    nonisolated static func message(topic: String, event: String, payload: [String: Any], ref: String) -> [String: Any] {
        ["topic": topic, "event": event, "payload": payload, "ref": ref]
    }

    /// Joins the channel for every change to the three tables.
    nonisolated static func joinMessage(token: String, ref: String) -> [String: Any] {
        var message = message(topic: topic, event: "phx_join", payload: [
            "config": [
                "broadcast": ["ack": false, "self": false],
                "presence": ["key": ""],
                "postgres_changes": tables.map { ["event": "*", "schema": "public", "table": $0] },
                "private": false,
            ] as [String: Any],
            "access_token": token,
        ], ref: ref)
        message["join_ref"] = ref
        return message
    }

    nonisolated static func isJoinReply(_ text: String) -> Bool {
        guard let json = object(text), json["event"] as? String == "phx_reply", json["topic"] as? String == topic,
              let payload = json["payload"] as? [String: Any] else { return false }
        return payload["status"] as? String == "ok"
    }

    /// A row that changed: whose change it was, and where.
    struct Change: Equatable {
        let table: String
        let actorID: UUID?
        let huddleID: UUID?
        let depositID: UUID?
    }

    /// The change in a `postgres_changes` message; nil for anything else.
    nonisolated static func change(in text: String) -> Change? {
        guard let json = object(text), json["event"] as? String == "postgres_changes",
              let payload = json["payload"] as? [String: Any],
              let data = payload["data"] as? [String: Any],
              let table = data["table"] as? String, tables.contains(table) else { return nil }
        // A delete carries only the old row's id.
        let row = (data["record"] as? [String: Any]).flatMap { $0.isEmpty ? nil : $0 }
            ?? data["old_record"] as? [String: Any] ?? [:]
        func id(_ key: String) -> UUID? { (row[key] as? String).flatMap(UUID.init(uuidString:)) }
        return Change(
            table: table,
            actorID: id(table == "deposits" ? "author_id" : "user_id"),
            huddleID: table == "deposits" ? id("huddle_id") : nil,
            depositID: table == "deposits" ? nil : id("deposit_id")
        )
    }

    nonisolated private static func object(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}

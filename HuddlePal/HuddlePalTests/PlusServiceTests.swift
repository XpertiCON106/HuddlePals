import StoreKit
import StoreKitTest
import SwiftData
import XCTest

@testable import HuddlePal

/// HuddlePals Plus on the device: how a plan status reads (by the server's
/// clock), the offline world's Plus, and the live StoreKit 2 service against
/// a local App Store (`StoreKit/HuddlePalsPlus.storekit`) and a stand-in for
/// the server's verify-subscription and my_entitlement().
@MainActor
final class PlanStatusTests: XCTestCase {
    private func status(
        premium: Bool = true, until: Date? = .now.addingTimeInterval(3600),
        limitsStart: Date? = nil, offset: TimeInterval = 0
    ) -> PlanStatus {
        PlanStatus(isPremium: premium, premiumUntil: until, freeLimitsStart: limitsStart, keptHuddles: 2, huddleLimit: nil, clockOffset: offset)
    }

    func testPlusLastsUntilItRunsOut() {
        let now = Date.now
        let plus = status(until: now.addingTimeInterval(60))
        XCTAssertTrue(plus.isPremium(at: now))
        XCTAssertFalse(plus.isPremium(at: now.addingTimeInterval(61)), "ends when the server would, with no refresh")
        XCTAssertFalse(status(premium: false).isPremium(at: now))
        XCTAssertFalse(status(until: nil).isPremium(at: now))
    }

    func testThePhonesClockSetBackDoesntExtendPlus() {
        let deviceNow = Date.now
        // The phone runs a day behind the server; Plus ended an hour ago by
        // the server's clock.
        let behind = status(until: deviceNow.addingTimeInterval(86_400 - 3600), offset: 86_400)
        XCTAssertFalse(behind.isPremium(at: deviceNow))
        XCTAssertEqual(behind.serverNow(deviceNow: deviceNow).timeIntervalSince(deviceNow), 86_400, accuracy: 0.001)
    }

    func testTheFreeLimitsApplyFromTheirStart() {
        let now = Date.now
        XCTAssertFalse(status(limitsStart: nil).freeLimitsActive(at: now), "off as shipped")
        XCTAssertFalse(status(limitsStart: now.addingTimeInterval(3600)).freeLimitsActive(at: now), "a grace period")
        XCTAssertTrue(status(limitsStart: now.addingTimeInterval(-1)).freeLimitsActive(at: now))
    }
}

/// The offline world's Plus: `MockPlanLedger`, the same ledger the mock huddle
/// service enforces.
@MainActor
final class MockPlusServiceTests: XCTestCase {
    private var deps: AppDependencies!
    private var plans: MockPlanLedger!
    private var you: User!

    override func setUp() async throws {
        try await super.setUp()
        deps = AppDependencies.makeMock(inMemory: true)
        try await deps.seeder.regenerate()
        plans = try XCTUnwrap(deps.mockPlans)
        guard case .signedIn(let user) = try await deps.auth.currentState() else {
            throw XCTSkip("expected the seeded user to be signed in")
        }
        you = user
        deps.session.currentUser = user
    }

    func testNobodySignedInHasNoStatus() {
        deps.session.currentUser = nil
        XCTAssertNil(deps.plus.status)
        XCTAssertFalse(deps.plus.isPremium)
    }

    func testTheStatusReadsTheLedger() throws {
        var status = try XCTUnwrap(deps.plus.status)
        XCTAssertFalse(status.isPremium)
        XCTAssertEqual(status.keptHuddles, 2, "The Crew and Sunday Dinners")
        XCTAssertNil(status.huddleLimit, "no cap while the limits are off")
        XCTAssertFalse(deps.plus.freeLimitsActive)

        plans.freeLimitsActive = true
        status = try XCTUnwrap(deps.plus.status)
        XCTAssertEqual(status.huddleLimit, 3)
        XCTAssertTrue(deps.plus.freeLimitsActive)

        plans.setPlus(true, for: you.id)
        XCTAssertTrue(deps.plus.isPremium)
        XCTAssertEqual(deps.plus.status?.huddleLimit, 10)
    }

    func testBuyingPlusLiftsTheCapsTheMockServerEnforces() async throws {
        plans.freeLimitsActive = true
        let crew = try XCTUnwrap(you.memberships.compactMap(\.huddle).first { $0.inviteCode == SeedDataService.crewInviteCode })
        let newcomer = User(displayName: "Newcomer", avatarColorHex: "46A758")
        deps.modelContainer.mainContext.insert(newcomer)
        do {
            _ = try await deps.huddleService.joinHuddle(inviteCode: crew.inviteCode, user: newcomer)
            XCTFail("full on the free plan")
        } catch HuddleServiceError.huddleFullFree {}

        let products = try await deps.plus.products()
        let monthly = try XCTUnwrap(products.first { $0.period == .month })
        let outcome = await deps.plus.purchase(monthly)
        XCTAssertEqual(outcome, .purchased)
        XCTAssertTrue(deps.plus.isPremium)
        let until = try XCTUnwrap(deps.plus.status?.premiumUntil)
        XCTAssertEqual(until.timeIntervalSinceNow, 30 * 86_400, accuracy: 3 * 86_400, "a month")
        _ = try await deps.huddleService.joinHuddle(inviteCode: crew.inviteCode, user: newcomer)
    }

    func testASubscriptionLinkedElsewhereIsRefusedEitherWay() async throws {
        plans.purchasesLinkedElsewhere = true
        let products = try await deps.plus.products()
        let product = try XCTUnwrap(products.first)
        let bought = await deps.plus.purchase(product)
        XCTAssertEqual(bought, .linkedToAnotherAccount)
        let restored = await deps.plus.restore()
        XCTAssertEqual(restored, .linkedToAnotherAccount)
        XCTAssertFalse(deps.plus.isPremium)
    }

    func testRestoreFindsPlusOrSaysThereIsNone() async {
        let none = await deps.plus.restore()
        XCTAssertEqual(none, .nothingToRestore)
        plans.setPlus(true, for: you.id)
        let restored = await deps.plus.restore()
        XCTAssertEqual(restored, .restored)
    }

    func testPlusThatRunsOutEndsWithNoRefresh() async {
        plans.setPlus(until: .now.addingTimeInterval(-1), for: you.id)
        XCTAssertFalse(deps.plus.isPremium)
        let renews = await deps.plus.appleSubscriptionWillRenew()
        XCTAssertFalse(renews)
    }

    func testTheCatalogMatchesTheStoreKitConfiguration() {
        XCTAssertEqual(MockPlusService.catalog.map(\.id), PlusCatalog.productIDs)
        XCTAssertEqual(MockPlusService.catalog.map(\.displayPrice), ["$2.99", "$24.99"])
    }
}

/// The live service: real StoreKit 2 calls against a local App Store
/// (`SKTestSession`), and the server stubbed (`StubURLProtocol`).
@MainActor
final class LivePlusServiceTests: XCTestCase {
    private var store: SKTestSession!
    private var container: ModelContainer!
    private var session: AppSession!
    private var me: User!
    private var defaults: UserDefaults!
    private var server: FakePlusServer!

    override func setUp() async throws {
        try await super.setUp()
        store = try SKTestSession(contentsOf: try Self.configuration())
        store.resetToDefaultState()
        store.disableDialogs = true
        store.clearTransactions()

        container = try LiveStub.inMemoryContainer()
        me = User(displayName: "Me", avatarColorHex: "E5484D")
        container.mainContext.insert(me)
        session = AppSession()
        session.currentUser = me
        defaults = UserDefaults(suiteName: "LivePlusServiceTests-\(UUID().uuidString)")
        server = FakePlusServer()
    }

    override func tearDown() async throws {
        store.clearTransactions()
        StubURLProtocol.reset()
        KeychainStore.delete(key: LiveStub.sessionKey)
        try await super.tearDown()
    }

    private static func configuration() throws -> URL {
        let bundle = Bundle(for: LivePlusServiceTests.self)
        if let url = bundle.url(forResource: "HuddlePalsPlus", withExtension: "storekit") { return url }
        // Not copied as a resource: read it where it lives in the repo.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("StoreKit/HuddlePalsPlus.storekit")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("HuddlePalsPlus.storekit isn't reachable from the test")
        }
        return url
    }

    /// A service signed in as `me`, talking to `server`.
    private func service(syncWithAppStore: @escaping () async throws -> Void = {}) async throws -> LivePlusService {
        let client = try await LiveStub.signedInClient(userID: me.id)
        let server = server!
        StubURLProtocol.respond { request in server.reply(to: request) }
        return LivePlusService(client: client, session: session, defaults: defaults, syncWithAppStore: syncWithAppStore)
    }

    private func product(_ id: String, in service: LivePlusService) async throws -> PlusProduct {
        let products = try await service.products()
        return try XCTUnwrap(products.first { $0.id == id })
    }

    private func unfinishedCount() async -> Int {
        var count = 0
        for await _ in Transaction.unfinished { count += 1 }
        return count
    }

    /// A purchase made through `SKTestSession` (one made outside the app)
    /// reaches `Transaction.currentEntitlements` a moment after it returns.
    private func waitForEntitlement() async throws {
        for _ in 0..<50 {
            for await _ in Transaction.currentEntitlements { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("the test App Store never listed the purchase")
    }

    func testProductsComeFromTheAppStoreCheapestFirstWithTheTrial() async throws {
        let products = try await service().products()
        XCTAssertEqual(products.map(\.id), [PlusCatalog.monthly, PlusCatalog.annual])
        XCTAssertEqual(products.map(\.period), [.month, .year])
        XCTAssertEqual(products.map(\.freeTrialDays), [7, 7], "nobody here has used the trial")
        XCTAssertTrue(products[0].displayPrice.contains("2.99"))
        XCTAssertTrue(products[1].displayPrice.contains("24.99"))
    }

    func testAPurchaseNamesTheAccountAndThePlusComesFromTheServer() async throws {
        let plus = try await service()
        let outcome = await plus.purchase(try await product(PlusCatalog.monthly, in: plus))
        XCTAssertEqual(outcome, .purchased)
        XCTAssertTrue(plus.isPremium)

        let sent = try XCTUnwrap(server.verifyRequests.first)
        XCTAssertEqual(sent["restore"] as? Bool, false)
        let payload = try XCTUnwrap(FakePlusServer.payload(of: try XCTUnwrap(sent["transaction"] as? String)))
        XCTAssertEqual((payload["appAccountToken"] as? String)?.lowercased(), me.id.uuidString.lowercased(), "the purchase names this account")
        XCTAssertEqual(payload["productId"] as? String, PlusCatalog.monthly)
        let unfinished = await unfinishedCount()
        XCTAssertEqual(unfinished, 0, "finished once the server has it")
    }

    func testAPurchaseTheServerDidntConfirmIsKeptAndSentAgain() async throws {
        let plus = try await service()
        server.offline = true
        let outcome = await plus.purchase(try await product(PlusCatalog.annual, in: plus))
        XCTAssertEqual(outcome, .notConfirmed)
        XCTAssertFalse(plus.isPremium)
        let unfinished = await unfinishedCount()
        XCTAssertEqual(unfinished, 1, "not finished, so StoreKit delivers it again")

        server.offline = false
        await plus.refresh()
        XCTAssertTrue(plus.isPremium, "the next foreground sends it")
        let finished = await unfinishedCount()
        XCTAssertEqual(finished, 0)
    }

    func testASubscriptionAnotherAccountHoldsIsRefused() async throws {
        let plus = try await service()
        server.verifyReply = .init(status: 409, body: LiveStub.json(["error": "subscription_in_use"]))
        let outcome = await plus.purchase(try await product(PlusCatalog.monthly, in: plus))
        XCTAssertEqual(outcome, .linkedToAnotherAccount)
        XCTAssertFalse(plus.isPremium)
    }

    func testAskToBuyWaits() async throws {
        let plus = try await service()
        store.askToBuyEnabled = true
        let outcome = await plus.purchase(try await product(PlusCatalog.monthly, in: plus))
        XCTAssertEqual(outcome, .pending)
        XCTAssertTrue(server.verifyRequests.isEmpty, "nothing to verify until it's approved")
    }

    func testRefreshSendsOnlyThisAccountsSubscriptionRestoreSendsAnyOne() async throws {
        let plus = try await service()
        // Bought outside the app: no appAccountToken.
        _ = try await store.buyProduct(identifier: PlusCatalog.monthly)
        try await waitForEntitlement()
        await plus.refresh()
        XCTAssertTrue(server.verifyRequests.isEmpty, "not this account's to claim without Restore")
        XCTAssertFalse(plus.isPremium)

        let outcome = await plus.restore()
        XCTAssertEqual(outcome, .restored)
        XCTAssertEqual(server.verifyRequests.first?["restore"] as? Bool, true)
        XCTAssertTrue(plus.isPremium)
    }

    func testRestoreSaysWhenTheSubscriptionIsLinkedElsewhereOrThereIsNone() async throws {
        var synced = 0
        let plus = try await service(syncWithAppStore: { synced += 1 })
        let none = await plus.restore()
        XCTAssertEqual(none, .nothingToRestore)
        XCTAssertEqual(synced, 1, "asks the App Store first")

        // Bought in the app by another HuddlePals account on this device.
        _ = try await store.buyProduct(identifier: PlusCatalog.monthly, options: [.appAccountToken(UUID())])
        try await waitForEntitlement()
        server.verifyReply = .init(status: 409, body: LiveStub.json(["error": "subscription_in_use"]))
        let linked = await plus.restore()
        XCTAssertEqual(linked, .linkedToAnotherAccount)
    }

    func testACancelledAppStoreSignInCancelsTheRestore() async throws {
        let plus = try await service(syncWithAppStore: { throw StoreKitError.userCancelled })
        let outcome = await plus.restore()
        XCTAssertEqual(outcome, .cancelled)
    }

    func testTheCachedStatusOpensAnOfflineLaunchForTheSameAccountOnly() async throws {
        server.premiumUntil = .now.addingTimeInterval(86_400)
        let online = try await service()
        await online.refresh()
        XCTAssertTrue(online.isPremium)

        server.offline = true
        let offline = try await service()
        await offline.refresh()
        XCTAssertTrue(offline.isPremium, "the last status, until it runs out")

        let other = User(displayName: "Other", avatarColorHex: "0091FF")
        container.mainContext.insert(other)
        session.currentUser = other
        await offline.refresh()
        XCTAssertNil(offline.status, "never another account's")
    }

    func testSigningOutForgetsTheStatus() async throws {
        server.premiumUntil = .now.addingTimeInterval(86_400)
        let plus = try await service()
        await plus.refresh()
        plus.reset()
        XCTAssertNil(plus.status)
        server.offline = true
        await plus.refresh()
        XCTAssertNil(plus.status, "the cached copy went too")
    }

    func testTheServersClockDecidesWhenPlusEnds() async throws {
        // The phone's clock is an hour fast; Plus ends 30 minutes from now by
        // the server's clock, which is all the phone has to go on.
        server.clockSkew = -3600
        server.premiumUntil = .now.addingTimeInterval(-3600 + 1800)
        let plus = try await service()
        await plus.refresh()
        let status = try XCTUnwrap(plus.status)
        XCTAssertEqual(status.clockOffset, -3600, accuracy: 5)
        XCTAssertTrue(status.isPremium(at: .now))
        XCTAssertFalse(status.isPremium(at: .now.addingTimeInterval(1801)))
    }

    func testAppleKeepsBillingWhileTheSubscriptionRenews() async throws {
        let plus = try await service()
        let before = await plus.appleSubscriptionWillRenew()
        XCTAssertFalse(before)
        _ = await plus.purchase(try await product(PlusCatalog.monthly, in: plus))
        let after = await plus.appleSubscriptionWillRenew()
        XCTAssertTrue(after, "deleting the account wouldn't stop it")
    }
}

/// verify-subscription and my_entitlement(), as far as the app sees them:
/// a verified transaction gives Plus until `premiumUntil`.
final class FakePlusServer: @unchecked Sendable {
    private let lock = NSLock()
    private var _verifyRequests: [[String: Any]] = []
    var offline = false
    var verifyReply = StubURLProtocol.Reply(body: LiveStub.json(["status": "applied"]))
    /// Plus until, once verified (or set up front).
    var premiumUntil: Date?
    /// The server's clock minus the device's.
    var clockSkew: TimeInterval = 0

    var verifyRequests: [[String: Any]] { lock.withLock { _verifyRequests } }

    func reply(to request: URLRequest) -> StubURLProtocol.Reply {
        if offline { return .init(error: URLError(.notConnectedToInternet)) }
        let path = request.url?.path ?? ""
        if path.hasSuffix("/functions/v1/verify-subscription") {
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
            lock.withLock { _verifyRequests.append(body) }
            if verifyReply.status == 200, premiumUntil == nil {
                premiumUntil = .now.addingTimeInterval(30 * 86_400)
            }
            return verifyReply
        }
        if path.hasSuffix("/rest/v1/rpc/my_entitlement") {
            let iso = ISO8601DateFormatter()
            let serverNow = Date.now.addingTimeInterval(clockSkew)
            let premium = premiumUntil.map { $0 > serverNow } ?? false
            return .init(body: LiveStub.json([[
                "is_premium": premium,
                "premium_until": premiumUntil.map { iso.string(from: $0) as Any } ?? NSNull(),
                "server_now": iso.string(from: serverNow),
                "free_limits_start": NSNull(),
                "kept_huddles": 1,
                "huddle_limit": NSNull(),
            ]]))
        }
        return .init(status: 404, body: Data("{}".utf8))
    }

    /// The decoded payload of a JWS.
    static func payload(of jws: String) -> [String: Any]? {
        let parts = jws.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

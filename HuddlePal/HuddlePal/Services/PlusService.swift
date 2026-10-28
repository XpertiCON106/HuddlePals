import Foundation
import Observation

/// The signed-in account's plan, as the server last reported it
/// (`my_entitlement()`, migration 013). Postgres enforces Plus by its own
/// clock; the app reads this to show what's open and to explain a refusal
/// before it happens. Judged by the server's clock too: `clockOffset` turns
/// the device's clock into it, so setting the phone back doesn't extend Plus.
struct PlanStatus: Codable, Equatable {
    /// Plus at the moment the server answered.
    var isPremium: Bool
    /// When Plus ends (after any billing grace period); nil without one.
    var premiumUntil: Date?
    /// Huddles the account keeps, inherited ones included.
    var keptHuddles: Int
    /// 3 or 10 huddles kept.
    var huddleLimit: Int?
    /// The server's clock minus the device's, when it answered.
    var clockOffset: TimeInterval

    /// The server's clock now, estimated from the device's.
    func serverNow(deviceNow: Date = .now) -> Date {
        deviceNow.addingTimeInterval(clockOffset)
    }

    /// Plus right now: what the server said, until it runs out.
    func isPremium(at deviceNow: Date = .now) -> Bool {
        guard isPremium, let premiumUntil else { return false }
        return premiumUntil > serverNow(deviceNow: deviceNow)
    }
}

/// A HuddlePals+ subscription the App Store sells, ready to show.
struct PlusProduct: Identifiable, Equatable, Sendable {
    enum Period: Equatable, Sendable {
        case month
        case year
    }

    let id: String
    let displayName: String
    /// Localized, as the App Store charges it ("$2.99").
    let displayPrice: String
    let period: Period
    /// The free trial this Apple Account can still take, in days; nil when
    /// there's none (or it was already used).
    let freeTrialDays: Int?
}

enum PurchaseOutcome: Equatable {
    /// The server has it: Plus is on.
    case purchased
    /// Waiting on someone else (Ask to Buy) or the bank; the App Store
    /// finishes it later and `Transaction.updates` delivers it.
    case pending
    case cancelled
    /// This Apple subscription already gives Plus to another HuddlePals
    /// account.
    case linkedToAnotherAccount
    /// Bought, but the server hasn't confirmed it yet (no connection): the
    /// next launch or foreground sends it again.
    case notConfirmed
    case failed(String)
}

enum RestoreOutcome: Equatable {
    case restored
    /// This Apple Account has no active HuddlePals+ subscription.
    case nothingToRestore
    case linkedToAnotherAccount
    case cancelled
    case failed(String)
}

/// HuddlePals+ for the signed-in account: what the server says about it,
/// and buying or restoring it through the App Store. Observable, so screens
/// update when `status` changes.
@MainActor
protocol PlusServiceProtocol: AnyObject {
    /// What the server last said about the signed-in account; nil before
    /// it's known (signed out, or never reached and nothing cached).
    var status: PlanStatus? { get }
    /// At launch: listens for transactions the App Store finishes later
    /// (renewals, Ask to Buy, purchases made on another device).
    func start()
    /// Asks the server again, and sends it any subscription this device
    /// knows of that it hasn't recorded. On launch, sign-in and foreground.
    func refresh() async
    /// The Plus subscriptions on sale, cheapest first.
    func products() async throws -> [PlusProduct]
    func purchase(_ product: PlusProduct) async -> PurchaseOutcome
    /// Restore Purchases: syncs with the App Store, then links this Apple
    /// Account's subscription to the signed-in account if no other has it.
    func restore() async -> RestoreOutcome
    /// Whether this device's Apple Account has a HuddlePals subscription
    /// that will renew: deleting the account doesn't stop Apple's billing.
    func appleSubscriptionWillRenew() async -> Bool
    /// Whether this device's Apple Account already has HuddlePals+, linked
    /// to whichever HuddlePals account: the paywall offers Restore Purchases
    /// then, instead of buying it again.
    func hasAppleSubscription() async -> Bool
    /// Sign-out: forgets the account's status, cached copy included.
    func reset()
}

extension PlusServiceProtocol {
    /// Plus right now, by the server's clock.
    var isPremium: Bool { status?.isPremium(at: .now) ?? false }
}

/// The App Store's catalog, and the offline world's prices for it.
enum PlusCatalog {
    static let monthly = "com.huddlepals.ios.plus.monthly"
    static let annual = "com.huddlepals.ios.plus.yearly"
    static let productIDs = [monthly, annual]
}

// MARK: - Mock

/// The offline world's Plus: buying and restoring flip `MockPlanLedger`, the
/// same ledger the mock huddle service enforces, and the status is read
/// straight from it. Prices are the StoreKit configuration file's.
@MainActor
@Observable
final class MockPlusService: PlusServiceProtocol {
    private let plans: MockPlanLedger
    private let session: AppSession

    static let catalog = [
        PlusProduct(id: PlusCatalog.monthly, displayName: "HuddlePals+", displayPrice: "$2.99", period: .month, freeTrialDays: 7),
        PlusProduct(id: PlusCatalog.annual, displayName: "HuddlePals+", displayPrice: "$24.99", period: .year, freeTrialDays: 7),
    ]

    init(plans: MockPlanLedger, session: AppSession) {
        self.plans = plans
        self.session = session
    }

    var status: PlanStatus? {
        guard let user = session.currentUser else { return nil }
        let premium = plans.hasPlus(user.id)
        return PlanStatus(
            isPremium: premium,
            premiumUntil: plans.plusUntil[user.id],
            keptHuddles: user.memberships.filter { $0.role == .keeper }.count,
            huddleLimit: premium ? HuddleLimits.plusHuddlesKept : HuddleLimits.freeHuddlesKept,
            clockOffset: 0
        )
    }

    func start() {}
    func refresh() async {}

    func products() async throws -> [PlusProduct] {
        Self.catalog
    }

    func purchase(_ product: PlusProduct) async -> PurchaseOutcome {
        guard let user = session.currentUser else { return .failed("Sign in to get HuddlePals+.") }
        if plans.purchasesLinkedElsewhere { return .linkedToAnotherAccount }
        let period: Calendar.Component = product.period == .year ? .year : .month
        let until = Calendar.current.date(byAdding: period, value: 1, to: .now) ?? .distantFuture
        plans.setPlus(until: until, for: user.id)
        return .purchased
    }

    func restore() async -> RestoreOutcome {
        guard let user = session.currentUser else { return .failed("Sign in to restore purchases.") }
        if plans.purchasesLinkedElsewhere { return .linkedToAnotherAccount }
        return plans.hasPlus(user.id) ? .restored : .nothingToRestore
    }

    func appleSubscriptionWillRenew() async -> Bool {
        plans.hasPlus(session.currentUser?.id)
    }

    func hasAppleSubscription() async -> Bool {
        plans.purchasesLinkedElsewhere || plans.hasPlus(session.currentUser?.id)
    }

    func reset() {}
}

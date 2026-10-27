import Foundation
import Observation
import StoreKit

/// HuddlePals+ through StoreKit 2 and the server. The App Store sells
/// the subscription; the server decides: every transaction goes to the
/// verify-subscription edge function, which checks Apple's signature and
/// records it for this account, and `my_entitlement()` says what the account
/// has. A transaction is finished only once the server has it, so one the
/// server never heard about (no connection) is delivered again.
///
/// Purchases name the account (`appAccountToken` = the user's id). A
/// subscription that names another account, or none (bought outside the app),
/// is sent only on Restore Purchases, so a shared iPad never quietly hands a
/// parent's subscription to a child's account.
@MainActor
@Observable
final class LivePlusService: PlusServiceProtocol {
    private(set) var status: PlanStatus?
    /// Whose `status` it is: a sign-in as someone else starts from nothing.
    @ObservationIgnored private var statusUserID: UUID?

    @ObservationIgnored private let client: SupabaseClient
    @ObservationIgnored private let session: AppSession
    @ObservationIgnored private let defaults: UserDefaults
    /// AppStore.sync, replaceable in tests (it asks for the Apple Account's
    /// password on a device).
    @ObservationIgnored private let syncWithAppStore: () async throws -> Void
    @ObservationIgnored private var updates: Task<Void, Never>?
    /// The App Store's products, by id, from the last `products()`.
    @ObservationIgnored private var storeProducts: [String: Product] = [:]

    private static let cacheKey = "huddlepal.plus.status"

    init(
        client: SupabaseClient,
        session: AppSession,
        defaults: UserDefaults = .standard,
        syncWithAppStore: @escaping () async throws -> Void = { try await AppStore.sync() }
    ) {
        self.client = client
        self.session = session
        self.defaults = defaults
        self.syncWithAppStore = syncWithAppStore
    }

    func start() {
        guard updates == nil else { return }
        // Renewals, Ask to Buy approvals, purchases on another device, and
        // any transaction left unfinished last time.
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                // Signed out: left unfinished, so it comes again after sign-in.
                guard let userID = self.session.currentUser?.id else { continue }
                if await self.submit(result, for: userID, restore: false) == .recorded {
                    await self.refreshStatus(for: userID)
                }
            }
        }
    }

    func refresh() async {
        guard let userID = session.currentUser?.id else {
            status = nil
            statusUserID = nil
            return
        }
        if statusUserID != userID {
            status = cachedStatus(for: userID)
            statusUserID = status == nil ? nil : userID
        }
        // Offline, the cached status stands (it still ends at premiumUntil).
        guard await refreshStatus(for: userID), !isPremium else { return }
        // This device has a subscription for this account the server hasn't
        // recorded: bought while offline, or its verify call failed.
        var sent = false
        for await result in Transaction.currentEntitlements {
            if await submit(result, for: userID, restore: false) == .recorded { sent = true }
        }
        if sent { await refreshStatus(for: userID) }
    }

    func products() async throws -> [PlusProduct] {
        let products = try await Product.products(for: PlusCatalog.productIDs)
            .filter { $0.subscription != nil }
            .sorted { $0.price < $1.price }
        storeProducts = Dictionary(products.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [PlusProduct] = []
        for product in products {
            result.append(await Self.plusProduct(product))
        }
        return result
    }

    func purchase(_ product: PlusProduct) async -> PurchaseOutcome {
        guard let userID = session.currentUser?.id else { return .failed("Sign in to get HuddlePals+.") }
        do {
            guard let storeProduct = try await storeProduct(for: product.id) else {
                return .failed("HuddlePals+ isn't available right now. Try again later.")
            }
            switch try await storeProduct.purchase(options: [.appAccountToken(userID)]) {
            case .success(let result):
                switch await submit(result, for: userID, restore: false) {
                case .recorded:
                    await refreshStatus(for: userID)
                    return isPremium ? .purchased : .notConfirmed
                case .inUse:
                    return .linkedToAnotherAccount
                case .unconfirmed:
                    return .notConfirmed
                case .skipped:
                    // StoreKit couldn't verify Apple's signature on it.
                    return .failed("The App Store couldn't confirm this purchase. Try Restore Purchases.")
                }
            case .pending:
                return .pending
            case .userCancelled:
                return .cancelled
            @unknown default:
                return .cancelled
            }
        } catch StoreKitError.userCancelled {
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func restore() async -> RestoreOutcome {
        guard let userID = session.currentUser?.id else { return .failed("Sign in to restore purchases.") }
        do {
            try await syncWithAppStore()
        } catch StoreKitError.userCancelled {
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
        var linkedElsewhere = false
        var unconfirmed = false
        for await result in Transaction.currentEntitlements {
            switch await submit(result, for: userID, restore: true) {
            case .inUse: linkedElsewhere = true
            case .unconfirmed: unconfirmed = true
            case .recorded, .skipped: break
            }
        }
        await refreshStatus(for: userID)
        if isPremium { return .restored }
        if linkedElsewhere { return .linkedToAnotherAccount }
        if unconfirmed { return .failed("Couldn't reach HuddlePals. Check your connection and try again.") }
        return .nothingToRestore
    }

    func appleSubscriptionWillRenew() async -> Bool {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, PlusCatalog.productIDs.contains(transaction.productID),
                  let subscription = await transaction.subscriptionStatus,
                  case .verified(let renewal) = subscription.renewalInfo
            else { continue }
            if renewal.willAutoRenew { return true }
        }
        return false
    }

    func reset() {
        status = nil
        statusUserID = nil
        defaults.removeObject(forKey: Self.cacheKey)
    }

    // MARK: - The server

    private enum Submission: Equatable {
        /// The server has it (applied, or it already knew something newer).
        case recorded
        /// Another HuddlePals account holds this subscription.
        case inUse
        /// Not sent: not a verified Plus subscription, or not this account's
        /// to claim without Restore.
        case skipped
        /// Sent, but the server didn't confirm it (offline, or it refused).
        case unconfirmed
    }

    private struct VerifyRequest: Encodable {
        let transaction: String
        let renewalInfo: String?
        let restore: Bool

        enum CodingKeys: String, CodingKey {
            case transaction
            case renewalInfo = "renewal_info"
            case restore
        }
    }

    /// Sends one transaction to verify-subscription and finishes it once the
    /// server has it.
    private func submit(_ result: VerificationResult<Transaction>, for userID: UUID, restore: Bool) async -> Submission {
        // An unverified transaction is never sent: the server would refuse
        // its signature anyway.
        guard case .verified(let transaction) = result,
              PlusCatalog.productIDs.contains(transaction.productID),
              transaction.productType == .autoRenewable
        else { return .skipped }
        if !restore, transaction.appAccountToken != userID { return .skipped }

        var renewalInfo: String?
        if let subscription = await transaction.subscriptionStatus {
            renewalInfo = subscription.renewalInfo.jwsRepresentation
        }
        let request = VerifyRequest(transaction: result.jwsRepresentation, renewalInfo: renewalInfo, restore: restore)
        do {
            try await client.invokeFunction("verify-subscription", body: try JSONEncoder().encode(request))
            await transaction.finish()
            return .recorded
        } catch let SupabaseClient.ClientError.http(status, message) where status == 409 && message.contains("subscription_in_use") {
            // The server knows it, for someone else: nothing to deliver again.
            await transaction.finish()
            return .inUse
        } catch {
            return .unconfirmed
        }
    }

    /// The row my_entitlement() returns.
    private struct EntitlementDTO: Decodable {
        let isPremium: Bool
        let premiumUntil: Date?
        let serverNow: Date
        let keptHuddles: Int
        let huddleLimit: Int?
    }

    /// Asks the server for the account's plan. False when it couldn't be
    /// reached (or the account changed meanwhile).
    @discardableResult
    private func refreshStatus(for userID: UUID) async -> Bool {
        let rows: [EntitlementDTO]
        do {
            rows = try await client.rpc("my_entitlement", params: [:])
        } catch {
            return false
        }
        guard let row = rows.first, session.currentUser?.id == userID else { return false }
        let fresh = PlanStatus(
            isPremium: row.isPremium,
            premiumUntil: row.premiumUntil,
            keptHuddles: row.keptHuddles,
            huddleLimit: row.huddleLimit,
            clockOffset: row.serverNow.timeIntervalSinceNow
        )
        status = fresh
        statusUserID = userID
        save(fresh, for: userID)
        return true
    }

    // MARK: - The cached status

    /// The last status, kept for the next launch: offline, Plus still opens
    /// the archive, and still ends when `premiumUntil` passes.
    private struct CachedStatus: Codable {
        let userID: UUID
        let status: PlanStatus
    }

    private func cachedStatus(for userID: UUID) -> PlanStatus? {
        guard let data = defaults.data(forKey: Self.cacheKey),
              let cached = try? JSONDecoder().decode(CachedStatus.self, from: data),
              cached.userID == userID
        else { return nil }
        return cached.status
    }

    private func save(_ status: PlanStatus, for userID: UUID) {
        if let data = try? JSONEncoder().encode(CachedStatus(userID: userID, status: status)) {
            defaults.set(data, forKey: Self.cacheKey)
        }
    }

    // MARK: - Products

    private func storeProduct(for id: String) async throws -> Product? {
        if let product = storeProducts[id] { return product }
        _ = try await products()
        return storeProducts[id]
    }

    private static func plusProduct(_ product: Product) async -> PlusProduct {
        let subscription = product.subscription
        var trialDays: Int?
        if let subscription, let offer = subscription.introductoryOffer, offer.paymentMode == .freeTrial,
           await subscription.isEligibleForIntroOffer {
            trialDays = days(in: offer.period)
        }
        return PlusProduct(
            id: product.id,
            displayName: product.displayName,
            displayPrice: product.displayPrice,
            period: subscription?.subscriptionPeriod.unit == .year ? .year : .month,
            freeTrialDays: trialDays
        )
    }

    static func days(in period: Product.SubscriptionPeriod) -> Int {
        switch period.unit {
        case .day: period.value
        case .week: 7 * period.value
        case .month: 30 * period.value
        case .year: 365 * period.value
        @unknown default: period.value
        }
    }
}

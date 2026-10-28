import Foundation
import Observation

/// Why the paywall opened. Its headline answers that first.
enum PaywallContext: String, Identifiable {
    case archive
    case video
    case createHuddle
    case invites
    case profile
    /// The intro after a first post, or a HuddlePals+ reminder.
    case promotion

    var id: String { rawValue }

    var headline: String {
        switch self {
        case .archive: "Unlock your full huddle archive with HuddlePals+"
        case .video: "Post 6-second video drops with HuddlePals+"
        case .createHuddle: "Keep up to 10 huddles with HuddlePals+"
        case .invites: "Reopen invites with HuddlePals+"
        case .profile: "HuddlePals+"
        case .promotion: "More room for your huddles with HuddlePals+"
        }
    }

    var symbol: String {
        switch self {
        case .archive: "archivebox.fill"
        case .video: "video.fill"
        case .createHuddle: "square.stack.3d.up.fill"
        case .invites: "person.badge.plus"
        case .profile, .promotion: "person.3.fill"
        }
    }
}

/// The paywall: the App Store's Plus plans with their prices and terms
/// (what guideline 3.1.2 asks a subscription to show), buying one, and
/// Restore Purchases. Works the same against the mock catalog.
@MainActor
@Observable
final class PaywallViewModel {
    enum Phase: Equatable {
        case loading
        case ready
        case unavailable(String)
    }

    private let deps: AppDependencies
    let context: PaywallContext

    private(set) var phase: Phase = .loading
    private(set) var products: [PlusProduct] = []
    var selectedID: String?
    private(set) var isWorking = false
    /// What happened to the last purchase or restore, when it needs saying.
    private(set) var message: String?
    /// Plus just turned on: the welcome screen shows until Continue.
    private(set) var didUnlock = false
    /// This Apple Account already has HuddlePals+ (it may need restoring
    /// here, or be another account's): Restore takes the buy button's place.
    private(set) var appleAccountHasPlus = false
    /// The subscription belongs to another HuddlePals account: said in an
    /// alert, too easy to miss as a line of text.
    var isLinkedElsewhereAlertPresented = false

    static let linkedElsewhere = "This Apple Account's HuddlePals+ is already linked to another HuddlePals account. Sign in to that account to use it, or write to \(AppLinks.contactEmail) to move it."

    init(deps: AppDependencies, context: PaywallContext) {
        self.deps = deps
        self.context = context
    }

    var isPremium: Bool { deps.plus.isPremium }
    /// Apple's subscription settings exist only for a real subscription.
    var canManageSubscription: Bool { deps.isLive }
    var premiumUntil: Date? { deps.plus.status?.premiumUntil }

    var selected: PlusProduct? {
        products.first { $0.id == selectedID } ?? products.first
    }

    /// Restore Purchases instead of the plans: buying again would only find
    /// the subscription this Apple Account already has.
    var offersRestoreInsteadOfBuying: Bool {
        appleAccountHasPlus && !isPremium && !didUnlock
    }

    func load() async {
        if !isPremium { appleAccountHasPlus = await deps.plus.hasAppleSubscription() }
        do {
            products = try await deps.plus.products()
            selectedID = products.first { $0.period == .year }?.id ?? products.first?.id
            phase = products.isEmpty ? .unavailable("HuddlePals+ isn't available right now. Try again later.") : .ready
        } catch {
            phase = .unavailable("Couldn't reach the App Store. Check your connection and try again.")
        }
    }

    func purchase() async {
        guard let selected, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        message = nil
        switch await deps.plus.purchase(selected) {
        case .purchased:
            unlock()
        case .pending:
            message = "Waiting for approval. Plus turns on as soon as the purchase goes through."
        case .cancelled:
            break
        case .linkedToAnotherAccount:
            message = Self.linkedElsewhere
            isLinkedElsewhereAlertPresented = true
        case .notConfirmed:
            message = "Your purchase went through. HuddlePals is still confirming it, and Plus turns on shortly — there's no need to buy it again."
        case .failed(let reason):
            message = reason
        }
    }

    func restore() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        message = nil
        switch await deps.plus.restore() {
        case .restored:
            unlock()
        case .nothingToRestore:
            message = "No HuddlePals+ subscription was found for this Apple Account."
        case .linkedToAnotherAccount:
            message = Self.linkedElsewhere
            isLinkedElsewhereAlertPresented = true
        case .cancelled:
            break
        case .failed(let reason):
            message = reason
        }
    }

    private func unlock() {
        didUnlock = true
        Haptics.success()
    }

    // MARK: Wording

    static func periodWord(_ period: PlusProduct.Period) -> String {
        period == .year ? "year" : "month"
    }

    /// "$2.99 a month".
    static func price(_ product: PlusProduct) -> String {
        "\(product.displayPrice) a \(periodWord(product.period))"
    }

    /// "1 week", "3 days", "1 month".
    static func trialLength(days: Int) -> String {
        if days % 30 == 0 { return days == 30 ? "1 month" : "\(days / 30) months" }
        if days % 7 == 0 { return days == 7 ? "1 week" : "\(days / 7) weeks" }
        return days == 1 ? "1 day" : "\(days) days"
    }

    var buttonTitle: String {
        guard let selected else { return "Subscribe" }
        if let days = selected.freeTrialDays { return "Try it free for \(Self.trialLength(days: days))" }
        return "Subscribe for \(Self.price(selected))"
    }

    /// What Apple asks to be said before buying: the price and period, that
    /// it renews by itself, how to stop it, and where the money goes.
    var renewalTerms: String {
        guard let selected else { return "" }
        let period = Self.periodWord(selected.period)
        var terms = ""
        if let days = selected.freeTrialDays {
            terms += "Free for \(Self.trialLength(days: days)), then \(selected.displayPrice) a \(period). "
        }
        terms += "Payment is charged to your Apple Account. HuddlePals+ renews automatically at \(selected.displayPrice) a \(period) unless it's turned off at least 24 hours before the end of the current period. Manage or cancel it any time in Settings › your name › Subscriptions."
        return terms
    }
}

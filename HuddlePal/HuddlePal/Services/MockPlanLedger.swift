import Foundation
import Observation

/// The offline world's `user_entitlements` and `app_limits`: who has
/// HuddlePals Plus and until when, and whether the free plan's limits are on.
/// In memory, like `SkipLedger`; the mock services read it so they refuse
/// what the server would, and Profile's DEBUG section flips it.
@MainActor
@Observable
final class MockPlanLedger {
    /// Off until switched on, as `app_limits.free_limits_start` ships: the
    /// old rules (8 members, no cap on huddles kept) until then, except that
    /// a Plus keeper's huddles take 10.
    var freeLimitsActive = false
    /// Whether the Apple subscription on "this device" is already linked to
    /// another HuddlePals account, so buying or restoring it here is refused
    /// (`subscription_in_use`).
    var purchasesLinkedElsewhere = false
    /// Plus until, per account, by the real clock (the mock day offset only
    /// moves deposits' days).
    private(set) var plusUntil: [UUID: Date] = [:]

    func hasPlus(_ userID: UUID?, now: Date = .now) -> Bool {
        guard let userID, let until = plusUntil[userID] else { return false }
        return until > now
    }

    /// On with no end, or off.
    func setPlus(_ hasPlus: Bool, for userID: UUID) {
        plusUntil[userID] = hasPlus ? .distantFuture : nil
    }

    /// On until `date`: past it, Plus ends exactly as an expired
    /// subscription does on the server.
    func setPlus(until date: Date, for userID: UUID) {
        plusUntil[userID] = date
    }

    func removeAll() {
        freeLimitsActive = false
        purchasesLinkedElsewhere = false
        plusUntil.removeAll()
    }
}

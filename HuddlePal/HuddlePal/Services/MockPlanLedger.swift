import Foundation
import Observation

/// The offline world's `user_entitlements`: who has HuddlePals+ and
/// until when.
/// In memory, like `SkipLedger`; the mock services read it so they refuse
/// what the server would, and Profile's DEBUG section flips it.
@MainActor
@Observable
final class MockPlanLedger {
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
        purchasesLinkedElsewhere = false
        plusUntil.removeAll()
    }
}

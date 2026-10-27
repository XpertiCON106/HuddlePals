import Foundation
import Observation

/// The offline world's `user_entitlements` and `app_limits`: who has
/// HuddlePals Plus, and whether the free plan's limits are on. In memory, like
/// `SkipLedger`; the mock services read it so they refuse what the server
/// would, and Profile's DEBUG section flips it.
@MainActor
@Observable
final class MockPlanLedger {
    /// Off until switched on, as `app_limits.free_limits_start` ships: the
    /// old rules (8 members, no cap on huddles kept) until then.
    var freeLimitsActive = false
    private(set) var plusUserIDs: Set<UUID> = []

    func hasPlus(_ userID: UUID?) -> Bool {
        userID.map(plusUserIDs.contains) ?? false
    }

    func setPlus(_ hasPlus: Bool, for userID: UUID) {
        if hasPlus {
            plusUserIDs.insert(userID)
        } else {
            plusUserIDs.remove(userID)
        }
    }

    func removeAll() {
        freeLimitsActive = false
        plusUserIDs.removeAll()
    }
}

import Foundation
import Observation

/// Injectable clock so the engine and view models never call `Date()`
/// directly — this is what makes "advance mock day by 1" possible.
protocol DateProviding: AnyObject {
    var now: Date { get }
}

@Observable
final class AppDateProvider: DateProviding {
    private static let offsetKey = "vault.debug.dayOffset"

    /// DEBUG: shifts "now" forward by whole days to demo streak math.
    /// Persisted so the simulated day survives relaunch.
    var dayOffset: Int {
        didSet { UserDefaults.standard.set(dayOffset, forKey: Self.offsetKey) }
    }

    init() {
        dayOffset = UserDefaults.standard.integer(forKey: Self.offsetKey)
    }

    var now: Date {
        Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) ?? Date()
    }

    func reset() {
        dayOffset = 0
    }
}

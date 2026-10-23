import Foundation
import Observation

@MainActor
@Observable
final class HuddleHomeViewModel {
    private let deps: AppDependencies
    let huddle: Huddle

    private(set) var todayDeposits: [Deposit] = []
    private(set) var isUnlocked = false
    private(set) var streakCount = 0
    private(set) var members: [User] = []
    /// Non-nil while yesterday broke the streak and the 24h recovery
    /// window is still open.
    private(set) var recovery: HuddleEngine.StreakRecovery?
    /// Set for one render cycle when a deposit flips the gate open, to
    /// drive the lock-opening reveal.
    private(set) var playUnlockReveal = false
    /// False until the first refresh lands: before that, an empty day is
    /// unknown, not "nobody has posted".
    private(set) var hasLoaded = false
    /// The last refresh failed (offline, server error). The screen keeps
    /// its last state and says so.
    private(set) var loadError: String?
    /// Members waiting for the huddle's key until someone checks their key
    /// code (in the huddle's settings).
    private(set) var keyChecks: [KeyCheck] = []

    /// "Ben is waiting…" / "2 members are waiting…"
    var keyCheckSummary: String? {
        guard let first = keyChecks.first else { return nil }
        if keyChecks.count > 1 { return "\(keyChecks.count) members are waiting for this huddle's key." }
        let name = members.first { $0.id == first.userID }?.displayName ?? "A new member"
        return "\(name) is waiting for this huddle's key."
    }

    var showCompose = false

    var currentUser: User? { deps.session.currentUser }

    var todayKey: String {
        deps.engine.todayKey(now: deps.dateProvider.now)
    }

    /// Members who haven't deposited today — drives the "waiting on…" line.
    /// Everyone who deposited today, computed from the *unfiltered* set so
    /// blocking a member never makes them wrongly appear in `waitingOn`.
    private(set) var todayDepositorIDs: Set<UUID> = []

    var waitingOn: [User] {
        members.filter { !todayDepositorIDs.contains($0.id) }
    }

    /// Members still missing from the broken day, resolved to users.
    var recoveryMissingMembers: [User] {
        guard let recovery else { return [] }
        return members.filter { recovery.missingMemberIDs.contains($0.id) }
    }

    init(deps: AppDependencies, huddle: Huddle) {
        self.deps = deps
        self.huddle = huddle
    }

    func refresh() async {
        guard let user = currentUser else {
            todayDeposits = []
            members = []
            isUnlocked = false
            recovery = nil
            hasLoaded = true
            return
        }
        do {
            let all = try await deps.depositService.deposits(in: huddle)
            let key = todayKey
            let todayAll = all.filter { $0.dayKey == key }
            todayDepositorIDs = Set(todayAll.compactMap { $0.author?.id })
            // Hide blocked members' photos from the feed (gate/streak below
            // use the unfiltered set, so blocking is presentational only).
            let blocked = deps.session.blockedUserIDs
            todayDeposits = todayAll
                .filter { !blocked.contains($0.author?.id ?? UUID()) }
                .sorted { $0.createdAt < $1.createdAt }
            members = huddle.members

            let snapshots = all.compactMap(\.snapshot)
            let gateOpen = deps.engine.isUnlocked(
                huddleID: huddle.id,
                currentUserID: user.id,
                deposits: snapshots,
                now: deps.dateProvider.now
            )
            // DEBUG override demos the locked state on demand.
            isUnlocked = gateOpen && !deps.debug.simulateNotPostedToday
            streakCount = huddle.streakCount

            let skips = (try? await deps.huddleService.skipRecords(for: huddle)) ?? [:]
            recovery = deps.engine.recovery(
                memberIDs: Set(members.map(\.id)),
                joinedDayKeys: huddle.memberJoinDayKeys(using: deps.engine),
                deposits: snapshots,
                skips: skips,
                now: deps.dateProvider.now
            )
            // Found by the key sync that loading the deposits just ran.
            keyChecks = await deps.huddleService.keyChecks(for: huddle)
            hasLoaded = true
            loadError = nil
        } catch where error.isCancellation {
            // Left the screen mid-load: nothing went wrong.
        } catch {
            // Pull-based refresh: keep last state on transient failure, and
            // say it's stale rather than pass it off as current.
            loadError = error.localizedDescription
        }
    }

    /// Called when Compose succeeds: recompute streak, reveal, celebrate.
    func handleDepositSuccess() async {
        let wasLocked = !isUnlocked
        deps.debug.simulateNotPostedToday = false
        try? await deps.huddleService.recomputeStreak(for: huddle, now: deps.dateProvider.now)
        await refresh()
        // Uploading silences today's remaining reminders for this huddle.
        await deps.reminders.refresh()
        if wasLocked, isUnlocked {
            playUnlockReveal = true
            Haptics.unlock()
        }
    }

    func unlockRevealFinished() {
        playUnlockReveal = false
    }
}

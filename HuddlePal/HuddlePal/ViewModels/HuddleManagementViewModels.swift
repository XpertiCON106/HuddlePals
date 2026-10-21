import Foundation
import Observation

// MARK: - Create

@MainActor
@Observable
final class CreateHuddleViewModel {
    private let deps: AppDependencies

    var name = ""
    var emoji = "🏔"
    private(set) var createdHuddle: Huddle?
    private(set) var isCreating = false
    private(set) var errorMessage: String?

    static let emojiChoices = ["🏔", "🌊", "🌻", "🔥", "🐾", "🌙", "🍞", "🎒", "🏡", "🌵", "⛺️", "🫶"]

    var canCreate: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...TextLimit.huddleName).contains(trimmed.serverLength) && !isCreating
    }

    /// Stub deep link shared via the share sheet.
    /// TODO: BACKEND — replace with a universal link that routes through
    /// the join RPC.
    var shareURL: URL? {
        createdHuddle.flatMap { URL(string: "huddlepal://join/\($0.inviteCode)") }
    }

    init(deps: AppDependencies) {
        self.deps = deps
    }

    func create() async {
        guard canCreate, let user = deps.session.currentUser else { return }
        isCreating = true
        defer { isCreating = false }
        do {
            let huddle = try await deps.huddleService.createHuddle(name: name, emoji: emoji, keeper: user)
            createdHuddle = huddle
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Join

@MainActor
@Observable
final class JoinHuddleViewModel {
    private let deps: AppDependencies

    var code = ""
    private(set) var joinedHuddle: Huddle?
    private(set) var isJoining = false
    private(set) var errorMessage: String?

    var canJoin: Bool {
        code.trimmingCharacters(in: .whitespacesAndNewlines).count == 6 && !isJoining
    }

    init(deps: AppDependencies) {
        self.deps = deps
        // A huddlepal://join/<code> link may have arrived before this screen.
        if let pending = deps.session.pendingInviteCode {
            code = pending
            deps.session.pendingInviteCode = nil
        }
    }

    func join() async {
        guard canJoin, let user = deps.session.currentUser else { return }
        isJoining = true
        errorMessage = nil
        defer { isJoining = false }
        do {
            let huddle = try await deps.huddleService.joinHuddle(inviteCode: code, user: user)
            joinedHuddle = huddle
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Settings

@MainActor
@Observable
final class HuddleSettingsViewModel {
    private let deps: AppDependencies
    let huddle: Huddle

    private(set) var didLeave = false
    private(set) var errorMessage: String?

    init(deps: AppDependencies, huddle: Huddle) {
        self.deps = deps
        self.huddle = huddle
    }

    var memberships: [Membership] { huddle.sortedMemberships }

    var streakDetail: String {
        if huddle.streakCount == 0 {
            return "No active streak. It starts the next day everyone deposits."
        }
        var line = "\(huddle.streakCount) day\(huddle.streakCount == 1 ? "" : "s") and counting."
        if let last = huddle.lastStreakDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            line += " Last counted day: \(formatter.string(from: last))."
        }
        return line
    }

    /// Persists the huddle's preferred hour (shown here, used when seeding /
    /// surfacing the huddle's rhythm). Notification *delivery* is owned by
    /// the per-user reminder in Profile (`deps.reminders`), so this no
    /// longer schedules its own notification — that avoided a member in
    /// several huddles getting one nudge per huddle on top of the per-user one.
    func setNotificationHour(_ hour: Int) async {
        try? await deps.huddleService.updateNotificationHour(hour, for: huddle)
    }

    func leaveHuddle() async {
        guard let user = deps.session.currentUser else { return }
        do {
            try await deps.huddleService.leaveHuddle(huddle, user: user)
            didLeave = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

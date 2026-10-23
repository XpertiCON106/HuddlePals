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
    /// The new huddle's invite; nil only if it couldn't be issued yet (the
    /// huddle's settings retry).
    private(set) var inviteCode: InviteCode?
    private(set) var isCreating = false
    private(set) var errorMessage: String?

    /// Six rows of six in the picker: places and nature, then the people a
    /// huddle is usually for, what they do together, trips and seasons.
    static let emojiChoices = [
        "🏔", "🌊", "🌻", "🔥", "🐾", "🌙",
        "🍞", "🎒", "🏡", "🌵", "⛺️", "🫶",
        "👨‍👩‍👧‍👦", "🧑‍🤝‍🧑", "❤️", "🎉", "📸", "🎂",
        "☕️", "🍕", "🍳", "🍷", "🎮", "🎵",
        "📚", "⚽️", "🏃", "🚲", "✈️", "🎓",
        "🏖", "🌸", "🍂", "❄️", "🐶", "🐱",
    ]

    var canCreate: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...TextLimit.huddleName).contains(trimmed.serverLength) && !isCreating
    }

    /// Shared via the share sheet: the link plus the code itself, for
    /// pasting where custom-scheme links don't open.
    /// TODO: BACKEND — a universal link would open in any app.
    var shareURL: URL? {
        inviteCode.map(InviteLink.url(for:))
    }

    var shareMessage: String {
        InviteShare.message(huddleName: createdHuddle?.name ?? "", code: inviteCode)
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
            inviteCode = try? await deps.huddleService.inviteCode(for: huddle)
            createdHuddle = huddle
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        // The first huddle is when notifications start to matter.
        await deps.push.huddleJoined()
    }
}

/// The words that go with a shared invite.
enum InviteShare {
    static func message(huddleName: String, code: InviteCode?) -> String {
        var text = "Join our huddle \"\(huddleName)\" on HuddlePals."
        if let code { text += " Invite code: \(code.displayed)" }
        return text
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

    /// A whole code, or an old 6-character one (which `join` explains).
    var canJoin: Bool {
        (InviteCode(code) != nil || InviteCode.isLegacy(code)) && !isJoining
    }

    init(deps: AppDependencies) {
        self.deps = deps
        // A huddlepal://join/<code> link may have arrived before this screen.
        usePendingInvite()
    }

    /// Takes the code of a huddlepal://join/<code> link, once. Also called
    /// when a link arrives while this screen is already open.
    func usePendingInvite() {
        guard let pending = deps.session.pendingInviteCode else { return }
        code = pending
        errorMessage = nil
        deps.session.pendingInviteCode = nil
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
            return
        }
        await deps.push.huddleJoined()
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
    private(set) var inviteCode: InviteCode?
    private(set) var isLoadingInvite = false
    private(set) var isResettingInvite = false
    /// Why the invite isn't shown, or why a reset failed.
    private(set) var inviteMessage: String?
    /// Members waiting for the huddle's key until someone checks their code.
    private(set) var keyChecks: [KeyCheck] = []
    private(set) var isConfirmingKeyCheck = false
    /// Why sharing the key after a check failed.
    private(set) var keyCheckMessage: String?

    init(deps: AppDependencies, huddle: Huddle) {
        self.deps = deps
        self.huddle = huddle
    }

    func loadKeyChecks() async {
        keyChecks = await deps.huddleService.keyChecks(for: huddle)
    }

    /// The name to ask for: whoever the huddle lists under that account.
    func name(for check: KeyCheck) -> String {
        huddle.members.first { $0.id == check.userID }?.displayName ?? "A new member"
    }

    /// Codes matched: the key goes to them. False if it didn't.
    func confirm(_ check: KeyCheck) async -> Bool {
        guard !isConfirmingKeyCheck else { return false }
        isConfirmingKeyCheck = true
        defer { isConfirmingKeyCheck = false }
        do {
            try await deps.huddleService.confirmKeyCheck(check, in: huddle)
            keyChecks.removeAll { $0.userID == check.userID }
            keyCheckMessage = nil
            Haptics.success()
            return true
        } catch {
            keyCheckMessage = error.localizedDescription
            return false
        }
    }

    var inviteShareURL: URL? {
        inviteCode.map(InviteLink.url(for:))
    }

    var inviteShareMessage: String {
        InviteShare.message(huddleName: huddle.name, code: inviteCode)
    }

    /// Loads the code to show; a huddle still on an old code gets a new one.
    func loadInvite() async {
        guard inviteCode == nil, !isLoadingInvite else { return }
        isLoadingInvite = true
        defer { isLoadingInvite = false }
        do {
            inviteCode = try await deps.huddleService.inviteCode(for: huddle)
            inviteMessage = inviteCode == nil ? HuddleServiceError.inviteUnavailable.errorDescription : nil
        } catch where error.isCancellation {
            // Left the screen mid-load; "Try again" is still there.
        } catch {
            inviteMessage = HuddleServiceError.inviteUnavailable.errorDescription
        }
    }

    /// Keeper only: replaces the code; the old one stops working.
    func resetInvite() async {
        guard isKeeper, let user = deps.session.currentUser, !isResettingInvite else { return }
        isResettingInvite = true
        defer { isResettingInvite = false }
        do {
            inviteCode = try await deps.huddleService.resetInviteCode(for: huddle, by: user)
            inviteMessage = nil
            Haptics.success()
        } catch {
            inviteMessage = error.localizedDescription
        }
    }

    var memberships: [Membership] { huddle.sortedMemberships }

    /// Only the keeper may change huddle settings. For anyone else the
    /// server's rule silently updates nothing, so the control is off.
    var isKeeper: Bool {
        guard let me = deps.session.currentUser?.id else { return false }
        return huddle.memberships.contains { $0.user?.id == me && $0.role == .keeper }
    }

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
        guard isKeeper else { return }
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

import Foundation
import Observation

// MARK: - Create

@MainActor
@Observable
final class CreateVaultViewModel {
    private let deps: AppDependencies

    var name = ""
    var emoji = "🏔"
    private(set) var createdVault: Vault?
    private(set) var isCreating = false
    private(set) var errorMessage: String?

    static let emojiChoices = ["🏔", "🌊", "🌻", "🔥", "🐾", "🌙", "🍞", "🎒", "🏡", "🌵", "⛺️", "🫶"]

    var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isCreating
    }

    /// Stub deep link shared via the share sheet.
    /// TODO: BACKEND — replace with a universal link that routes through
    /// the join RPC.
    var shareURL: URL? {
        createdVault.flatMap { URL(string: "vault://join/\($0.inviteCode)") }
    }

    init(deps: AppDependencies) {
        self.deps = deps
    }

    func create() async {
        guard canCreate, let user = deps.session.currentUser else { return }
        isCreating = true
        defer { isCreating = false }
        do {
            let vault = try await deps.vaultService.createVault(name: name, emoji: emoji, keeper: user)
            createdVault = vault
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Join

@MainActor
@Observable
final class JoinVaultViewModel {
    private let deps: AppDependencies

    var code = ""
    private(set) var joinedVault: Vault?
    private(set) var isJoining = false
    private(set) var errorMessage: String?

    var canJoin: Bool {
        code.trimmingCharacters(in: .whitespacesAndNewlines).count == 6 && !isJoining
    }

    init(deps: AppDependencies) {
        self.deps = deps
        // A vault://join/<code> link may have arrived before this screen.
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
            let vault = try await deps.vaultService.joinVault(inviteCode: code, user: user)
            joinedVault = vault
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Settings

@MainActor
@Observable
final class VaultSettingsViewModel {
    private let deps: AppDependencies
    let vault: Vault

    private(set) var didLeave = false
    private(set) var errorMessage: String?

    init(deps: AppDependencies, vault: Vault) {
        self.deps = deps
        self.vault = vault
    }

    var memberships: [Membership] { vault.sortedMemberships }

    var streakDetail: String {
        if vault.streakCount == 0 {
            return "No active streak. It starts the next day everyone deposits."
        }
        var line = "\(vault.streakCount) day\(vault.streakCount == 1 ? "" : "s") and counting."
        if let last = vault.lastStreakDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            line += " Last counted day: \(formatter.string(from: last))."
        }
        return line
    }

    /// Persists the vault's preferred hour (shown here, used when seeding /
    /// surfacing the vault's rhythm). Notification *delivery* is owned by
    /// the per-user reminder in Profile (`deps.reminders`), so this no
    /// longer schedules its own notification — that avoided a member in
    /// several vaults getting one nudge per vault on top of the per-user one.
    func setNotificationHour(_ hour: Int) async {
        try? await deps.vaultService.updateNotificationHour(hour, for: vault)
    }

    func leaveVault() async {
        guard let user = deps.session.currentUser else { return }
        do {
            try await deps.vaultService.leaveVault(vault, user: user)
            didLeave = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

import Foundation

protocol NotificationServiceProtocol: AnyObject {
    func requestAuthorization() async -> Bool
    /// Schedules the daily "deposit your memory" reminder at the vault's
    /// notification hour.
    func scheduleDailyReminder(vaultID: UUID, vaultName: String, hour: Int) async
    func cancelDailyReminder(vaultID: UUID) async
}

// MARK: - Mock

/// No-op. The notification hour picker in Vault Settings writes to the
/// model; nothing is actually scheduled in MVP.
final class MockNotificationService: NotificationServiceProtocol {
    func requestAuthorization() async -> Bool {
        // TODO: BACKEND — UNUserNotificationCenter.requestAuthorization for
        // local reminders, plus APNs registration once the backend can send
        // "everyone else has deposited" pushes.
        true
    }

    func scheduleDailyReminder(vaultID: UUID, vaultName: String, hour: Int) async {
        // TODO: BACKEND — schedule a UNCalendarNotificationTrigger at `hour`
        // local time; later, move to server-driven APNs so the prompt can
        // say who has already deposited.
    }

    func cancelDailyReminder(vaultID: UUID) async {
        // TODO: BACKEND — remove pending notification requests for this
        // vault's identifier.
    }
}

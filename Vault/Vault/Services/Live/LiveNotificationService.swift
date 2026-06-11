import Foundation
import UserNotifications

/// Real local daily reminders via UNUserNotificationCenter. Server pushes
/// come later.
final class LiveNotificationService: NotificationServiceProtocol {
    private func identifier(for vaultID: UUID) -> String {
        "vault.reminder.\(vaultID.uuidString)"
    }

    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func scheduleDailyReminder(vaultID: UUID, vaultName: String, hour: Int) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier(for: vaultID)])

        let content = UNMutableNotificationContent()
        content.title = vaultName
        content.body = "Time to deposit today's memory. Theirs are waiting."
        content.sound = .default

        var components = DateComponents()
        components.hour = hour
        components.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)

        try? await center.add(UNNotificationRequest(
            identifier: identifier(for: vaultID),
            content: content,
            trigger: trigger
        ))
        // TODO: BACKEND — replace with server-driven APNs so the reminder
        // can say who has already deposited (needs an APNs key + an edge
        // function watching deposit inserts).
    }

    func cancelDailyReminder(vaultID: UUID) async {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [identifier(for: vaultID)])
    }
}

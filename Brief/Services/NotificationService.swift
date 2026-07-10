import Foundation
import UserNotifications

/// Schedules the single daily morning reminder.
@MainActor
@Observable
final class NotificationService {
    static let morningReminderIdentifier = "com.jerry.brief.morning-reminder"

    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    /// Request permission if needed; returns whether notifications are allowed.
    func requestAuthorizationIfNeeded() async -> Bool {
        await refreshAuthorizationStatus()
        switch authorizationStatus {
        case .notDetermined:
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])) ?? false
            await refreshAuthorizationStatus()
            return granted
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }

    /// Re-schedule the repeating morning reminder at the configured time.
    /// The wording never claims the brief is generated — background refresh
    /// is best-effort only.
    func updateMorningReminder(preferences: UserPreferences) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.morningReminderIdentifier])

        guard preferences.notificationsEnabled else { return }
        guard await requestAuthorizationIfNeeded() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Brief"
        content.body = "Your morning brief is waiting."
        content.sound = .default

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: preferences.morningTime,
            repeats: true
        )
        let request = UNNotificationRequest(
            identifier: Self.morningReminderIdentifier,
            content: content,
            trigger: trigger
        )
        try? await center.add(request)
    }
}

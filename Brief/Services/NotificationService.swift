import Foundation
import UserNotifications

/// Schedules the daily morning reminder and fires immediate breaking-alert
/// notifications.
@MainActor
@Observable
final class NotificationService {
    static let morningReminderIdentifier = "com.jerry.brief.morning-reminder"
    static let breakingAlertCategory = "com.jerry.brief.breaking-alert"

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

    /// Fires immediately for a hurdle-cleared breaking alert. Separate
    /// identifier per alert (rather than the fixed morning-reminder one)
    /// so multiple rare alerts in one day each show up instead of
    /// replacing each other, and `trigger: nil` delivers it right away
    /// rather than scheduling it for later.
    func sendBreakingAlertNotification(headline: String) async {
        guard await requestAuthorizationIfNeeded() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Brief · Breaking"
        content.body = headline
        content.sound = .default
        content.categoryIdentifier = Self.breakingAlertCategory

        let request = UNNotificationRequest(
            identifier: "\(Self.breakingAlertCategory).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}

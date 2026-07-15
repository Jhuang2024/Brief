import GoogleSignIn
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // BGTaskScheduler requires registration before launch finishes.
        AppEnvironment.shared.backgroundRefresh.register()
        UNUserNotificationCenter.current().delegate = self
        AppearanceConfiguration.apply()
        GoogleAuthenticationService.configureIfPossible()
        return true
    }

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        GIDSignIn.sharedInstance.handle(url)
    }

    // Tapping the morning reminder opens Today; the cached brief renders
    // immediately and generation starts if it is missing. Tapping a
    // breaking alert also opens Today, but must never trigger a full
    // brief generation - the alert is already stored and shown inline,
    // and generating a brief was never one of the two conditions that are
    // allowed to spend API credits.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let isBreakingAlert = response.notification.request.content.categoryIdentifier
            == NotificationService.breakingAlertCategory
        Task { @MainActor in
            let environment = AppEnvironment.shared
            environment.selectedTab = .today
            if !isBreakingAlert {
                // Tapping the morning reminder can cold-launch the app, so
                // the previous Google session hasn't been restored into this
                // process yet - GIDSignIn's currentUser is nil until
                // ensureLaunched() runs. Without awaiting it first, this
                // notification-triggered generation races ahead and bakes a
                // false "Calendar unavailable" into the very brief the tap
                // was meant to open. ensureLaunched() is memoized, so it's a
                // no-op if Today's onAppear already ran it.
                await environment.ensureLaunched()
                await environment.engine.generateIfNeeded(trigger: .notification)
            }
            completionHandler()
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

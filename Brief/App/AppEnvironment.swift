import Foundation
import SwiftData
import SwiftUI

enum RootTab: Hashable {
    case today, history, settings
}

/// The app's dependency container. Built once at launch and injected
/// into the view tree via `.environment(_:)`.
@MainActor
@Observable
final class AppEnvironment {
    static let shared = AppEnvironment()

    let modelContainer: ModelContainer
    let preferencesStore: PreferencesStore
    let briefStore: BriefStore
    let googleAuth: GoogleAuthenticationService
    let locationService: LocationService
    let notificationService: NotificationService
    let engine: BriefingEngine
    let backgroundRefresh: BackgroundRefreshService
    let speech: SpeechService

    /// Selected tab, settable from anywhere (e.g. notification taps,
    /// "Open Settings" buttons).
    var selectedTab: RootTab = .today

    private init() {
        let schema = Schema([DailyBrief.self, BriefSection.self, BriefStory.self, BriefSource.self])
        do {
            modelContainer = try ModelContainer(for: schema)
        } catch {
            // Storage is unrecoverable — fall back to an in-memory store so
            // the app still launches and can regenerate today's brief.
            let fallback = ModelConfiguration(isStoredInMemoryOnly: true)
            modelContainer = try! ModelContainer(for: schema, configurations: fallback)
        }

        preferencesStore = PreferencesStore()
        briefStore = BriefStore(container: modelContainer)
        googleAuth = GoogleAuthenticationService()
        locationService = LocationService()
        notificationService = NotificationService()
        engine = BriefingEngine(
            store: briefStore,
            preferencesStore: preferencesStore,
            googleAuth: googleAuth,
            locationService: locationService
        )
        backgroundRefresh = BackgroundRefreshService(
            engine: engine,
            store: briefStore,
            preferencesStore: preferencesStore
        )
        speech = SpeechService()
    }

    /// Launch-time work: restore Google, prune history, schedule
    /// background refresh and the morning reminder.
    func onLaunch() async {
        briefStore.pruneOldBriefs()
        backgroundRefresh.scheduleNextRefresh()
        await googleAuth.restorePreviousSession()
        await notificationService.updateMorningReminder(preferences: preferencesStore.preferences)
    }
}

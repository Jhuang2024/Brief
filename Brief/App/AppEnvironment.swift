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
    let alertStore: BreakingAlertStore
    let breakingCheck: BreakingCheckService
    let backgroundRefresh: BackgroundRefreshService
    let speech: SpeechService

    /// Selected tab, settable from anywhere (e.g. notification taps,
    /// "Open Settings" buttons).
    var selectedTab: RootTab = .today

    private var launchTask: Task<Void, Never>?

    private init() {
        // Before SwiftData touches the store: take a byte-for-byte copy of
        // the raw store files if the schema changed since last launch, and
        // log any container-path changes. See PersistenceGuard.
        PersistenceGuard.runPreLaunchChecks()

        let schema = Schema([
            DailyBrief.self, BriefSection.self, BriefStory.self, BriefSource.self, BreakingAlert.self,
        ])
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
        alertStore = BreakingAlertStore(container: modelContainer)
        breakingCheck = BreakingCheckService(
            store: briefStore,
            alertStore: alertStore,
            preferencesStore: preferencesStore,
            notificationService: notificationService
        )
        backgroundRefresh = BackgroundRefreshService(
            preferencesStore: preferencesStore,
            breakingCheckService: breakingCheck
        )
        speech = SpeechService()
    }

    /// Launch-time work: restore Google, prune history, schedule the
    /// breaking-check background task and the morning reminder
    /// notification. Safe to call from multiple places (the app-level
    /// launch task and Today's onAppear both call this) — the underlying
    /// work runs exactly once, and every caller awaits the same
    /// completion. This matters because Today's generation reads
    /// `googleAuth`'s connection state to decide whether Calendar is
    /// available; without this memoized await, generation could start
    /// before Google's previous session finished restoring and would
    /// wrongly report Calendar as unavailable.
    func ensureLaunched() async {
        if let launchTask {
            await launchTask.value
            return
        }
        let task = Task {
            await briefStore.pruneOldBriefs()
            await alertStore.pruneOld()
            backgroundRefresh.scheduleNextBreakingCheck()
            await googleAuth.restorePreviousSession()
            await notificationService.updateMorningReminder(preferences: preferencesStore.preferences)
        }
        launchTask = task
        await task.value
    }
}

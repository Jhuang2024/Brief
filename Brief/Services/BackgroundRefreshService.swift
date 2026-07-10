import BackgroundTasks
import Foundation

/// Registers and schedules Brief's two best-effort background tasks: the
/// morning brief pre-generation, and the hourly breaking-news check. Both
/// are `BGAppRefreshTask`s, which iOS runs at its own discretion, not on a
/// guaranteed schedule — neither task's absence or lateness should ever
/// leave the app in a broken state, only a slightly stale one that the
/// matching foreground fallback (`generateIfNeeded`, `checkIfDue`) picks
/// up next time the app is opened.
@MainActor
final class BackgroundRefreshService {
    static let refreshTaskIdentifier = "com.jerry.brief.refresh"
    static let breakingCheckTaskIdentifier = "com.jerry.brief.breakingcheck"

    private let engine: BriefingEngine
    private let store: BriefStore
    private let preferencesStore: PreferencesStore
    private let breakingCheckService: BreakingCheckService
    private let googleAuth: GoogleAuthenticationService

    init(
        engine: BriefingEngine,
        store: BriefStore,
        preferencesStore: PreferencesStore,
        breakingCheckService: BreakingCheckService,
        googleAuth: GoogleAuthenticationService
    ) {
        self.engine = engine
        self.store = store
        self.preferencesStore = preferencesStore
        self.breakingCheckService = breakingCheckService
        self.googleAuth = googleAuth
    }

    /// Must be called before `didFinishLaunching` returns.
    func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshTaskIdentifier,
            using: .main
        ) { [weak self] task in
            // Registered on the main queue, so hopping to the main actor is safe.
            MainActor.assumeIsolated {
                guard let self, let refreshTask = task as? BGAppRefreshTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.handleRefresh(refreshTask)
            }
        }
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.breakingCheckTaskIdentifier,
            using: .main
        ) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self, let checkTask = task as? BGAppRefreshTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.handleBreakingCheck(checkTask)
            }
        }
    }

    /// Schedule the next attempt shortly before the configured morning time.
    func scheduleNextRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
        request.earliestBeginDate = nextMorningRunDate()
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Submitted once at launch and again after every run (success or
    /// not), so the check keeps recurring roughly hourly with only ever
    /// one request in flight. No-ops when the feature is off in Settings.
    func scheduleNextBreakingCheck(after date: Date = Date()) {
        guard preferencesStore.preferences.breakingAlertsEnabled else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.breakingCheckTaskIdentifier)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: Self.breakingCheckTaskIdentifier)
        request.earliestBeginDate = Calendar.current.date(byAdding: .minute, value: 60, to: date)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func nextMorningRunDate(now: Date = Date()) -> Date? {
        var components = preferencesStore.preferences.morningTime
        // Aim ~30 minutes ahead of the briefing time.
        let minutes = (components.hour ?? 7) * 60 + (components.minute ?? 30) - 30
        components.hour = max(0, minutes) / 60
        components.minute = max(0, minutes) % 60
        return Calendar.current.nextDate(
            after: now, matching: components, matchingPolicy: .nextTime
        )
    }

    /// Only ever pre-generates today's brief if it doesn't exist yet — an
    /// existing brief is never regenerated here just because it's gotten
    /// old during the day. This mirrors `BriefingEngine.generateIfNeeded`'s
    /// two-condition rule (morning time, or manual refresh) exactly;
    /// without matching it here, a background firing later in the day
    /// could silently burn API credits regenerating a brief nobody asked
    /// to refresh.
    private func handleRefresh(_ task: BGAppRefreshTask) {
        // Always keep the chain alive for tomorrow.
        scheduleNextRefresh()

        let work = Task { [engine, store, googleAuth] in
            if store.todaysBrief() != nil {
                task.setTaskCompleted(success: true)
                return
            }
            // A BGAppRefreshTask can fire in a freshly-spawned process with
            // no foreground launch preceding it, so nothing has called
            // AppEnvironment.ensureLaunched() yet this run — GIDSignIn's
            // `currentUser` is nil until a session is explicitly restored,
            // even though a previous sign-in exists on disk. Without this,
            // fetchCalendarContext's "is a session available" check passes
            // (it only checks whether a previous sign-in exists), but the
            // actual token fetch then fails because no session was ever
            // restored into this process — silently generating a brief
            // that reports Calendar as unavailable despite being connected.
            await googleAuth.restorePreviousSession()
            await engine.generateIfNeeded(trigger: .background)
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = { [engine] in
            work.cancel()
            Task { @MainActor in
                engine.cancelGeneration()
            }
        }
    }

    private func handleBreakingCheck(_ task: BGAppRefreshTask) {
        let work = Task { [breakingCheckService] in
            await breakingCheckService.checkIfDue()
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = {
            work.cancel()
        }
        scheduleNextBreakingCheck()
    }
}

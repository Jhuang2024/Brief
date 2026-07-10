import BackgroundTasks
import Foundation

/// Best-effort pre-generation of the morning brief via BGAppRefreshTask.
/// iOS decides when (and whether) the task actually runs, so the app
/// never depends on it: launch-time generation is the reliable path.
@MainActor
final class BackgroundRefreshService {
    static let taskIdentifier = "com.jerry.brief.refresh"

    private let engine: BriefingEngine
    private let store: BriefStore
    private let preferencesStore: PreferencesStore

    init(engine: BriefingEngine, store: BriefStore, preferencesStore: PreferencesStore) {
        self.engine = engine
        self.store = store
        self.preferencesStore = preferencesStore
    }

    /// Must be called before `didFinishLaunching` returns.
    func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: .main
        ) { [weak self] task in
            // Registered on the main queue, so hopping to the main actor is safe.
            MainActor.assumeIsolated {
                guard let self, let refreshTask = task as? BGAppRefreshTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.handle(refreshTask)
            }
        }
    }

    /// Schedule the next attempt shortly before the configured morning time.
    func scheduleNextRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = nextMorningRunDate()
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

    private func handle(_ task: BGAppRefreshTask) {
        // Always keep the chain alive for tomorrow.
        scheduleNextRefresh()

        let work = Task { [engine, store] in
            // Skip when today's brief is already current.
            if let existing = store.todaysBrief(), existing.isCurrent() {
                task.setTaskCompleted(success: true)
                return
            }
            await engine.generate(trigger: .background)
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = { [engine] in
            work.cancel()
            Task { @MainActor in
                engine.cancelGeneration()
            }
        }
    }
}

import BackgroundTasks
import Foundation

/// Registers and schedules Brief's one best-effort background task: the
/// hourly breaking-news check. It's a `BGAppRefreshTask`, which iOS runs at
/// its own discretion, not on a guaranteed schedule; its absence or
/// lateness should never leave the app in a broken state, only a slightly
/// stale one that the foreground fallback (`checkIfDue`) picks up next time
/// the app is opened.
///
/// The morning brief itself is intentionally *not* pre-generated in the
/// background. Two prior attempts at this both proved unreliable in
/// practice: first as a `BGAppRefreshTask` (killed by its ~30s budget long
/// before a full generation could finish), then as a `BGProcessingTask`
/// (more runtime, but iOS still doesn't guarantee it runs at all). Rather
/// than keep fighting scheduling that's fundamentally at iOS's discretion,
/// the morning notification (`NotificationService.updateMorningReminder`)
/// fires on iOS's own reliable notification scheduler and tapping it opens
/// the app and generates the brief in the foreground, where it's guaranteed
/// to actually run.
@MainActor
final class BackgroundRefreshService {
    static let breakingCheckTaskIdentifier = "com.jerry.brief.breakingcheck"

    private let preferencesStore: PreferencesStore
    private let breakingCheckService: BreakingCheckService

    init(
        preferencesStore: PreferencesStore,
        breakingCheckService: BreakingCheckService
    ) {
        self.preferencesStore = preferencesStore
        self.breakingCheckService = breakingCheckService
    }

    /// Must be called before `didFinishLaunching` returns.
    func register() {
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

import Foundation
import SwiftData

/// Watches for ANY SwiftData save, whether from an explicit user action (a
/// brief generating, a breaking alert landing, a restore) or SwiftData's own
/// autosave, and asks `BackupService` for a debounced automatic backup
/// shortly after. This is the same trigger every app in the personal-OS
/// family now uses (see Social Climber): instead of every mutation site
/// having to remember to call `scheduleBackupSoon`, one observer guarantees a
/// backup follows any change that reaches the store, so a code path that
/// forgets to schedule one can never leave a change uncaptured. The existing
/// `scheduleBackupSoon` calls (BriefingEngine, BreakingAlertStore) stay as
/// redundant belt-and-suspenders triggers, on purpose: more than one
/// independent trigger means no single one has to be perfectly reliable.
///
/// Debounced rather than one backup per save, so a burst of saves in quick
/// succession coalesces into a single write via `scheduleBackupSoon`'s own
/// trailing-edge scheduling. The content-hash dedupe inside `performBackup`
/// makes a save that changed nothing observable a cheap no-op.
enum AutoBackupObserver {
    nonisolated(unsafe) private static var observerToken: NSObjectProtocol?

    /// Matches Social Climber's ~2s debounce: long enough to coalesce a burst
    /// of saves, short enough that a backup reliably lands while the app is
    /// still in the foreground.
    private static let debounceSeconds: Double = 2

    /// Call once, right after the container is created. Safe to call more
    /// than once; only the first call registers an observer.
    static func start(container: ModelContainer) {
        guard observerToken == nil else { return }
        observerToken = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: nil,
            queue: .main
        ) { _ in
            BackupService.scheduleBackupSoon(container: container, after: debounceSeconds)
        }
    }
}

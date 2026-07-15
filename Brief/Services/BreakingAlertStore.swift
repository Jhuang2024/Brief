import Foundation
import SwiftData

/// SwiftData persistence for hourly breaking-check alerts. Deliberately
/// separate from `BriefStore` - alerts are a different kind of content
/// (rare, out-of-cycle, dismissible) with their own short retention.
@MainActor
final class BreakingAlertStore {
    static let retentionDays = 7

    let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    init(container: ModelContainer) {
        self.container = container
    }

    func allAlerts() -> [BreakingAlert] {
        let descriptor = FetchDescriptor<BreakingAlert>(
            sortBy: [SortDescriptor(\.detectedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Unread alerts from the last `days` days, for the Today banner.
    func unreadAlerts(days: Int = 1, now: Date = Date()) -> [BreakingAlert] {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) else {
            return []
        }
        return allAlerts().filter { $0.detectedAt >= cutoff && !$0.isRead }
    }

    /// Fingerprints and headlines from recent alerts, so the hourly check
    /// never re-flags something it already surfaced.
    func recentFingerprints(days: Int = 7, now: Date = Date()) -> [String] {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) else {
            return []
        }
        return allAlerts().filter { $0.detectedAt >= cutoff }.map(\.fingerprint)
    }

    func recentHeadlines(days: Int = 7, now: Date = Date()) -> [String] {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) else {
            return []
        }
        return allAlerts().filter { $0.detectedAt >= cutoff }.map(\.headline)
    }

    func save(_ alert: BreakingAlert) {
        context.insert(alert)
        try? context.save()
        BackupService.scheduleBackupSoon(container: container)
    }

    /// Mutates rather than deletes - safe even if a view is currently
    /// rendering this exact alert, unlike a delete of a live-referenced
    /// SwiftData object (see BriefStore.save's doc comment for why that
    /// distinction matters).
    func markRead(_ alert: BreakingAlert) {
        alert.isRead = true
        try? context.save()
    }

    /// Default retention: 7 days - alerts are ephemeral by design, unlike
    /// the 30-day brief history. Runs once per launch alongside
    /// `BriefStore.pruneOldBriefs()`, never mid-session, for the same
    /// reason: deleting an object a view might still be rendering crashes.
    func pruneOld(now: Date = Date()) async {
        guard let cutoff = Calendar.current.date(
            byAdding: .day, value: -Self.retentionDays, to: Calendar.current.startOfDay(for: now)
        ) else { return }
        let stale = allAlerts().filter { $0.detectedAt < cutoff }
        for (index, alert) in stale.enumerated() {
            context.delete(alert)
            if index % 5 == 4 {
                try? context.save()
                await Task.yield()
            }
        }
        try? context.save()
    }
}

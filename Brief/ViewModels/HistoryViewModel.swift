import Foundation

/// Briefs from one calendar month, newest first, for History's archive index.
struct HistoryMonthGroup: Identifiable {
    let id: String
    let monthLabel: String
    let briefs: [DailyBrief]
}

@MainActor
@Observable
final class HistoryViewModel {
    private let environment: AppEnvironment
    private var lastSeenGeneration = -1

    var briefs: [DailyBrief] = []
    var confirmDeleteAll = false
    private(set) var isDeletingAll = false

    init(environment: AppEnvironment = .shared) {
        self.environment = environment
    }

    /// `briefs` grouped by month, preserving the newest-first order the
    /// store already provides.
    var groupedByMonth: [HistoryMonthGroup] {
        let calendar = Calendar.current
        var order: [DateComponents] = []
        var buckets: [DateComponents: [DailyBrief]] = [:]

        for brief in briefs {
            let key = calendar.dateComponents([.year, .month], from: brief.briefingDate)
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(brief)
        }

        return order.map { key in
            let date = calendar.date(from: key) ?? Date()
            return HistoryMonthGroup(
                id: "\(key.year ?? 0)-\(key.month ?? 0)",
                monthLabel: DateFormatting.monthYear.string(from: date),
                briefs: buckets[key] ?? []
            )
        }
    }

    func reload() {
        lastSeenGeneration = environment.engine.generationCounter
        briefs = environment.briefStore.allBriefs()
    }

    func reloadIfGenerationAdvanced() {
        guard environment.engine.generationCounter != lastSeenGeneration else { return }
        reload()
    }

    func delete(_ brief: DailyBrief) {
        environment.briefStore.delete(brief)
        reload()
    }

    /// Async and guarded against re-entry: a month of history can take a
    /// perceptible moment to cascade-delete.
    ///
    /// Clears `briefs` BEFORE the underlying delete runs, not after.
    /// `DailyBrief` is a SwiftData `@Model`, individually
    /// Observable-tracked — `deleteAllHistory()` yields periodically
    /// while it works through a large history, and if the list were
    /// still holding references to those exact objects during that
    /// window, a re-render mid-loop would read a property off an object
    /// that's already been deleted from the context, crashing with
    /// SwiftData's "backing data was detached from a context without
    /// resolving attribute faults." Clearing first means the list has
    /// nothing left to render before any deletion happens, so there's
    /// nothing left to race.
    func deleteAll() async {
        guard !isDeletingAll else { return }
        isDeletingAll = true
        briefs = []
        await environment.briefStore.deleteAllHistory()
        reload()
        isDeletingAll = false
    }
}

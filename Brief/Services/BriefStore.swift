import Foundation
import SwiftData

/// SwiftData persistence for briefings: fetch, save, prune, delete,
/// and the seven-day recent-story memory.
@MainActor
final class BriefStore {
    static let retentionDays = 30

    let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    init(container: ModelContainer) {
        self.container = container
    }

    func todaysBrief(now: Date = Date()) -> DailyBrief? {
        brief(for: now)
    }

    func brief(for date: Date) -> DailyBrief? {
        let dayStart = Calendar.current.startOfDay(for: date)
        guard let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) else {
            return nil
        }
        let predicate = #Predicate<DailyBrief> {
            $0.briefingDate >= dayStart && $0.briefingDate < dayEnd
        }
        var descriptor = FetchDescriptor<DailyBrief>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.generatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    func allBriefs() -> [DailyBrief] {
        let descriptor = FetchDescriptor<DailyBrief>(
            sortBy: [SortDescriptor(\.briefingDate, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Save a new brief. Deliberately does NOT delete any existing brief
    /// for the same day here, even though it's being superseded, and
    /// deliberately does NOT kick off pruning immediately either — a view
    /// (Today, in particular) can still hold a live SwiftUI reference to
    /// that exact object while this runs, since BriefingEngine flips
    /// `isGenerating` to false (which is @Observable and triggers a
    /// re-render) in a `defer` block moments before its caller gets a
    /// chance to refetch and repoint that reference. Deleting the object
    /// out from under a view that's still rendering it — even shortly
    /// after save() returns, via a detached prune task — crashes with
    /// SwiftData's "backing data was detached from a context without
    /// resolving attribute faults." `brief(for:)`/`todaysBrief()` already
    /// sort by `generatedAt` descending and take the first result, so a
    /// temporary extra same-day row is harmless — it's always resolved
    /// correctly to the newest one. `pruneOldBriefs()` already runs once
    /// per launch via `AppEnvironment.ensureLaunched()`, before any
    /// generation starts, which is the only point that's actually safe.
    func save(_ brief: DailyBrief) {
        context.insert(brief)
        try? context.save()
    }

    func delete(_ brief: DailyBrief) {
        context.delete(brief)
        try? context.save()
    }

    func deleteTodaysBrief() {
        if let brief = todaysBrief() {
            delete(brief)
        }
    }

    /// Deletes every stored brief. A month of history cascades through
    /// thousands of section/story/source objects, and SwiftData's
    /// `ModelContext` only runs on the main actor here — deleting them
    /// all in one uninterrupted loop blocks the main thread for the
    /// entire operation with nothing yielded back to the run loop, which
    /// reads to the user as the app freezing. Chunking with periodic
    /// `Task.yield()` calls keeps the UI responsive (spinners animate,
    /// touches still register) across the same total work.
    func deleteAllHistory() async {
        // The user is deliberately clearing everything: mark it so the next
        // launch's automatic empty-store recovery doesn't quietly restore
        // what they just deleted.
        BackupService.markFreshStartChosen()
        let all = allBriefs()
        for (index, brief) in all.enumerated() {
            context.delete(brief)
            if index % 5 == 4 {
                try? context.save()
                await Task.yield()
            }
        }
        try? context.save()
    }

    /// Fingerprints and short summaries from the last `days` days,
    /// sent to the editor so stories are not repeated without cause.
    func recentStoryMemory(days: Int = 7, now: Date = Date()) -> [StoryMemory] {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) else {
            return []
        }
        return allBriefs()
            .filter { $0.briefingDate >= cutoff }
            .flatMap { brief in
                brief.sections.flatMap(\.stories).map { story in
                    StoryMemory(
                        fingerprint: story.fingerprint,
                        headline: story.headline,
                        summary: String(story.summary.prefix(220)),
                        briefingDate: brief.briefingDate
                    )
                }
            }
    }

    /// Default retention: 30 days. Same chunked-yield treatment as
    /// `deleteAllHistory()` — this runs unattended on every launch, so a
    /// long unbroken deletion loop here would silently stall startup.
    /// Also removes same-day briefs superseded by a newer generation
    /// (see `save()` for why those aren't deleted immediately at save time).
    func pruneOldBriefs(now: Date = Date()) async {
        if let cutoff = Calendar.current.date(
            byAdding: .day, value: -Self.retentionDays, to: Calendar.current.startOfDay(for: now)
        ) {
            let stale = allBriefs().filter { $0.briefingDate < cutoff }
            for (index, brief) in stale.enumerated() {
                context.delete(brief)
                if index % 5 == 4 {
                    try? context.save()
                    await Task.yield()
                }
            }
        }
        removeSupersededSameDayBriefs()
        try? context.save()
    }

    /// Keeps only the most recently generated brief for each calendar
    /// day, deleting older duplicates left behind by `save()`.
    private func removeSupersededSameDayBriefs() {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: allBriefs()) { calendar.startOfDay(for: $0.briefingDate) }
        for (_, briefsForDay) in byDay where briefsForDay.count > 1 {
            let newestFirst = briefsForDay.sorted { $0.generatedAt > $1.generatedAt }
            for superseded in newestFirst.dropFirst() {
                context.delete(superseded)
            }
        }
    }
}

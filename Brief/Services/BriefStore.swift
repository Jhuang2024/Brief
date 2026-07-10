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

    /// Save a new brief, replacing any existing brief for the same day.
    func save(_ brief: DailyBrief) {
        if let existing = self.brief(for: brief.briefingDate), existing.id != brief.id {
            context.delete(existing)
        }
        context.insert(brief)
        try? context.save()
        pruneOldBriefs()
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

    func deleteAllHistory() {
        for brief in allBriefs() {
            context.delete(brief)
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

    /// Default retention: 30 days.
    func pruneOldBriefs(now: Date = Date()) {
        guard let cutoff = Calendar.current.date(
            byAdding: .day, value: -Self.retentionDays, to: Calendar.current.startOfDay(for: now)
        ) else { return }
        for brief in allBriefs() where brief.briefingDate < cutoff {
            context.delete(brief)
        }
        try? context.save()
    }
}

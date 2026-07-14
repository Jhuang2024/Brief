import Foundation

/// Reads the brief feeds LockedInFit and Social Climber write into the
/// shared App Group container and slices them into per-brief digests:
/// yesterday's activity plus reminders that matter on the briefing day.
///
/// Everything here is best-effort and read-only. A missing App Group (no
/// signing team, entitlement not granted yet), a missing or corrupt file,
/// or a stale feed all resolve to an `unavailable` digest with a short
/// user-facing note, never an error: the sections should explain
/// themselves rather than silently vanish, so "not set up" is
/// distinguishable from "nothing happened yesterday". No AI model ever
/// sees or rewrites this content; the sections render it verbatim, the
/// same way weather numbers stay faithful to Open-Meteo.
struct LinkedAppsService {
    /// Shared with LockedInFit and Social Climber; all three apps list this
    /// identifier under their App Group capability. See LINKED_APPS.md.
    static let appGroupIdentifier = "group.com.jerry.personalOS"

    /// A feed older than this renders with an "as of" caveat...
    private static let agingAfter: TimeInterval = 24 * 3600
    /// ...and one older than this is treated as absent: reminders computed
    /// two days ago say more about that day than about this morning.
    private static let staleAfter: TimeInterval = 48 * 3600

    /// At most this many reminders per app in one brief.
    private static let maxReminders = 8

    /// Digests for every linked app the user has enabled, in fixed order.
    func digests(preferences: UserPreferences, now: Date = Date(), calendar: Calendar = .current) -> [LinkedAppDigest] {
        var digests: [LinkedAppDigest] = []
        if preferences.includeLockedInFit {
            digests.append(digest(for: .lockedInFit, now: now, calendar: calendar))
        }
        if preferences.includeSocialClimber {
            digests.append(digest(for: .socialClimber, now: now, calendar: calendar))
        }
        return digests
    }

    func digest(for app: LinkedApp, now: Date = Date(), calendar: Calendar = .current) -> LinkedAppDigest {
        guard let feed = readFeed(for: app) else {
            return .init(
                app: app,
                availability: .unavailable,
                feedGeneratedAt: nil,
                activityLabel: "Yesterday",
                activityLines: [],
                todayReminders: [],
                statusNote: "No data yet. Open \(app.displayName) on this iPhone once so it can share its daily summary."
            )
        }

        // Schema versions above ours are fine (changes are additive by
        // contract); version 0 means the field itself failed to decode.
        guard feed.schemaVersion >= LinkedAppFeed.expectedSchemaVersion else {
            return .init(
                app: app,
                availability: .unavailable,
                feedGeneratedAt: nil,
                activityLabel: "Yesterday",
                activityLines: [],
                todayReminders: [],
                statusNote: "\(app.displayName)'s data couldn't be read. Update both apps to their latest versions."
            )
        }

        let age = now.timeIntervalSince(feed.generatedAt)
        guard age <= Self.staleAfter else {
            return .init(
                app: app,
                availability: .unavailable,
                feedGeneratedAt: feed.generatedAt,
                activityLabel: "Yesterday",
                activityLines: [],
                todayReminders: [],
                statusNote: "Last updated \(Self.relativeDay(feed.generatedAt, now: now, calendar: calendar)). Open \(app.displayName) to refresh."
            )
        }

        let activity = Self.pickActivityDay(from: feed.days, now: now, calendar: calendar)
        let reminders = Self.pickReminders(from: feed.reminders, now: now, calendar: calendar)

        // Negative age (a clock oddity) still renders; it just never counts
        // as aging.
        let isAging = age > Self.agingAfter
        return .init(
            app: app,
            availability: isAging ? .aging : .fresh,
            feedGeneratedAt: feed.generatedAt,
            activityLabel: activity.label,
            activityLines: activity.lines,
            todayReminders: reminders,
            statusNote: isAging
                ? "As of \(Self.relativeDay(feed.generatedAt, now: now, calendar: calendar))."
                : nil
        )
    }

    // MARK: - Feed reading

    private func readFeed(for app: LinkedApp) -> LinkedAppFeed? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else { return nil }
        let url = containerURL.appendingPathComponent(app.feedFilename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.brief.decode(LinkedAppFeed.self, from: data)
    }

    // MARK: - Slicing

    /// "yyyy-MM-dd" in the local calendar, matching what the writers emit.
    private static func localDayString(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Yesterday's entry when the feed has one; otherwise the most recent
    /// entry within the last three days, labeled with its actual day so a
    /// quiet Sunday feed still shows Saturday's activity honestly.
    private static func pickActivityDay(
        from days: [LinkedAppFeed.Day], now: Date, calendar: Calendar
    ) -> (label: String, lines: [String]) {
        let candidates: [(offset: Int, key: String)] = (1...3).compactMap { back in
            guard let day = calendar.date(byAdding: .day, value: -back, to: now) else { return nil }
            return (back, localDayString(day, calendar: calendar))
        }
        for candidate in candidates {
            guard let match = days.first(where: { $0.date == candidate.key }), !match.lines.isEmpty else { continue }
            if candidate.offset == 1 {
                return ("Yesterday", Array(match.lines.prefix(8)))
            }
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "EEEE, MMM d"
            let labelDate = calendar.date(byAdding: .day, value: -candidate.offset, to: now) ?? now
            return (formatter.string(from: labelDate), Array(match.lines.prefix(8)))
        }
        return ("Yesterday", [])
    }

    /// Reminders worth showing this morning: everything overdue, plus
    /// anything due on the briefing day itself. Overdue is recomputed here
    /// rather than trusted from the feed alone, because the feed's flag was
    /// evaluated at write time, usually the evening before: a reminder that
    /// was merely "due today" when the app last wrote its feed is overdue
    /// by this morning, and trusting the stale flag would drop it entirely.
    /// Overdue first, then by due time; deterministic tiebreak on id.
    private static func pickReminders(
        from reminders: [LinkedAppFeed.Reminder], now: Date, calendar: Calendar
    ) -> [LinkedAppReminder] {
        let dayStart = calendar.startOfDay(for: now)
        let picked = reminders.compactMap { reminder -> LinkedAppReminder? in
            guard !reminder.title.isEmpty, let dueDate = reminder.dueDate else { return nil }
            let overdue = reminder.overdue || dueDate < dayStart
            guard overdue || calendar.isDate(dueDate, inSameDayAs: now) else { return nil }
            return LinkedAppReminder(
                id: reminder.id,
                title: reminder.title,
                detail: reminder.detail?.isEmpty == true ? nil : reminder.detail,
                dueDate: dueDate,
                isAllDay: reminder.isAllDay,
                overdue: overdue
            )
        }
        return picked
            .sorted {
                if $0.overdue != $1.overdue { return $0.overdue }
                if $0.dueDate != $1.dueDate { return $0.dueDate < $1.dueDate }
                return $0.id < $1.id
            }
            .prefix(maxReminders)
            .map { $0 }
    }

    /// "today at 9:14 PM", "yesterday", "Friday": just enough to explain a
    /// feed's age without a full timestamp.
    private static func relativeDay(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return "today at \(DateFormatting.time.string(from: date))"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE, MMM d"
        return formatter.string(from: date)
    }
}

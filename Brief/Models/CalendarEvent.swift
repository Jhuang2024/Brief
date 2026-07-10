import Foundation

/// A read-only snapshot of a Google Calendar event.
/// Values are taken directly from the Calendar API and are never
/// rewritten by the model.
struct CalendarEvent: Codable, Identifiable, Hashable {
    var id: String
    var calendarID: String
    var title: String
    var start: Date
    var end: Date
    var location: String?
    var isAllDay: Bool
    /// Only sent to OpenRouter when the explicit Settings toggle is on.
    var eventDescription: String?

    /// Key used to deduplicate identical events across merged calendars.
    var dedupeKey: String {
        "\(title.lowercased())|\(start.timeIntervalSince1970)|\(end.timeIntervalSince1970)|\(isAllDay)"
    }

    func timeUntilStart(from now: Date = Date()) -> TimeInterval {
        start.timeIntervalSince(now)
    }

    func isHappening(at now: Date = Date()) -> Bool {
        now >= start && now < end
    }
}

/// A calendar in the user's Google Calendar list, shown in Settings.
struct GoogleCalendarInfo: Codable, Identifiable, Hashable {
    var id: String
    var summary: String
    var isPrimary: Bool
}

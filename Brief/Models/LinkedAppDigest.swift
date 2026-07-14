import Foundation

/// The two companion apps Brief can read morning digests from. Both write a
/// small JSON "brief feed" into the shared App Group container (see
/// LINKED_APPS.md at the repo root for the contract); Brief never touches
/// their databases.
enum LinkedApp: String, Codable, CaseIterable, Identifiable {
    case lockedInFit = "locked_in_fit"
    case socialClimber = "social_climber"

    var id: String { rawValue }

    /// Spaced like the apps' own marketing names; the section header
    /// uppercases this, and "LOCKEDINFIT" run together reads like a typo.
    var displayName: String {
        switch self {
        case .lockedInFit: return "Locked In Fit"
        case .socialClimber: return "Social Climber"
        }
    }

    /// The feed file this app writes into the shared container.
    var feedFilename: String {
        switch self {
        case .lockedInFit: return "lockedinfit_brief_feed_v1.json"
        case .socialClimber: return "socialclimber_brief_feed_v1.json"
        }
    }
}

/// One reminder surfaced from a linked app for the briefing day.
struct LinkedAppReminder: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var detail: String?
    var dueDate: Date
    /// True when the reminder has day precision only, so no time is shown.
    var isAllDay: Bool
    var overdue: Bool
}

/// The slice of a linked app's feed that one briefing actually shows:
/// yesterday's activity lines plus reminders that matter on the briefing
/// day. Persisted on `DailyBrief` as JSON so History renders exactly what
/// the morning showed, even after the live feed moves on.
struct LinkedAppDigest: Codable, Equatable, Identifiable {
    /// How usable the feed was at generation time.
    enum Availability: String, Codable {
        /// Feed present and recently written.
        case fresh
        /// Feed present but 24 to 48 hours old; shown with an "as of" note.
        case aging
        /// Feed missing, unreadable, or older than 48 hours.
        case unavailable
    }

    var app: LinkedApp
    var availability: Availability
    /// When the source app last wrote its feed; nil when never seen.
    var feedGeneratedAt: Date?
    /// User-facing caption for the activity block, computed at generation
    /// time so the view stays dumb: "Yesterday", or a labeled fallback like
    /// "Saturday, Jul 12" when yesterday itself had no data.
    var activityLabel: String
    var activityLines: [String]
    var todayReminders: [LinkedAppReminder]
    /// One short user-facing sentence explaining an aging or unavailable
    /// feed ("Last updated Friday. Open LockedInFit to refresh.").
    var statusNote: String?

    var id: String { app.rawValue }

    /// Whether the section has anything at all worth rendering beyond the
    /// status note.
    var hasContent: Bool {
        !activityLines.isEmpty || !todayReminders.isEmpty
    }
}

// MARK: - Raw feed (wire format)

/// The raw feed a linked app writes, decoded defensively: a missing key,
/// wrong type, or unknown extra field never fails the whole decode, because
/// a partially understood feed is still useful and a failed decode must
/// look identical to "no file at all" (the writers' schemas may drift ahead
/// of Brief's; changes are additive by contract).
struct LinkedAppFeed: Decodable {
    static let expectedSchemaVersion = 1

    var app: String
    var schemaVersion: Int
    var generatedAt: Date
    var days: [Day]
    var reminders: [Reminder]

    /// One local calendar day of activity, newest first in the feed.
    struct Day: Decodable {
        /// Local calendar day as "yyyy-MM-dd".
        var date: String
        var lines: [String]

        private enum CodingKeys: String, CodingKey { case date, lines }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            date = (try? container.decode(String.self, forKey: .date)) ?? ""
            lines = (try? container.decode([String].self, forKey: .lines)) ?? []
        }
    }

    struct Reminder: Decodable {
        var id: String
        var title: String
        var detail: String?
        var dueDate: Date?
        var isAllDay: Bool
        var overdue: Bool

        private enum CodingKeys: String, CodingKey {
            case id, title, detail, dueDate, isAllDay, overdue
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? container.decode(String.self, forKey: .id)) ?? UUID().uuidString
            title = (try? container.decode(String.self, forKey: .title)) ?? ""
            detail = try? container.decode(String.self, forKey: .detail)
            dueDate = try? container.decode(Date.self, forKey: .dueDate)
            isAllDay = (try? container.decode(Bool.self, forKey: .isAllDay)) ?? false
            overdue = (try? container.decode(Bool.self, forKey: .overdue)) ?? false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case app, schemaVersion, generatedAt, days, reminders
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        app = (try? container.decode(String.self, forKey: .app)) ?? ""
        schemaVersion = (try? container.decode(Int.self, forKey: .schemaVersion)) ?? 0
        generatedAt = (try? container.decode(Date.self, forKey: .generatedAt)) ?? .distantPast
        days = (try? container.decode([Day].self, forKey: .days)) ?? []
        reminders = (try? container.decode([Reminder].self, forKey: .reminders)) ?? []
    }
}

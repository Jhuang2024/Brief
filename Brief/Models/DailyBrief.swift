import Foundation
import SwiftData

/// How a generation run ended.
enum BriefGenerationStatus: String, Codable {
    case complete
    case partial
    case failed

    var displayName: String {
        switch self {
        case .complete: return "Complete"
        case .partial: return "Partial"
        case .failed: return "Failed"
        }
    }
}

/// One persisted morning briefing.
@Model
final class DailyBrief {
    @Attribute(.unique) var id: UUID
    /// Start of the local day this briefing covers.
    var briefingDate: Date
    var generatedAt: Date
    var timezoneIdentifier: String
    var locationName: String
    /// Short editorial paragraphs for "The day in one minute".
    var overviewItems: [String]
    @Relationship(deleteRule: .cascade, inverse: \BriefSection.brief)
    var sections: [BriefSection]
    /// JSON-encoded `[CalendarEvent]` snapshot, faithful to Google Calendar.
    var calendarEventsData: Data?
    /// JSON-encoded `WeatherSnapshot`, faithful to Open-Meteo.
    var weatherData: Data?
    var calendarWasAvailable: Bool
    var estimatedReadingMinutes: Int
    var statusRaw: String
    /// Human-readable notes about anything that failed during generation.
    var failureNotes: [String]
    var researchModel: String
    var editorModel: String
    var inputTokens: Int
    var outputTokens: Int
    var generationDuration: TimeInterval

    init(
        id: UUID = UUID(),
        briefingDate: Date,
        generatedAt: Date = Date(),
        timezoneIdentifier: String = TimeZone.current.identifier,
        locationName: String = "",
        overviewItems: [String] = [],
        sections: [BriefSection] = [],
        calendarEvents: [CalendarEvent] = [],
        calendarWasAvailable: Bool = false,
        weather: WeatherSnapshot? = nil,
        estimatedReadingMinutes: Int = 5,
        status: BriefGenerationStatus = .complete,
        failureNotes: [String] = [],
        researchModel: String = "",
        editorModel: String = "",
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        generationDuration: TimeInterval = 0
    ) {
        self.id = id
        self.briefingDate = briefingDate
        self.generatedAt = generatedAt
        self.timezoneIdentifier = timezoneIdentifier
        self.locationName = locationName
        self.overviewItems = overviewItems
        self.sections = sections
        self.calendarEventsData = try? JSONEncoder.brief.encode(calendarEvents)
        self.calendarWasAvailable = calendarWasAvailable
        self.weatherData = weather.flatMap { try? JSONEncoder.brief.encode($0) }
        self.estimatedReadingMinutes = estimatedReadingMinutes
        self.statusRaw = status.rawValue
        self.failureNotes = failureNotes
        self.researchModel = researchModel
        self.editorModel = editorModel
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.generationDuration = generationDuration
    }
}

extension DailyBrief {
    var status: BriefGenerationStatus {
        get { BriefGenerationStatus(rawValue: statusRaw) ?? .complete }
        set { statusRaw = newValue.rawValue }
    }

    var calendarEvents: [CalendarEvent] {
        get {
            guard let calendarEventsData else { return [] }
            return (try? JSONDecoder.brief.decode([CalendarEvent].self, from: calendarEventsData)) ?? []
        }
        set { calendarEventsData = try? JSONEncoder.brief.encode(newValue) }
    }

    var weather: WeatherSnapshot? {
        get {
            guard let weatherData else { return nil }
            return try? JSONDecoder.brief.decode(WeatherSnapshot.self, from: weatherData)
        }
        set { weatherData = newValue.flatMap { try? JSONEncoder.brief.encode($0) } }
    }

    var orderedSections: [BriefSection] {
        sections.sorted { $0.order < $1.order }
    }

    /// The single most important headline, used in History rows.
    var topHeadline: String? {
        orderedSections
            .flatMap(\.orderedStories)
            .max(by: { $0.importanceScore < $1.importanceScore })?
            .headline
    }

    var totalStoryCount: Int {
        sections.reduce(0) { $0 + $1.stories.count }
    }

    /// Whether this briefing counts as current for the refresh policy.
    func isCurrent(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard calendar.isDate(briefingDate, inSameDayAs: now) else { return false }
        guard status != .failed else { return false }
        return now.timeIntervalSince(generatedAt) < 90 * 60
    }
}

extension JSONEncoder {
    static let brief: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    static let brief: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

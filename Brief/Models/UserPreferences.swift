import Foundation
import SwiftUI

enum BriefLength: String, Codable, CaseIterable, Identifiable {
    case quick, standard, thorough
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }

    /// Global multiplier applied to per-section story limits.
    var storyLimitMultiplier: Double {
        switch self {
        case .quick: return 0.6
        case .standard: return 1.0
        case .thorough: return 1.3
        }
    }
}

enum ResearchDepth: String, Codable, CaseIterable, Identifiable {
    case light, standard, deep
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }

    /// Web plugin max_results per research request.
    var webResults: Int {
        switch self {
        case .light: return 5
        case .standard: return 10
        case .deep: return 15
        }
    }

    /// Candidate cap requested from each research call.
    var candidateCap: Int {
        switch self {
        case .light: return 8
        case .standard: return 12
        case .deep: return 18
        }
    }
}

enum TemperatureUnit: String, Codable, CaseIterable, Identifiable {
    case automatic, celsius, fahrenheit
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .celsius: return "Celsius"
        case .fahrenheit: return "Fahrenheit"
        }
    }

    /// Resolved against the current locale when set to automatic.
    var resolved: TemperatureUnit {
        guard self == .automatic else { return self }
        return Locale.current.measurementSystem == .metric ? .celsius : .fahrenheit
    }
}

enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum TextSizePreference: String, Codable, CaseIterable, Identifiable {
    case system, large, extraLarge
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .system: return "System"
        case .large: return "Large"
        case .extraLarge: return "Extra Large"
        }
    }
    var dynamicTypeSize: DynamicTypeSize? {
        switch self {
        case .system: return nil
        case .large: return .xLarge
        case .extraLarge: return .xxxLarge
        }
    }
}

/// Per-section configuration, editable in Settings.
struct SectionConfiguration: Codable, Identifiable, Hashable {
    var category: SectionCategory
    var customTitle: String = ""
    var isEnabled: Bool = true
    var maxStories: Int
    var order: Int

    var id: String { category.rawValue }

    var title: String {
        customTitle.trimmingCharacters(in: .whitespaces).isEmpty
            ? category.defaultTitle
            : customTitle
    }

    static var defaults: [SectionConfiguration] {
        SectionCategory.allCases.enumerated().map { index, category in
            SectionConfiguration(
                category: category,
                maxStories: category.defaultMaxStories,
                order: index
            )
        }
    }
}

/// Everything Jerry can tune, persisted as one JSON blob in UserDefaults.
/// The OpenRouter API key lives in the Keychain, never here.
struct UserPreferences: Codable, Equatable {
    // Briefing
    var morningMinutesAfterMidnight: Int = 7 * 60 + 30 // 7:30 AM
    var briefLength: BriefLength = .standard
    var maxReadingMinutes: Int = 7
    var automaticRefreshEnabled: Bool = true
    var notificationsEnabled: Bool = true
    var includeWhyItMatters: Bool = true
    var includeCalendar: Bool = true
    var includeWeather: Bool = true
    /// Off by default: event descriptions are only sent to OpenRouter when enabled.
    var sendEventDescriptions: Bool = false

    // Sections
    var sections: [SectionConfiguration] = SectionConfiguration.defaults

    // Interests
    var topics: [String]
    var companies: [String]
    var people: [String]
    var f1DriversAndTeams: [String]
    var sportsLeagues: [String]
    var sportsTeams: [String]
    var athletes: [String]
    var universities: [String]
    var excludedKeywords: [String]
    var spoilersEnabled: Bool = true

    // Sources
    var preferredDomains: [String]
    var excludedDomains: [String]
    var preferOfficialSources: Bool = true
    var requireMultipleSourcesForBreaking: Bool = true

    // AI Provider — defaults to OpenRouter, but any endpoint that speaks
    // the OpenAI-style chat completions API can be used by changing the
    // base URL. Structured JSON-schema output and the web-search plugin
    // are OpenRouter extensions to that API; disable either toggle if a
    // different provider doesn't support that exact request shape.
    var apiBaseURL: String = "https://openrouter.ai/api/v1"
    var useStructuredOutput: Bool = true
    var useWebSearchPlugin: Bool = true
    var researchModel: String = "openrouter/auto"
    var editorModel: String = "openrouter/auto"
    var researchDepth: ResearchDepth = .standard

    // Weather & location
    var useCurrentLocation: Bool = true
    var manualCity: String = ""
    var temperatureUnit: TemperatureUnit = .automatic

    // Calendar
    var selectedCalendarIDs: [String] = ["primary"]

    // Appearance
    var theme: AppTheme = .system
    var textSize: TextSizePreference = .system
    var reducedMotion: Bool = false

    var morningTime: DateComponents {
        DateComponents(
            hour: morningMinutesAfterMidnight / 60,
            minute: morningMinutesAfterMidnight % 60
        )
    }

    /// `apiBaseURL` with any trailing slash trimmed, so appending
    /// "/chat/completions" never produces a doubled slash.
    var resolvedAPIBaseURL: URL? {
        let trimmed = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutTrailingSlash = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        guard let url = URL(string: withoutTrailingSlash),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil
        else { return nil }
        return url
    }

    var enabledSections: [SectionConfiguration] {
        sections.filter(\.isEnabled).sorted { $0.order < $1.order }
    }

    func configuration(for category: SectionCategory) -> SectionConfiguration? {
        sections.first { $0.category == category }
    }

    /// Effective story cap for a section after the length multiplier.
    func effectiveMaxStories(for category: SectionCategory) -> Int {
        let base = configuration(for: category)?.maxStories ?? category.defaultMaxStories
        return max(1, Int((Double(base) * briefLength.storyLimitMultiplier).rounded()))
    }

    static let `default` = UserPreferences(
        topics: [
            "Major global developments", "Technology", "Artificial intelligence",
            "Semiconductors", "Startups", "Venture capital",
            "Data-centre infrastructure", "Computing energy use", "Electricity grids",
            "Major financial-market movements", "Significant scientific developments",
        ],
        companies: [
            "OpenAI", "Anthropic", "Google", "Apple", "Nvidia",
        ],
        people: [
            "Lewis Hamilton", "Max Verstappen", "Oscar Piastri",
        ],
        f1DriversAndTeams: [
            "Ferrari", "McLaren", "Red Bull Racing",
            "Lewis Hamilton", "Max Verstappen", "Oscar Piastri",
        ],
        sportsLeagues: [
            "Formula 1", "NBA", "NFL",
        ],
        sportsTeams: [],
        athletes: [],
        universities: [
            "UC Berkeley",
        ],
        excludedKeywords: [
            "celebrity gossip", "influencer drama", "horoscope",
        ],
        preferredDomains: [
            "reuters.com", "apnews.com", "bloomberg.com", "ft.com",
            "formula1.com", "fia.com", "berkeley.edu", "dailycal.org",
            "theverge.com", "arstechnica.com", "techcrunch.com",
        ],
        excludedDomains: []
    )
}

/// Loads and saves `UserPreferences`, observable by SwiftUI.
@MainActor
@Observable
final class PreferencesStore {
    private static let key = "brief.userPreferences.v1"

    var preferences: UserPreferences {
        didSet { save() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = Self.decodeFillingMissingKeysWithDefaults(data) {
            preferences = decoded
        } else {
            preferences = .default
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(preferences) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    func reset() {
        preferences = .default
    }

    /// Plain `Codable` synthesis does not apply a stored property's
    /// default value to a key missing from the decoded JSON — it just
    /// fails to decode. Since every new preference added over time is a
    /// non-optional field with a default, decoding an older saved blob
    /// as-is would throw, and the `try?` in `init()` would silently
    /// discard everything already saved (interests, sources, calendar
    /// selection, …) in favor of `.default`. Instead, merge any keys
    /// missing from the saved JSON in from a freshly encoded `.default`
    /// before decoding, so old saved preferences stay intact across
    /// schema additions.
    private static func decodeFillingMissingKeysWithDefaults(_ data: Data) -> UserPreferences? {
        guard var stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let defaultData = try? JSONEncoder().encode(UserPreferences.default),
              let defaults = (try? JSONSerialization.jsonObject(with: defaultData)) as? [String: Any]
        else {
            return try? JSONDecoder().decode(UserPreferences.self, from: data)
        }
        for (key, value) in defaults where stored[key] == nil {
            stored[key] = value
        }
        guard let mergedData = try? JSONSerialization.data(withJSONObject: stored) else {
            return try? JSONDecoder().decode(UserPreferences.self, from: data)
        }
        return try? JSONDecoder().decode(UserPreferences.self, from: mergedData)
    }
}

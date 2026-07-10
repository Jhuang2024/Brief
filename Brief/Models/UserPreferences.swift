import Foundation
import SwiftUI

/// A built-in AI provider Brief knows how to reach. Each has its own
/// Keychain-stored key and fixed base URL, so both can be configured at
/// once — generation tries `preferredProvider` first and automatically
/// retries with the other one (if it has a saved key) on failure.
enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case openRouter, bazaarlink

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .bazaarlink: return "Bazaarlink"
        }
    }

    var baseURL: URL {
        switch self {
        case .openRouter: return URL(string: "https://openrouter.ai/api/v1")!
        case .bazaarlink: return URL(string: "https://bazaarlink.ai/api/v1")!
        }
    }

    var keychainKind: KeychainService.APIKeyKind {
        switch self {
        case .openRouter: return .openRouter
        case .bazaarlink: return .bazaarlink
        }
    }

    /// The other built-in provider, tried as a fallback.
    var fallback: AIProvider {
        self == .openRouter ? .bazaarlink : .openRouter
    }
}

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
    /// Hourly best-effort check for news urgent enough to interrupt the
    /// day, separate from and much cheaper than the daily brief. Off
    /// disables the background check entirely — no API calls, no alerts.
    var breakingAlertsEnabled: Bool = true
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

    // AI Provider — both OpenRouter and Bazaarlink can hold a saved key
    // at once. Generation tries preferredProvider first and automatically
    // retries with the other one if it has a saved key and the first
    // attempt fails. Structured JSON-schema output and the web-search
    // plugin are OpenRouter-style request extensions that Bazaarlink also
    // appears to support; disable either toggle in Settings if a request
    // is being rejected because of them.
    var preferredProvider: AIProvider = .openRouter
    var useStructuredOutput: Bool = true
    var useWebSearchPlugin: Bool = true
    // "auto:free" rather than a pinned model: confirmed in testing that
    // openai/gpt-oss-120b:free alone gets upstream-rate-limited under
    // real-world demand ("temporarily rate-limited upstream" from
    // OpenRouter's OpenInference-hosted pool) — a specific popular free
    // model being oversubscribed, not an account or request problem.
    // auto:free lets OpenRouter route to whichever free model currently
    // has capacity instead of pinning to one that may be saturated.
    var researchModel: String = "auto:free"
    var editorModel: String = "auto:free"
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

    /// `preferredProvider` first, then the other built-in provider —
    /// only including ones that actually have a saved key.
    var providerAttemptOrder: [AIProvider] {
        [preferredProvider, preferredProvider.fallback].filter {
            KeychainService.loadAPIKey($0.keychainKind) != nil
        }
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
            let migrated = Self.migratingKnownStaleModelDefaults(decoded)
            preferences = migrated
            // didSet doesn't fire for a property's own initial-value
            // assignment in init(), so a migration wouldn't otherwise
            // reach disk until some unrelated setting change happened to
            // trigger a save — write it back explicitly right away.
            if migrated != decoded {
                save()
            }
        } else {
            preferences = .default
        }
    }

    /// One-time migration for a specific default that turned out to be a
    /// bad choice after already shipping: openai/gpt-oss-120b:free gets
    /// upstream-rate-limited under real demand (confirmed in testing),
    /// but changing UserPreferences.default only affects fresh installs
    /// — a phone that already saved that value keeps using it forever
    /// otherwise, since nothing here ever rewrites an already-saved
    /// preference. This only touches an exact match of that specific
    /// stale value, never a value the user deliberately chose themselves,
    /// so it can't clobber an intentional customization.
    private static func migratingKnownStaleModelDefaults(_ preferences: UserPreferences) -> UserPreferences {
        var preferences = preferences
        let staleDefault = "openai/gpt-oss-120b:free"
        if preferences.researchModel == staleDefault {
            preferences.researchModel = "auto:free"
        }
        if preferences.editorModel == staleDefault {
            preferences.editorModel = "auto:free"
        }
        return preferences
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

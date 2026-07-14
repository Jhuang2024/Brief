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
    var morningMinutesAfterMidnight: Int = 6 * 60 // 6:00 AM
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
    /// Personal sections read from the shared App Group feeds the companion
    /// apps write (see LINKED_APPS.md). Purely on-device, no API calls.
    var includeLockedInFit: Bool = true
    var includeSocialClimber: Bool = true
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
    // openai/gpt-4o-mini rather than a free model: every free/open-weight
    // option tried here (auto:free landing on DeepSeek, a pinned
    // gpt-oss-120b:free getting upstream-rate-limited, and finally
    // openai:free's gpt-oss-120b/20b pair repeatedly returning structured
    // output that failed to decode even after a repair attempt, confirmed
    // on-device across several rebuilds) turned out too unreliable for a
    // brief that only gets one shot a day. gpt-4o-mini costs a small
    // fraction of a cent per generation and has solid, consistent JSON
    // schema support — reliability was worth trading the "free" part away
    // for. "openai:free" is still available as a manual choice in
    // Settings → Models if cost ever matters more than reliability again.
    var researchModel: String = "openai/gpt-4o-mini"
    var editorModel: String = "openai/gpt-4o-mini"
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

    /// Flags a one-time move of the morning brief time to 6:00 AM. Gated by
    /// its own key rather than "rewrite whenever the value is the old 7:30
    /// default", so that if the user later picks a different time in
    /// Settings it sticks instead of being reset on the next launch.
    private static let morningTimeMigrationKey = "brief.migratedMorningTimeTo6AM.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = Self.decodeFillingMissingKeysWithDefaults(data) {
            var migrated = Self.migratingKnownStaleModelDefaults(decoded)
            if !UserDefaults.standard.bool(forKey: Self.morningTimeMigrationKey) {
                migrated.morningMinutesAfterMidnight = 6 * 60
                UserDefaults.standard.set(true, forKey: Self.morningTimeMigrationKey)
            }
            preferences = migrated
            // didSet doesn't fire for a property's own initial-value
            // assignment in init(), so a migration wouldn't otherwise
            // reach disk until some unrelated setting change happened to
            // trigger a save — write it back explicitly right away.
            if migrated != decoded {
                save()
            }
        } else {
            // Fresh install: `.default` already carries 6:00 AM, so mark the
            // one-time migration done to avoid re-applying it later.
            UserDefaults.standard.set(true, forKey: Self.morningTimeMigrationKey)
            preferences = .default
        }
    }

    /// One-time migration for defaults that turned out to be a bad choice
    /// after already shipping — changing UserPreferences.default only
    /// affects fresh installs, so a phone that already saved an old
    /// default keeps using it forever otherwise, since nothing here ever
    /// rewrites an already-saved preference on its own. This only touches
    /// an exact match of a specific historical stale value, never a value
    /// the user deliberately chose themselves, so it can't clobber an
    /// intentional customization.
    ///
    /// Every one of these was the app's own shipped default at some
    /// point, not a manual choice, and each turned out unreliable in a
    /// different way, confirmed on-device:
    /// - `openai/gpt-oss-120b:free`: gets upstream-rate-limited under real
    ///   demand when pinned alone.
    /// - `auto:free`: OpenRouter's own "route to any free model" auto
    ///   selection landed on deepseek/deepseek-v4-flash — not what "free"
    ///   was meant to mean here.
    /// - `openai:free` (gpt-oss-120b/20b fallback pair): repeatedly
    ///   returned structured output that failed to decode even after the
    ///   one repair attempt, across several rebuilds.
    ///
    /// All three migrate straight to `openai/gpt-4o-mini` — a paid model,
    /// but one with consistent JSON schema support and a per-generation
    /// cost small enough not to matter for a once-a-day brief.
    private static func migratingKnownStaleModelDefaults(_ preferences: UserPreferences) -> UserPreferences {
        var preferences = preferences
        let staleDefaults: Set<String> = ["openai/gpt-oss-120b:free", "auto:free", "openai:free"]
        if staleDefaults.contains(preferences.researchModel) {
            preferences.researchModel = "openai/gpt-4o-mini"
        }
        if staleDefaults.contains(preferences.editorModel) {
            preferences.editorModel = "openai/gpt-4o-mini"
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

    /// The saved preferences blob exactly as persisted, for BackupService
    /// archives. Like the live copy, it never contains API keys (those are
    /// Keychain-only). nonisolated because backups build off the main actor
    /// and UserDefaults is thread-safe.
    nonisolated static func encodedPreferences() -> Data? {
        UserDefaults.standard.data(forKey: key)
    }

    /// Applies preferences from a backup archive, with the same
    /// missing-keys merge and stale-model migration a normal launch decode
    /// gets. Only meaningful as an explicit, user-confirmed recovery;
    /// BackupService calls this solely when the current preferences are
    /// still factory-default, so a restore can never clobber settings the
    /// user has since customized.
    @discardableResult
    func replacePreferences(withBackupData data: Data) -> Bool {
        guard let decoded = Self.decodeFillingMissingKeysWithDefaults(data) else { return false }
        preferences = Self.migratingKnownStaleModelDefaults(decoded)
        return true
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

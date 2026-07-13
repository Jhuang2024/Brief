import CoreLocation
import Foundation
import UserNotifications

@MainActor
@Observable
final class SettingsViewModel {
    let environment: AppEnvironment

    // Per-provider key entry/test state. Flat, doubled-up properties
    // rather than a dictionary/array so each provider's row in Settings
    // binds directly without keyed-lookup binding gymnastics — the
    // methods below are generic over AIProvider so the duplication stays
    // out of the actual logic.
    var openRouterKeyInput = ""
    var hasOpenRouterKey = KeychainService.loadAPIKey(.openRouter) != nil
    var openRouterTestResult: String?
    var isTestingOpenRouter = false

    var bazaarlinkKeyInput = ""
    var hasBazaarlinkKey = KeychainService.loadAPIKey(.bazaarlink) != nil
    var bazaarlinkTestResult: String?
    var isTestingBazaarlink = false

    // Google Calendar
    var availableCalendars: [GoogleCalendarInfo] = []
    var isLoadingCalendars = false
    var googleError: String?

    // Calendar self-test (Google Calendar API only — never touches the paid
    // AI provider, so running it can't burn generation credits).
    var calendarTestResult: String?
    var isTestingCalendar = false

    init(environment: AppEnvironment = .shared) {
        self.environment = environment
    }

    var preferencesStore: PreferencesStore { environment.preferencesStore }
    var googleAuth: GoogleAuthenticationService { environment.googleAuth }

    // MARK: - AI Provider keys

    func hasStoredKey(for provider: AIProvider) -> Bool {
        provider == .openRouter ? hasOpenRouterKey : hasBazaarlinkKey
    }

    func testResult(for provider: AIProvider) -> String? {
        provider == .openRouter ? openRouterTestResult : bazaarlinkTestResult
    }

    func isTesting(for provider: AIProvider) -> Bool {
        provider == .openRouter ? isTestingOpenRouter : isTestingBazaarlink
    }

    func saveKey(for provider: AIProvider) {
        let trimmed = inputText(for: provider).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try KeychainService.saveAPIKey(trimmed, kind: provider.keychainKind)
            setHasStoredKey(true, for: provider)
            setInputText("", for: provider)
            setTestResult("Key saved to the Keychain.", for: provider)
            Haptics.tick()
        } catch {
            setTestResult(error.localizedDescription, for: provider)
        }
    }

    func removeKey(for provider: AIProvider) {
        try? KeychainService.deleteAPIKey(provider.keychainKind)
        setHasStoredKey(false, for: provider)
        setTestResult(nil, for: provider)
    }

    func testConnection(for provider: AIProvider) {
        guard let key = KeychainService.loadAPIKey(provider.keychainKind) else {
            setTestResult("No API key saved yet.", for: provider)
            return
        }
        setIsTesting(true, for: provider)
        setTestResult(nil, for: provider)
        let model = preferencesStore.preferences.editorModel
        let baseURL = provider.baseURL
        Task {
            do {
                let result = try await OpenRouterService()
                    .testConnection(baseURL: baseURL, apiKey: key, model: model)
                setTestResult(result, for: provider)
            } catch {
                setTestResult(error.localizedDescription, for: provider)
            }
            setIsTesting(false, for: provider)
        }
    }

    private func inputText(for provider: AIProvider) -> String {
        provider == .openRouter ? openRouterKeyInput : bazaarlinkKeyInput
    }

    private func setInputText(_ value: String, for provider: AIProvider) {
        switch provider {
        case .openRouter: openRouterKeyInput = value
        case .bazaarlink: bazaarlinkKeyInput = value
        }
    }

    private func setHasStoredKey(_ value: Bool, for provider: AIProvider) {
        switch provider {
        case .openRouter: hasOpenRouterKey = value
        case .bazaarlink: hasBazaarlinkKey = value
        }
    }

    private func setTestResult(_ value: String?, for provider: AIProvider) {
        switch provider {
        case .openRouter: openRouterTestResult = value
        case .bazaarlink: bazaarlinkTestResult = value
        }
    }

    private func setIsTesting(_ value: Bool, for provider: AIProvider) {
        switch provider {
        case .openRouter: isTestingOpenRouter = value
        case .bazaarlink: isTestingBazaarlink = value
        }
    }

    // MARK: - Google Calendar

    /// Deliberately does not regenerate today's brief on connect, even if
    /// the cached brief predates this connection and still shows Calendar
    /// as unavailable — the brief only ever regenerates at the configured
    /// morning time or via a manual refresh, never automatically as a
    /// side effect of another setting change, so connecting never burns
    /// API credits on its own. A manual refresh picks up the new
    /// connection immediately.
    func connectGoogle() async {
        googleError = nil
        do {
            try await googleAuth.connect()
            await loadCalendarList()
        } catch {
            googleError = error.localizedDescription
        }
    }

    func disconnectGoogle() {
        googleAuth.disconnect()
        availableCalendars = []
    }

    func loadCalendarList() async {
        guard googleAuth.isConnected else { return }
        isLoadingCalendars = true
        defer { isLoadingCalendars = false }
        do {
            availableCalendars = try await GoogleCalendarService(auth: googleAuth).fetchCalendarList()
            googleError = nil
        } catch {
            googleError = error.localizedDescription
        }
    }

    /// Reproduces exactly what generation does when it reads the calendar —
    /// restores the session, then fetches today's events for the selected
    /// calendars — and reports the precise outcome. This calls only the free
    /// Google Calendar API, never the paid AI provider, so it diagnoses a
    /// "Calendar unavailable" brief without regenerating one or spending any
    /// generation credits.
    func testCalendar() {
        guard !isTestingCalendar else { return }
        isTestingCalendar = true
        calendarTestResult = nil
        Task {
            defer { isTestingCalendar = false }
            // Match generation's precondition: ensure the previous Google
            // session has actually been restored into this process first.
            await environment.ensureLaunched()

            var lines: [String] = [googleAuth.sessionDiagnostic]
            let ids = preferencesStore.preferences.selectedCalendarIDs
            lines.append(
                "Selected calendars: "
                    + (ids.isEmpty ? "primary (default)" : ids.joined(separator: ", "))
            )

            guard preferencesStore.preferences.includeCalendar else {
                lines.append(
                    "⚠️ “Include Calendar” is off in Briefing settings, so every brief "
                        + "skips the calendar regardless of the connection."
                )
                calendarTestResult = lines.joined(separator: "\n")
                return
            }

            do {
                let calendar = Calendar.current
                let now = Date()
                let dayStart = calendar.startOfDay(for: now)
                let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? now
                let events = try await GoogleCalendarService(auth: googleAuth)
                    .fetchEvents(calendarIDs: ids, from: dayStart, to: dayEnd)
                lines.append("✅ Fetched \(events.count) event(s) for today. Calendar is working right now.")
                if let last = lastCalendarDiagnostic {
                    lines.append(last)
                    lines.append(
                        "Since it works now, that earlier brief most likely generated before "
                            + "the Google session had finished restoring."
                    )
                }
            } catch {
                lines.append("❌ Fetch failed: \(error.localizedDescription)")
            }
            calendarTestResult = lines.joined(separator: "\n")
        }
    }

    /// The calendar-related failure recorded for the most recent generation,
    /// pulled from the persisted diagnostics — no regeneration required. Nil
    /// when the last brief's calendar succeeded (or nothing has run yet).
    var lastCalendarDiagnostic: String? {
        guard let json = environment.engine.lastDiagnosticsJSON,
              let data = json.data(using: .utf8)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let diagnostics = try? decoder.decode(GenerationDiagnostics.self, from: data)
        else { return nil }
        let calendarErrors = diagnostics.errors.filter {
            $0.localizedCaseInsensitiveContains("calendar")
        }
        guard !calendarErrors.isEmpty else { return nil }
        let when = diagnostics.finishedAt ?? diagnostics.startedAt
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return "Last brief (\(diagnostics.trigger), \(formatter.string(from: when))): "
            + calendarErrors.joined(separator: " ")
    }

    func isCalendarSelected(_ calendar: GoogleCalendarInfo) -> Bool {
        let ids = preferencesStore.preferences.selectedCalendarIDs
        if ids.contains(calendar.id) { return true }
        // "primary" is stored as an alias until the real list is loaded.
        return calendar.isPrimary && ids.contains("primary")
    }

    func toggleCalendar(_ calendar: GoogleCalendarInfo, selected: Bool) {
        var ids = preferencesStore.preferences.selectedCalendarIDs
        ids.removeAll { $0 == calendar.id || (calendar.isPrimary && $0 == "primary") }
        if selected {
            ids.append(calendar.id)
        }
        if ids.isEmpty {
            ids = ["primary"]
        }
        preferencesStore.preferences.selectedCalendarIDs = ids
    }

    // MARK: - Permissions shown in Connections

    var locationStatusDescription: String {
        switch environment.locationService.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return "Allowed"
        case .denied, .restricted: return "Denied: using fallback city"
        case .notDetermined: return "Not requested yet"
        @unknown default: return "Unknown"
        }
    }

    var notificationStatusDescription: String {
        switch environment.notificationService.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return "Allowed"
        case .denied: return "Denied"
        case .notDetermined: return "Not requested yet"
        @unknown default: return "Unknown"
        }
    }

    // MARK: - Data

    func deleteTodaysBrief() {
        environment.briefStore.deleteTodaysBrief()
    }

    func deleteAllHistory() async {
        await environment.briefStore.deleteAllHistory()
    }

    func resetPreferences() {
        preferencesStore.reset()
    }

    /// Diagnostics for the most recent generation. Never includes an AI
    /// provider key or Google tokens (they are never written there).
    var diagnosticsJSON: String {
        environment.engine.lastDiagnosticsJSON ?? "{\n  \"note\": \"No generation has run yet.\"\n}"
    }
}

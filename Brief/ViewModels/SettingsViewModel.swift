import CoreLocation
import Foundation
import UserNotifications

@MainActor
@Observable
final class SettingsViewModel {
    let environment: AppEnvironment

    // OpenRouter key handling. The field is write-only style: the stored
    // key is never echoed back in full.
    var apiKeyInput = ""
    var hasStoredKey = KeychainService.loadAPIKey() != nil
    var connectionTestResult: String?
    var isTestingConnection = false

    // Google Calendar
    var availableCalendars: [GoogleCalendarInfo] = []
    var isLoadingCalendars = false
    var googleError: String?

    init(environment: AppEnvironment = .shared) {
        self.environment = environment
    }

    var preferencesStore: PreferencesStore { environment.preferencesStore }
    var googleAuth: GoogleAuthenticationService { environment.googleAuth }

    // MARK: - OpenRouter

    func saveAPIKey() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try KeychainService.saveAPIKey(trimmed)
            hasStoredKey = true
            apiKeyInput = ""
            connectionTestResult = "Key saved to the Keychain."
            Haptics.tick()
        } catch {
            connectionTestResult = error.localizedDescription
        }
    }

    func removeAPIKey() {
        try? KeychainService.deleteAPIKey()
        hasStoredKey = false
        connectionTestResult = nil
    }

    func testConnection() {
        guard let key = KeychainService.loadAPIKey() else {
            connectionTestResult = "No API key saved yet."
            return
        }
        isTestingConnection = true
        connectionTestResult = nil
        Task {
            do {
                connectionTestResult = try await OpenRouterService().testConnection(apiKey: key)
            } catch {
                connectionTestResult = error.localizedDescription
            }
            isTestingConnection = false
        }
    }

    // MARK: - Google Calendar

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
        case .denied, .restricted: return "Denied — using fallback city"
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

    func deleteAllHistory() {
        environment.briefStore.deleteAllHistory()
    }

    func resetPreferences() {
        preferencesStore.reset()
    }

    /// Diagnostics for the most recent generation. Never includes the
    /// OpenRouter key or Google tokens (they are never written there).
    var diagnosticsJSON: String {
        environment.engine.lastDiagnosticsJSON ?? "{\n  \"note\": \"No generation has run yet.\"\n}"
    }
}

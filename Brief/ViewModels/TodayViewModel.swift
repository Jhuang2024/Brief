import Foundation
import SwiftUI

/// Freshness label shown in the masthead.
enum BriefFreshness: String {
    case current = "Current"
    case updating = "Updating"
    case cached = "Cached"
    case partial = "Partially updated"

    var symbolName: String {
        switch self {
        case .current: return "checkmark.circle"
        case .updating: return "arrow.triangle.2.circlepath"
        case .cached: return "clock"
        case .partial: return "exclamationmark.triangle"
        }
    }
}

@MainActor
@Observable
final class TodayViewModel {
    private let environment: AppEnvironment
    private var lastSeenGeneration = -1

    var brief: DailyBrief?
    var showRefreshConfirmation = false
    var presentedStory: BriefStory?
    var alerts: [BreakingAlert] = []

    init(environment: AppEnvironment = .shared) {
        self.environment = environment
    }

    var engine: BriefingEngine { environment.engine }
    var preferences: UserPreferences { environment.preferencesStore.preferences }
    var speech: SpeechService { environment.speech }

    var hasAPIKey: Bool { KeychainService.hasAnyAPIKey() }

    var freshness: BriefFreshness {
        if engine.isGenerating { return .updating }
        guard let brief else { return .cached }
        if brief.status == .partial { return .partial }
        return brief.isCurrent() ? .current : .cached
    }

    /// Load cache instantly, then generate if missing or stale.
    /// Waits for launch setup (notably Google session restore) first, so
    /// generation doesn't race ahead and see Calendar as disconnected
    /// just because the previous Google session hadn't finished loading
    /// yet — `ensureLaunched()` is memoized, so this is a no-op if launch
    /// setup already finished.
    func onAppear() async {
        reloadFromStore()
        reloadAlerts()
        await environment.ensureLaunched()
        await engine.generateIfNeeded(trigger: .launch)
        reloadFromStore()
        // Fire-and-forget: a foreground fallback for the hourly check, in
        // case the best-effort background task hasn't run recently.
        // `checkIfDue` already no-ops if it's been under an hour, so this
        // never costs anything extra beyond the one hourly call.
        Task {
            await environment.breakingCheck.checkIfDue()
            reloadAlerts()
        }
    }

    func reloadAlerts() {
        alerts = environment.alertStore.unreadAlerts()
    }

    func dismissAlert(_ alert: BreakingAlert) {
        environment.alertStore.markRead(alert)
        alerts.removeAll { $0.id == alert.id }
    }

    func reloadIfGenerationAdvanced() {
        guard engine.generationCounter != lastSeenGeneration else { return }
        reloadFromStore()
    }

    func reloadFromStore() {
        lastSeenGeneration = engine.generationCounter
        brief = environment.briefStore.todaysBrief()
    }

    /// Debounced refresh: a second paid generation within five minutes
    /// requires confirmation.
    func refreshRequested() {
        guard !engine.isGenerating else { return }
        if let completed = engine.lastCompletedAt, Date().timeIntervalSince(completed) < 5 * 60 {
            showRefreshConfirmation = true
            return
        }
        startRefresh()
    }

    func startRefresh() {
        guard !engine.isGenerating else { return }
        Haptics.tap()
        Task {
            await engine.generate(trigger: .manual)
            reloadFromStore()
        }
    }

    func openSettings() {
        environment.selectedTab = .settings
    }

    func toggleAudio() {
        guard let brief else { return }
        switch speech.state {
        case .idle:
            speech.play(brief: brief, includeWhyItMatters: preferences.includeWhyItMatters)
        case .playing:
            speech.pause()
        case .paused:
            speech.resume()
        }
    }
}

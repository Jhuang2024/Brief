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

    init(environment: AppEnvironment = .shared) {
        self.environment = environment
    }

    var engine: BriefingEngine { environment.engine }
    var preferences: UserPreferences { environment.preferencesStore.preferences }
    var speech: SpeechService { environment.speech }

    var hasAPIKey: Bool { KeychainService.loadAPIKey() != nil }

    var freshness: BriefFreshness {
        if engine.isGenerating { return .updating }
        guard let brief else { return .cached }
        if brief.status == .partial { return .partial }
        return brief.isCurrent() ? .current : .cached
    }

    /// Load cache instantly, then generate if missing or stale.
    func onAppear() async {
        reloadFromStore()
        await engine.generateIfNeeded(trigger: .launch)
        reloadFromStore()
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

import Foundation

@MainActor
@Observable
final class HistoryViewModel {
    private let environment: AppEnvironment
    private var lastSeenGeneration = -1

    var briefs: [DailyBrief] = []
    var confirmDeleteAll = false

    init(environment: AppEnvironment = .shared) {
        self.environment = environment
    }

    func reload() {
        lastSeenGeneration = environment.engine.generationCounter
        briefs = environment.briefStore.allBriefs()
    }

    func reloadIfGenerationAdvanced() {
        guard environment.engine.generationCounter != lastSeenGeneration else { return }
        reload()
    }

    func delete(_ brief: DailyBrief) {
        environment.briefStore.delete(brief)
        reload()
    }

    func deleteAll() {
        environment.briefStore.deleteAllHistory()
        reload()
    }
}

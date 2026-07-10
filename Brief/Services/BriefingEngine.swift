import Foundation
import SwiftData
import UIKit

/// Orchestrates the five-stage pipeline: local context → concurrent web
/// research → editorial synthesis → validation → persistence.
/// One generation runs at a time; concurrent callers share the in-flight task.
@MainActor
@Observable
final class BriefingEngine {
    enum Trigger: String {
        case launch, manual, background, notification
    }

    struct PhaseProgress: Identifiable, Equatable {
        enum Status { case pending, active, done, failed }
        let id: String
        let title: String
        var status: Status = .pending
    }

    enum EngineError: LocalizedError {
        case noUsableContent
        var errorDescription: String? {
            "The research and editing steps produced no usable stories. The previous briefing was kept."
        }
    }

    private let store: BriefStore
    private let preferencesStore: PreferencesStore
    private let googleAuth: GoogleAuthenticationService
    private let locationService: LocationService
    private let openRouter = OpenRouterService()
    private let weatherService = WeatherService()

    private(set) var phases: [PhaseProgress] = []
    private(set) var isGenerating = false
    private(set) var lastError: String?
    private(set) var lastCompletedAt: Date?
    /// Bumped whenever a brief is saved, so views refetch from the store.
    private(set) var generationCounter = 0

    private var generationTask: Task<DailyBrief?, Never>?

    /// Keeps a generation running for a little while after the user
    /// backgrounds the app (e.g. swiping up without force-quitting) —
    /// without this, iOS suspends the process almost immediately and an
    /// in-flight research/editor request just silently stops partway
    /// through. iOS grants a limited window (historically on the order of
    /// 30 seconds, not unlimited), not indefinite background execution;
    /// the expiration handler cancels cooperatively so a run that outlives
    /// the window fails cleanly instead of hanging, and picks back up
    /// automatically next time the app is foregrounded since today's
    /// brief is still missing or stale.
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    private static let diagnosticsKey = "brief.lastGenerationDiagnostics"

    init(
        store: BriefStore,
        preferencesStore: PreferencesStore,
        googleAuth: GoogleAuthenticationService,
        locationService: LocationService
    ) {
        self.store = store
        self.preferencesStore = preferencesStore
        self.googleAuth = googleAuth
        self.locationService = locationService
    }

    // MARK: - Entry points

    /// Generate when today's brief is missing or stale. Shows cached content
    /// meanwhile; never blocks the UI.
    func generateIfNeeded(trigger: Trigger) async {
        if let existing = store.todaysBrief() {
            let stale = !existing.isCurrent()
            let shouldRefresh = stale && preferencesStore.preferences.automaticRefreshEnabled
            guard shouldRefresh || trigger == .manual else { return }
        }
        await generate(trigger: trigger)
    }

    /// Run a generation, reusing any in-progress one.
    @discardableResult
    func generate(trigger: Trigger) async -> DailyBrief? {
        if let task = generationTask {
            return await task.value
        }
        beginBackgroundTask()
        let task = Task<DailyBrief?, Never> { [weak self] in
            await self?.run(trigger: trigger)
        }
        generationTask = task
        let result = await task.value
        endBackgroundTask()
        return result
    }

    func cancelGeneration() {
        generationTask?.cancel()
    }

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Brief.generation") { [weak self] in
            self?.generationTask?.cancel()
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    var lastDiagnosticsJSON: String? {
        UserDefaults.standard.string(forKey: Self.diagnosticsKey)
    }

    // MARK: - Pipeline

    private func run(trigger: Trigger) async -> DailyBrief? {
        defer {
            generationTask = nil
            isGenerating = false
        }

        let preferences = preferencesStore.preferences
        let providerOrder = preferences.providerAttemptOrder
        guard !providerOrder.isEmpty else {
            lastError = OpenRouterService.OpenRouterError.missingAPIKey.errorDescription
            return nil
        }

        isGenerating = true
        lastError = nil
        setUpPhases(preferences: preferences)

        var diagnostics = GenerationDiagnostics(
            startedAt: Date(),
            finishedAt: nil,
            trigger: trigger.rawValue,
            researchModel: preferences.researchModel,
            editorModel: preferences.editorModel
        )
        let overallStart = Date()

        // Stage 1 — local context.
        markPhase("checking_today", .done)

        async let calendarFetch = fetchCalendarContext(preferences: preferences)
        async let weatherFetch = fetchWeatherContext(preferences: preferences)
        let calendarContext = await calendarFetch
        let weatherContext = await weatherFetch

        if let note = calendarContext.failureNote { diagnostics.errors.append(note) }
        if let note = weatherContext.failureNote { diagnostics.errors.append(note) }

        let context = BriefContext(
            now: Date(),
            timezone: .current,
            location: weatherContext.location,
            weather: weatherContext.weather,
            weatherFailed: weatherContext.failureNote != nil,
            todayEvents: calendarContext.todayEvents,
            weekEvents: calendarContext.weekEvents,
            calendarAvailable: calendarContext.available,
            preferences: preferences,
            recentMemory: store.recentStoryMemory()
        )

        // Stage 2 — concurrent web-grounded research. A partial failure must
        // not cancel the successful requests.
        let groups = enabledResearchGroups(preferences: preferences)
        var packets: [ResearchPacket] = []
        var failedGroups: [ResearchGroup] = []

        for group in groups { markPhase(group.rawValue, .active) }
        let openRouter = self.openRouter
        await withTaskGroup(of: (ResearchGroup, Result<ResearchPacket, Error>).self) { taskGroup in
            for group in groups {
                taskGroup.addTask {
                    do {
                        let packet = try await Self.runResearch(
                            group: group, context: context, openRouter: openRouter, providerOrder: providerOrder
                        )
                        return (group, .success(packet))
                    } catch {
                        return (group, .failure(error))
                    }
                }
            }
            for await (group, result) in taskGroup {
                switch result {
                case .success(let packet):
                    packets.append(packet)
                    markPhase(group.rawValue, .done)
                    diagnostics.steps.append(.init(
                        name: "research.\(group.rawValue)",
                        succeeded: true,
                        detail: "\(packet.candidates.count) candidates via \(packet.modelUsed)",
                        duration: packet.duration
                    ))
                    diagnostics.totalInputTokens += packet.inputTokens
                    diagnostics.totalOutputTokens += packet.outputTokens
                case .failure(let error):
                    failedGroups.append(group)
                    markPhase(group.rawValue, .failed)
                    diagnostics.steps.append(.init(
                        name: "research.\(group.rawValue)",
                        succeeded: false,
                        detail: error.localizedDescription,
                        duration: 0
                    ))
                    diagnostics.errors.append("\(group.displayName): \(error.localizedDescription)")
                }
            }
        }
        packets.sort { $0.group.rawValue < $1.group.rawValue }
        diagnostics.candidateCount = packets.reduce(0) { $0 + $1.candidates.count }

        guard diagnostics.candidateCount > 0 || context.calendarAvailable || context.weather != nil else {
            finishWithFailure(
                EngineError.noUsableContent.localizedDescription,
                diagnostics: &diagnostics
            )
            return nil
        }

        // Stage 3 — editorial synthesis, with one repair attempt on
        // invalid structured output.
        markPhase("editing", .active)
        let editorOutcome: (response: EditorResponse, modelUsed: String)
        do {
            editorOutcome = try await runEditor(
                context: context,
                packets: packets,
                failedGroups: failedGroups,
                preferences: preferences,
                providerOrder: providerOrder,
                diagnostics: &diagnostics
            )
            markPhase("editing", .done)
        } catch {
            markPhase("editing", .failed)
            finishWithFailure(
                "The editing step failed: \(error.localizedDescription)",
                diagnostics: &diagnostics
            )
            return nil
        }

        // Stage 4 — validate; Stage 5 — persist.
        markPhase("finishing", .active)
        let brief = assembleBrief(
            editor: editorOutcome.response,
            editorModel: editorOutcome.modelUsed,
            context: context,
            packets: packets,
            failedGroups: failedGroups,
            diagnostics: &diagnostics,
            duration: Date().timeIntervalSince(overallStart)
        )

        guard brief.totalStoryCount > 0 || !brief.overviewItems.isEmpty else {
            markPhase("finishing", .failed)
            finishWithFailure(
                EngineError.noUsableContent.localizedDescription,
                diagnostics: &diagnostics
            )
            return nil
        }

        store.save(brief)
        markPhase("finishing", .done)

        diagnostics.finishedAt = Date()
        diagnostics.status = brief.status.rawValue
        diagnostics.storyCount = brief.totalStoryCount
        saveDiagnostics(diagnostics)

        lastCompletedAt = Date()
        generationCounter += 1
        Haptics.briefReady()
        return brief
    }

    private func finishWithFailure(_ message: String, diagnostics: inout GenerationDiagnostics) {
        lastError = message
        diagnostics.finishedAt = Date()
        diagnostics.status = "failed"
        diagnostics.errors.append(message)
        saveDiagnostics(diagnostics)
        Haptics.failure()
    }

    // MARK: - Stage 1 helpers

    private struct CalendarContext {
        var available: Bool
        var todayEvents: [CalendarEvent]
        var weekEvents: [CalendarEvent]
        var failureNote: String?
    }

    private struct WeatherContext {
        var location: LocationService.ResolvedLocation
        var weather: WeatherSnapshot?
        var failureNote: String?
    }

    private func fetchCalendarContext(preferences: UserPreferences) async -> CalendarContext {
        guard preferences.includeCalendar else {
            markPhase("reading_calendar", .done)
            return CalendarContext(available: false, todayEvents: [], weekEvents: [], failureNote: nil)
        }
        markPhase("reading_calendar", .active)
        guard googleAuth.isConnected || googleAuth.hasPreviousSession else {
            markPhase("reading_calendar", .done)
            return CalendarContext(
                available: false, todayEvents: [], weekEvents: [],
                failureNote: "Google Calendar is not connected."
            )
        }
        do {
            let calendar = Calendar.current
            let now = Date()
            let dayStart = calendar.startOfDay(for: now)
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? now
            let weekEnd = calendar.date(byAdding: .day, value: 7, to: dayStart) ?? now
            let service = GoogleCalendarService(auth: googleAuth)
            let ids = preferences.selectedCalendarIDs

            let todayEvents = try await service.fetchEvents(calendarIDs: ids, from: dayStart, to: dayEnd)
            let weekEvents = try await service.fetchEvents(calendarIDs: ids, from: dayEnd, to: weekEnd)
            markPhase("reading_calendar", .done)
            return CalendarContext(
                available: true, todayEvents: todayEvents, weekEvents: weekEvents, failureNote: nil
            )
        } catch {
            markPhase("reading_calendar", .failed)
            return CalendarContext(
                available: false, todayEvents: [], weekEvents: [],
                failureNote: "Calendar unavailable: \(error.localizedDescription)"
            )
        }
    }

    private func fetchWeatherContext(preferences: UserPreferences) async -> WeatherContext {
        markPhase("checking_weather", .active)
        let location = await locationService.resolveLocation(preferences: preferences)
        guard preferences.includeWeather else {
            markPhase("checking_weather", .done)
            return WeatherContext(location: location, weather: nil, failureNote: nil)
        }
        do {
            let weather = try await weatherService.fetchWeather(
                latitude: location.latitude,
                longitude: location.longitude,
                locationName: location.name,
                unit: preferences.temperatureUnit
            )
            markPhase("checking_weather", .done)
            return WeatherContext(location: location, weather: weather, failureNote: nil)
        } catch {
            markPhase("checking_weather", .failed)
            return WeatherContext(
                location: location, weather: nil,
                failureNote: "Weather unavailable: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Stage 2

    private func enabledResearchGroups(preferences: UserPreferences) -> [ResearchGroup] {
        var groups = Set<ResearchGroup>()
        for section in preferences.enabledSections {
            if let group = section.category.researchGroup {
                groups.insert(group)
            } else if section.category == .worthKnowing {
                // Worth Knowing draws from the general-news research requests.
                groups.formUnion([.worldPolitics, .businessMarkets, .technology])
            }
        }
        return ResearchGroup.allCases.filter { groups.contains($0) }
    }

    /// Tries each provider in `providerOrder` (already filtered to ones
    /// with a saved key) in turn, returning the first success. If every
    /// attempt fails, throws a combined error naming each provider and
    /// what went wrong with it, so a Settings misconfiguration is
    /// diagnosable rather than just "it didn't work."
    private nonisolated static func completeWithFallback(
        providerOrder: [AIProvider],
        openRouter: OpenRouterService,
        model: String,
        systemPrompt: String,
        userPrompt: String,
        schemaName: String,
        schema: [String: Any],
        useStructuredOutput: Bool,
        webSearch: Bool,
        webResults: Int = 10,
        temperature: Double = 0.3
    ) async throws -> OpenRouterService.CompletionResult {
        var failures: [(AIProvider, Error)] = []
        for provider in providerOrder {
            guard let apiKey = KeychainService.loadAPIKey(provider.keychainKind) else { continue }
            do {
                return try await openRouter.complete(
                    baseURL: provider.baseURL,
                    apiKey: apiKey,
                    model: model,
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    schemaName: schemaName,
                    schema: schema,
                    useStructuredOutput: useStructuredOutput,
                    webSearch: webSearch,
                    webResults: webResults,
                    temperature: temperature
                )
            } catch {
                failures.append((provider, error))
            }
        }
        if failures.count == 1, let only = failures.first {
            throw only.1
        }
        let details = failures
            .map { "\($0.0.displayName): \($0.1.localizedDescription)" }
            .joined(separator: " ")
        throw OpenRouterService.OpenRouterError.allProvidersFailed(details: details)
    }

    private nonisolated static func runResearch(
        group: ResearchGroup,
        context: BriefContext,
        openRouter: OpenRouterService,
        providerOrder: [AIProvider]
    ) async throws -> ResearchPacket {
        let preferences = context.preferences
        let result = try await completeWithFallback(
            providerOrder: providerOrder,
            openRouter: openRouter,
            model: preferences.researchModel,
            systemPrompt: BriefingPrompts.researchSystemPrompt,
            userPrompt: BriefingPrompts.researchUserPrompt(group: group, context: context),
            schemaName: "research_candidates",
            schema: BriefingPrompts.researchSchema,
            useStructuredOutput: preferences.useStructuredOutput,
            webSearch: preferences.useWebSearchPlugin,
            webResults: preferences.researchDepth.webResults,
            temperature: 0.3
        )
        let decoded = try JSONDecoder().decode(
            ResearchResponse.self,
            from: Data(Self.extractJSON(result.content).utf8)
        )
        let citedURLs = result.citations.map(\.url)
        let excludedDomains = Set(preferences.excludedDomains.map { $0.lowercased() })

        // Normalize and validate every candidate URL against the citation
        // annotations OpenRouter actually returned.
        let candidates = decoded.candidates.compactMap { raw -> CandidateStory? in
            var candidate = raw
            guard URLValidation.isPlausible(candidate.sourceURL) else { return nil }
            let domain = URLValidation.domain(of: candidate.sourceURL)
            guard !excludedDomains.contains(domain) else { return nil }
            candidate.sourceDomain = domain
            candidate.id = "\(group.rawValue):\(candidate.id)"
            candidate.citationVerified = URLValidation.matchesCitations(
                candidate.sourceURL, citations: citedURLs
            )
            return candidate
        }

        return ResearchPacket(
            group: group,
            candidates: candidates,
            citedURLs: citedURLs,
            modelUsed: result.modelUsed,
            inputTokens: result.inputTokens,
            outputTokens: result.outputTokens,
            duration: result.duration
        )
    }

    // MARK: - Stage 3

    private func runEditor(
        context: BriefContext,
        packets: [ResearchPacket],
        failedGroups: [ResearchGroup],
        preferences: UserPreferences,
        providerOrder: [AIProvider],
        diagnostics: inout GenerationDiagnostics
    ) async throws -> (response: EditorResponse, modelUsed: String) {
        let result = try await Self.completeWithFallback(
            providerOrder: providerOrder,
            openRouter: openRouter,
            model: preferences.editorModel,
            systemPrompt: BriefingPrompts.editorSystemPrompt,
            userPrompt: BriefingPrompts.editorUserPrompt(
                context: context, packets: packets, failedGroups: failedGroups
            ),
            schemaName: "daily_brief",
            schema: BriefingPrompts.editorSchema,
            useStructuredOutput: preferences.useStructuredOutput,
            webSearch: false,
            temperature: 0.2
        )
        diagnostics.totalInputTokens += result.inputTokens
        diagnostics.totalOutputTokens += result.outputTokens
        diagnostics.steps.append(.init(
            name: "editor", succeeded: true,
            detail: "via \(result.modelUsed)", duration: result.duration
        ))

        do {
            let response = try Self.decodeEditor(result.content)
            return (response, result.modelUsed)
        } catch {
            // One repair attempt: send the broken output and the error back.
            diagnostics.errors.append("Editor output failed to decode: \(error.localizedDescription). Attempting repair.")
            let repair = try await Self.completeWithFallback(
                providerOrder: providerOrder,
                openRouter: openRouter,
                model: preferences.editorModel,
                systemPrompt: BriefingPrompts.editorSystemPrompt,
                userPrompt: BriefingPrompts.repairPrompt(
                    originalContent: result.content,
                    decodeError: error.localizedDescription
                ),
                schemaName: "daily_brief",
                schema: BriefingPrompts.editorSchema,
                useStructuredOutput: preferences.useStructuredOutput,
                webSearch: false,
                temperature: 0.0
            )
            diagnostics.totalInputTokens += repair.inputTokens
            diagnostics.totalOutputTokens += repair.outputTokens
            let response = try Self.decodeEditor(repair.content)
            diagnostics.steps.append(.init(
                name: "editor.repair", succeeded: true,
                detail: "via \(repair.modelUsed)", duration: repair.duration
            ))
            return (response, repair.modelUsed)
        }
    }

    private nonisolated static func decodeEditor(_ content: String) throws -> EditorResponse {
        let json = extractJSON(content)
        do {
            return try JSONDecoder().decode(EditorResponse.self, from: Data(json.utf8))
        } catch {
            // Retry decoding once against the raw content before giving up.
            return try JSONDecoder().decode(EditorResponse.self, from: Data(content.utf8))
        }
    }

    /// Strip markdown fences and any prose around the outermost JSON object.
    private nonisolated static func extractJSON(_ content: String) -> String {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first < last {
            return String(text[first...last])
        }
        return text
    }

    // MARK: - Stage 4 + 5

    private func assembleBrief(
        editor: EditorResponse,
        editorModel: String,
        context: BriefContext,
        packets: [ResearchPacket],
        failedGroups: [ResearchGroup],
        diagnostics: inout GenerationDiagnostics,
        duration: TimeInterval
    ) -> DailyBrief {
        let preferences = context.preferences
        let now = context.now
        let calendar = Calendar.current

        var candidatesByID: [String: CandidateStory] = [:]
        for packet in packets {
            for candidate in packet.candidates {
                candidatesByID[candidate.id] = candidate
            }
        }

        var seenURLs = Set<String>()
        var seenHeadlines = Set<String>()
        var notes: [String] = []
        var sections: [BriefSection] = []

        for (sectionIndex, configuration) in preferences.enabledSections.enumerated() {
            guard let editorSection = editor.sections.first(
                where: { $0.category == configuration.category.rawValue }
            ) else { continue }

            var stories: [BriefStory] = []
            let limit = preferences.effectiveMaxStories(for: configuration.category)

            for editorStory in editorSection.stories {
                guard stories.count < limit else {
                    notes.append("Section \(configuration.title) exceeded its limit; extra stories dropped.")
                    break
                }
                let headline = editorStory.headline.trimmingCharacters(in: .whitespacesAndNewlines)
                let summary = editorStory.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !headline.isEmpty, !summary.isEmpty else {
                    notes.append("Dropped a story with an empty headline or summary.")
                    continue
                }

                // Deduplicate by normalized headline across the whole brief.
                let normalizedHeadline = Fingerprint.normalizeHeadline(headline)
                guard seenHeadlines.insert(normalizedHeadline).inserted else {
                    notes.append("Dropped duplicate headline: \(headline)")
                    continue
                }

                // Sources must come from validated research candidates.
                var sources: [BriefSource] = []
                var primaryURL: String?
                let referenced = editorStory.candidateIDs.compactMap { candidatesByID[$0] }
                let verified = referenced.filter { $0.citationVerified != false }
                let usable = verified.isEmpty ? referenced : verified
                for candidate in usable {
                    let canonical = URLValidation.canonicalize(candidate.sourceURL)
                    guard seenURLs.insert(canonical).inserted else { continue }
                    if primaryURL == nil { primaryURL = candidate.sourceURL }
                    sources.append(BriefSource(
                        title: candidate.sourceTitle.isEmpty ? candidate.sourceDomain : candidate.sourceTitle,
                        domain: candidate.sourceDomain,
                        urlString: candidate.sourceURL,
                        publishedAt: candidate.developmentDate,
                        sourceType: SourceType.classify(domain: candidate.sourceDomain)
                    ))
                }
                guard !sources.isEmpty else {
                    notes.append("Dropped story without a verifiable source: \(headline)")
                    continue
                }

                // Reject impossible dates: outside 14 days past to 7 days ahead.
                var developmentDate = DateFormatting.parseISO8601(editorStory.developmentTime)
                if let date = developmentDate {
                    let earliest = calendar.date(byAdding: .day, value: -14, to: now) ?? now
                    let latest = calendar.date(byAdding: .day, value: 7, to: now) ?? now
                    if date < earliest || date > latest {
                        developmentDate = nil
                        notes.append("Cleared an implausible date on: \(headline)")
                    }
                }

                let fingerprint = Fingerprint.make(
                    headline: headline,
                    sourceURL: primaryURL,
                    entities: Fingerprint.entities(from: headline + " " + summary),
                    category: configuration.category.rawValue
                )
                stories.append(BriefStory(
                    fingerprint: fingerprint,
                    headline: headline,
                    summary: summary,
                    whyItMatters: editorStory.whyItMatters.trimmingCharacters(in: .whitespacesAndNewlines),
                    context: editorStory.context.trimmingCharacters(in: .whitespacesAndNewlines),
                    developmentDate: developmentDate,
                    status: StoryStatus(rawValue: editorStory.status) ?? .none,
                    importanceScore: min(max(editorStory.importance, 0), 1),
                    relevanceScore: min(max(editorStory.relevance, 0), 1),
                    isUpdate: editorStory.isUpdate,
                    whatChanged: editorStory.whatChanged.trimmingCharacters(in: .whitespacesAndNewlines),
                    order: stories.count,
                    sources: sources
                ))
            }

            // Never render an empty section.
            if !stories.isEmpty {
                sections.append(BriefSection(
                    category: configuration.category,
                    title: configuration.title,
                    order: sectionIndex,
                    stories: stories
                ))
            }
        }

        // Overview: at most 6 non-empty items.
        let overview = editor.overview
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(6)

        // Weather values stay faithful to Open-Meteo; the model contributes
        // only the practical note.
        var weather = context.weather
        let note = editor.practicalWeatherNote.trimmingCharacters(in: .whitespacesAndNewlines)
        if weather != nil, !note.isEmpty {
            weather?.practicalNote = String(note.prefix(120))
        }

        // Reading time: trust the editor within reason, else estimate from words.
        let wordCount = (Array(overview) + sections.flatMap { section in
            section.stories.map { "\($0.headline) \($0.summary) \($0.whyItMatters)" }
        }).joined(separator: " ").split(separator: " ").count
        let estimatedFromWords = max(1, Int((Double(wordCount) / 200.0).rounded(.up)))
        let readingMinutes = (3...30).contains(editor.estimatedReadingMinutes)
            ? editor.estimatedReadingMinutes
            : estimatedFromWords

        var failureNotes: [String] = []
        if !failedGroups.isEmpty {
            failureNotes.append("Some sections could not be updated: \(failedGroups.map(\.displayName).joined(separator: ", ")).")
        }
        if preferences.includeCalendar && !context.calendarAvailable {
            failureNotes.append("Calendar was unavailable.")
        }
        if preferences.includeWeather && context.weatherFailed {
            failureNotes.append("Weather was unavailable.")
        }
        let status: BriefGenerationStatus = failureNotes.isEmpty ? .complete : .partial

        diagnostics.validationNotes = notes

        return DailyBrief(
            briefingDate: calendar.startOfDay(for: now),
            generatedAt: now,
            timezoneIdentifier: context.timezone.identifier,
            locationName: context.location.name,
            overviewItems: Array(overview),
            sections: sections,
            calendarEvents: context.todayEvents,
            calendarWasAvailable: context.calendarAvailable,
            weather: weather,
            estimatedReadingMinutes: readingMinutes,
            status: status,
            failureNotes: failureNotes,
            researchModel: preferences.researchModel,
            editorModel: editorModel,
            inputTokens: diagnostics.totalInputTokens,
            outputTokens: diagnostics.totalOutputTokens,
            generationDuration: duration
        )
    }

    // MARK: - Phases

    private func setUpPhases(preferences: UserPreferences) {
        var list: [PhaseProgress] = [
            PhaseProgress(id: "checking_today", title: "Checking today"),
        ]
        if preferences.includeCalendar {
            list.append(PhaseProgress(id: "reading_calendar", title: "Reading Calendar"))
        }
        list.append(PhaseProgress(id: "checking_weather", title: "Checking weather"))
        for group in enabledResearchGroups(preferences: preferences) {
            list.append(PhaseProgress(id: group.rawValue, title: Self.phaseTitle(for: group)))
        }
        list.append(PhaseProgress(id: "editing", title: "Editing your brief"))
        list.append(PhaseProgress(id: "finishing", title: "Finishing"))
        phases = list
    }

    private static func phaseTitle(for group: ResearchGroup) -> String {
        switch group {
        case .worldPolitics: return "Researching world news"
        case .businessMarkets: return "Researching business & markets"
        case .technology: return "Researching technology"
        case .formulaOne: return "Checking Formula 1"
        case .sports: return "Checking sports"
        case .berkeley: return "Checking Berkeley"
        }
    }

    private func markPhase(_ id: String, _ status: PhaseProgress.Status) {
        guard let index = phases.firstIndex(where: { $0.id == id }) else { return }
        phases[index].status = status
    }

    // MARK: - Diagnostics

    private func saveDiagnostics(_ diagnostics: GenerationDiagnostics) {
        UserDefaults.standard.set(diagnostics.exportJSON(), forKey: Self.diagnosticsKey)
    }
}

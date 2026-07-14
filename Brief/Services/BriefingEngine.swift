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
        case launch, manual, notification
    }

    struct PhaseProgress: Identifiable, Equatable {
        enum Status { case pending, active, done, failed }
        let id: String
        let title: String
        var status: Status = .pending
        /// When this phase became active — lets the progress view show a
        /// live elapsed-time counter instead of a static spinner, so a
        /// long-but-still-working retry is visibly distinguishable from
        /// an actual freeze.
        var startedAt: Date?
    }

    enum EngineError: LocalizedError {
        case noUsableContent
        case timedOut(stage: String)
        case invalidStructuredOutput(stage: String)
        var errorDescription: String? {
            switch self {
            case .noUsableContent:
                return "The research and editing steps produced no usable stories. The previous briefing was kept."
            case .timedOut(let stage):
                return "\(stage) took too long and was stopped. The previous briefing was kept."
            case .invalidStructuredOutput(let stage):
                return "\(stage) returned a response in the wrong format, even after one retry. This is usually a free-tier model hiccup: try refreshing again, or pin a specific model in Settings → Models. The previous briefing was kept."
            }
        }
    }

    /// Races `operation` against a timer so a stuck request (e.g. a
    /// provider silently hanging, or retries stacking up past what's
    /// reasonable for someone actively watching the screen) fails
    /// cleanly instead of leaving the progress view on a single static
    /// phase indefinitely — which reads as a frozen app even though the
    /// UI thread itself is never actually blocked.
    private nonisolated static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        stage: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw EngineError.timedOut(stage: stage)
            }
            guard let result = try await group.next() else {
                throw EngineError.timedOut(stage: stage)
            }
            group.cancelAll()
            return result
        }
    }

    /// Explicit output caps for the research and editor calls. Without a
    /// `max_tokens` field at all, several OpenRouter-hosted free/open-weight
    /// endpoints (confirmed with the openai/gpt-oss-120b and gpt-oss-20b
    /// free tiers) fall back to a modest hosting default rather than
    /// "however much the schema needs" — the editor's response in
    /// particular, a full day's brief across every enabled section, easily
    /// exceeds that default, gets cut off mid-JSON, and fails to decode
    /// with a generic "data couldn't be read" error. That failure then
    /// repeats on the one repair attempt too, since it re-sends the same
    /// large schema. These are generous enough to cover a "thorough"
    /// brief's full JSON without constraining the model's actual writing.
    private static let researchMaxTokens = 4000
    private static let editorMaxTokens = 8000

    /// A free-tier model generating up to `editorMaxTokens` worth of
    /// output can genuinely take a while under load — the previous fixed
    /// 45-second timeout was tuned for a small/default-length response and
    /// started tripping on "Editing took too long" as soon as the cap
    /// above was raised, even though the request was still actively
    /// producing (not stuck). These are generous enough to let a slow but
    /// working free model finish; the live elapsed-time counters in
    /// GenerationProgressView/TodayView's inline strip already make a
    /// long-but-working wait visibly distinct from an actual freeze.
    private static let researchTimeoutSeconds: TimeInterval = 60
    private static let editorTimeoutSeconds: TimeInterval = 120
    private static let editorRepairTimeoutSeconds: TimeInterval = 90

    private let store: BriefStore
    private let preferencesStore: PreferencesStore
    private let googleAuth: GoogleAuthenticationService
    private let locationService: LocationService
    private let openRouter = OpenRouterService()
    private let weatherService = WeatherService()
    private let linkedApps = LinkedAppsService()

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

    /// Automatic generation happens under exactly two conditions: it's at
    /// or after the configured morning time and today's brief doesn't
    /// exist yet (covers the morning notification tap — which only fires
    /// at that time — and opening the app after it with nothing generated
    /// yet), or the caller is a manual refresh (which goes through
    /// `generate(trigger:)` directly,
    /// bypassing this gate entirely). A brief that already exists is
    /// never auto-regenerated just because it's gotten old during the
    /// day — deliberately, so the app doesn't spend API credits on its
    /// own. Only a manual refresh does that from that point on.
    func generateIfNeeded(trigger: Trigger) async {
        guard store.todaysBrief() == nil else { return }
        if trigger != .manual {
            guard preferencesStore.preferences.automaticRefreshEnabled,
                  isAtOrPastMorningTime()
            else { return }
        }
        await generate(trigger: trigger)
    }

    private func isAtOrPastMorningTime(now: Date = Date()) -> Bool {
        let preferences = preferencesStore.preferences
        guard let scheduled = Calendar.current.date(
            bySettingHour: preferences.morningMinutesAfterMidnight / 60,
            minute: preferences.morningMinutesAfterMidnight % 60,
            second: 0,
            of: now
        ) else { return true }
        return now >= scheduled
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

        // Linked-app digests: plain file reads from the shared App Group
        // container, deterministic and instant. Missing or stale feeds
        // become digests that explain themselves in the section, so they
        // never fail generation or mark the brief partial.
        let linkedAppDigests = fetchLinkedAppDigests(preferences: preferences)

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
            for (index, group) in groups.enumerated() {
                taskGroup.addTask {
                    // Stagger the concurrent research calls slightly so
                    // they don't all land on the provider in the same
                    // instant — free-tier models in particular have
                    // strict per-minute burst limits, and a same-instant
                    // burst of up to six calls is exactly what trips them.
                    if index > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(index) * 400_000_000)
                    }
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
            // EngineError's own descriptions are already complete, specific
            // sentences (e.g. "Editing took too long..."); only prefix a
            // generic label for an error type that doesn't describe itself
            // in terms of the editing stage.
            let message = error is EngineError
                ? error.localizedDescription
                : "The editing step failed: \(error.localizedDescription)"
            finishWithFailure(
                message,
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
            linkedAppDigests: linkedAppDigests,
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
                failureNote: "Calendar unavailable: Google is not connected. \(googleAuth.sessionDiagnostic)"
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
                failureNote: "Calendar unavailable: \(error.localizedDescription) \(googleAuth.sessionDiagnostic)"
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

    /// Reads the LockedInFit and Social Climber brief feeds from the shared
    /// App Group container. Synchronous file reads, so the phase is done the
    /// moment it starts; it exists so the progress list reflects that the
    /// apps were checked at all.
    private func fetchLinkedAppDigests(preferences: UserPreferences) -> [LinkedAppDigest] {
        guard preferences.includeLockedInFit || preferences.includeSocialClimber else { return [] }
        markPhase("checking_apps", .active)
        let digests = linkedApps.digests(preferences: preferences)
        markPhase("checking_apps", .done)
        return digests
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

    private nonisolated static func runResearch(
        group: ResearchGroup,
        context: BriefContext,
        openRouter: OpenRouterService,
        providerOrder: [AIProvider]
    ) async throws -> ResearchPacket {
        let preferences = context.preferences
        let result = try await withTimeout(seconds: Self.researchTimeoutSeconds, stage: "Research") {
            try await ProviderFallback.complete(
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
                temperature: 0.3,
                maxTokens: Self.researchMaxTokens
            )
        }
        let decoded = try JSONDecoder().decode(
            ResearchResponse.self,
            from: Data(Self.extractJSON(result.content).utf8)
        )
        let citedURLs = result.citations.map(\.url)
        let excludedDomains = Set(preferences.excludedDomains.map { $0.lowercased() })
        let webSearchActive = preferences.useWebSearchPlugin

        // Normalize and validate every candidate URL against the citation
        // annotations OpenRouter actually returned.
        let candidates = decoded.candidates.compactMap { raw -> CandidateStory? in
            var candidate = raw
            guard URLValidation.isPlausible(candidate.sourceURL) else { return nil }
            let domain = URLValidation.domain(of: candidate.sourceURL)
            guard !excludedDomains.contains(domain) else { return nil }
            candidate.sourceDomain = domain
            candidate.id = "\(group.rawValue):\(candidate.id)"
            let verified = URLValidation.matchesCitations(candidate.sourceURL, citations: citedURLs)
            candidate.citationVerified = verified
            // When web search actually ran, a candidate whose URL matches
            // none of the real citations almost certainly wasn't found
            // through search at all — it's fabricated, often a stale,
            // well-known past event recalled from training data and
            // dressed up with a fake recent date. Drop it outright rather
            // than forwarding it to the editor as a fallback option; the
            // editor previously used unverified candidates whenever no
            // verified one covered a topic, which is exactly the loophole
            // that let hallucinated "results" through. When web search is
            // off there's nothing to verify against (citedURLs is always
            // empty), so skip this filter entirely in that mode instead of
            // dropping every candidate.
            if webSearchActive && !verified { return nil }
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
        // Captured as a local rather than referenced as self.openRouter
        // inside the @Sendable closures below — capturing self (a
        // MainActor-isolated, non-Sendable reference type) from an
        // instance method would be a concurrency-checking error;
        // capturing the plain-struct value directly is not.
        let openRouter = self.openRouter
        let result = try await Self.withTimeout(seconds: Self.editorTimeoutSeconds, stage: "Editing") {
            try await ProviderFallback.complete(
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
                temperature: 0.2,
                maxTokens: Self.editorMaxTokens
            )
        }
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
            // The content snippet is kept in diagnostics (never shown to
            // the user directly) so a repeat failure is actually
            // debuggable via Settings → Data → Export diagnostic JSON,
            // instead of only ever seeing Swift's generic decode-error text.
            diagnostics.errors.append(
                "Editor output failed to decode: \(error.localizedDescription). Attempting repair. Raw content: \(Self.diagnosticSnippet(result.content))"
            )
            let repair = try await Self.withTimeout(seconds: Self.editorRepairTimeoutSeconds, stage: "Editing repair") {
                try await ProviderFallback.complete(
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
                    temperature: 0.0,
                    maxTokens: Self.editorMaxTokens
                )
            }
            diagnostics.totalInputTokens += repair.inputTokens
            diagnostics.totalOutputTokens += repair.outputTokens
            let response: EditorResponse
            do {
                response = try Self.decodeEditor(repair.content)
            } catch let repairDecodeError {
                // Both the original and the one repair attempt produced
                // output that doesn't decode — surface a clear, actionable
                // message here rather than letting Swift's generic
                // DecodingError.localizedDescription ("The data couldn't
                // be read because it isn't in the correct format.") reach
                // the user verbatim. The specific decode error is still
                // captured in diagnostics for export.
                diagnostics.errors.append(
                    "Editor repair output also failed to decode: \(repairDecodeError.localizedDescription). Raw content: \(Self.diagnosticSnippet(repair.content))"
                )
                throw EngineError.invalidStructuredOutput(stage: "Editing")
            }
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
            // Retry decoding once against the raw content (trailing-comma
            // repaired, but not re-sliced) before giving up.
            return try JSONDecoder().decode(EditorResponse.self, from: Data(removeTrailingCommas(content).utf8))
        }
    }

    /// A short, non-secret preview of a model's raw response for
    /// diagnostics only — never shown directly to the user, but exported
    /// diagnostics need to show what actually came back to be debuggable.
    private nonisolated static func diagnosticSnippet(_ content: String) -> String {
        String(content.prefix(600))
    }

    /// Strip markdown fences and any prose around the JSON object, then
    /// repair the single most common way a free-tier model's output still
    /// fails to decode afterward.
    private nonisolated static func extractJSON(_ content: String) -> String {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return removeTrailingCommas(balancedJSONObject(in: text) ?? text)
    }

    /// Finds the first `{` and walks forward tracking brace depth (and
    /// string-literal state, so a `{`/`}` inside a quoted value doesn't
    /// throw off the count) to the matching closing `}` — unlike a naive
    /// "first `{` to last `}`" scan, this isn't fooled by a model that
    /// ignores the "no prose" instruction and appends commentary
    /// containing its own stray braces after the real JSON object, which
    /// previously produced a corrupted slice that failed to decode.
    /// Returns nil if the braces never balance (e.g. genuinely truncated
    /// mid-object), in which case the caller falls back to the raw text.
    private nonisolated static func balancedJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var isEscaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if isEscaped {
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// A trailing comma before a closing `}`/`]` is invalid JSON but a
    /// common thing for a model to emit, especially free/open-weight ones
    /// with looser structured-output support — strip it rather than let a
    /// single stray comma fail the whole decode.
    private nonisolated static func removeTrailingCommas(_ json: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: ",(\\s*[}\\]])") else { return json }
        let range = NSRange(json.startIndex..., in: json)
        return regex.stringByReplacingMatches(in: json, range: range, withTemplate: "$1")
    }

    // MARK: - Stage 4 + 5

    private func assembleBrief(
        editor: EditorResponse,
        editorModel: String,
        context: BriefContext,
        packets: [ResearchPacket],
        failedGroups: [ResearchGroup],
        linkedAppDigests: [LinkedAppDigest],
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
            linkedAppDigests: linkedAppDigests,
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
        if preferences.includeLockedInFit || preferences.includeSocialClimber {
            list.append(PhaseProgress(id: "checking_apps", title: "Checking your apps"))
        }
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
        if status == .active {
            phases[index].startedAt = Date()
        }
    }

    // MARK: - Diagnostics

    private func saveDiagnostics(_ diagnostics: GenerationDiagnostics) {
        UserDefaults.standard.set(diagnostics.exportJSON(), forKey: Self.diagnosticsKey)
    }
}

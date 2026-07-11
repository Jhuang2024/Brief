import Foundation

/// Best-effort, cost-capped watcher that runs roughly once an hour,
/// separate from the daily brief pipeline. Deliberately NOT another brief:
/// one small completion call with a strict, very-high-bar schema, and in
/// the overwhelming majority of hours it finds nothing and does nothing —
/// no alert saved, no notification sent, no further cost. This is the only
/// thing in the app allowed to touch the network outside the two brief
/// generation triggers (morning time, manual refresh).
@MainActor
@Observable
final class BreakingCheckService {
    /// Slightly under an hour so a BGAppRefreshTask firing a bit early, or
    /// the app being opened mid-hour, doesn't get silently skipped — while
    /// still bounding worst-case usage to roughly once an hour.
    private static let minimumInterval: TimeInterval = 55 * 60

    private let store: BriefStore
    private let alertStore: BreakingAlertStore
    private let preferencesStore: PreferencesStore
    private let notificationService: NotificationService
    private let openRouter = OpenRouterService()

    private(set) var lastCheckedAt: Date?
    private var checkTask: Task<Void, Never>?

    init(
        store: BriefStore,
        alertStore: BreakingAlertStore,
        preferencesStore: PreferencesStore,
        notificationService: NotificationService
    ) {
        self.store = store
        self.alertStore = alertStore
        self.preferencesStore = preferencesStore
        self.notificationService = notificationService
    }

    /// Entry point for both the hourly background task and a foreground
    /// fallback call. A concurrent caller shares the in-flight check
    /// rather than starting a second one. Never throws — there is no
    /// user-facing surface for a failed background check, so a failure
    /// here just means this hour is silently skipped, same as finding
    /// nothing worth reporting.
    func checkIfDue(now: Date = Date()) async {
        if let checkTask {
            await checkTask.value
            return
        }
        let gatingPreferences = preferencesStore.preferences
        guard gatingPreferences.breakingAlertsEnabled, gatingPreferences.notificationsEnabled else { return }
        if let lastCheckedAt, now.timeIntervalSince(lastCheckedAt) < Self.minimumInterval {
            return
        }
        let task = Task { await self.run(now: now) }
        checkTask = task
        await task.value
        checkTask = nil
    }

    private func run(now: Date) async {
        lastCheckedAt = now
        let preferences = preferencesStore.preferences
        let providerOrder = preferences.providerAttemptOrder
        guard !providerOrder.isEmpty else { return }

        let recentFingerprints = Set(
            store.recentStoryMemory(days: 3, now: now).map(\.fingerprint) +
            alertStore.recentFingerprints(days: 7, now: now)
        )
        let recentHeadlines = Array(Set(
            store.recentStoryMemory(days: 3, now: now).map(\.headline) +
            alertStore.recentHeadlines(days: 7, now: now)
        )).prefix(60).map { $0 }

        do {
            let openRouter = self.openRouter
            let result = try await ProviderFallback.withTimeout(seconds: 25, stage: "Breaking check") {
                try await ProviderFallback.complete(
                    providerOrder: providerOrder,
                    openRouter: openRouter,
                    model: preferences.researchModel,
                    systemPrompt: Self.systemPrompt,
                    userPrompt: Self.userPrompt(
                        preferences: preferences,
                        recentHeadlines: recentHeadlines,
                        now: now
                    ),
                    schemaName: "breaking_check",
                    schema: Self.schema,
                    useStructuredOutput: preferences.useStructuredOutput,
                    webSearch: preferences.useWebSearchPlugin,
                    webResults: 4,
                    temperature: 0.1,
                    maxTokens: 500
                )
            }

            guard let response = Self.decode(result.content), response.hasAlert else { return }
            let headline = response.headline.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = response.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let whyItMatters = response.whyItMatters.trimmingCharacters(in: .whitespacesAndNewlines)
            let sourceURL = response.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !headline.isEmpty, !summary.isEmpty, !whyItMatters.isEmpty,
                  URLValidation.isPlausible(sourceURL)
            else { return }
            // Defense in depth on top of the HTTP-error catch below: a
            // provider that's out of credit/quota can sometimes still
            // return 200 with a schema-conforming apology stuffed into the
            // content instead of a proper error. Never treat that as a
            // real alert.
            guard !Self.looksLikeProviderFailure(headline + " " + summary + " " + whyItMatters)
            else { return }

            let domain = URLValidation.domain(of: sourceURL)
            let entities = Fingerprint.entities(from: headline + " " + summary)
            let fingerprint = Fingerprint.make(
                headline: headline, sourceURL: sourceURL, entities: entities, category: "breaking"
            )
            guard !recentFingerprints.contains(fingerprint) else { return }

            // The exact fingerprint above only catches an identical headline +
            // URL + entity set. The same real-world event reworded across
            // outlets — "Apple files lawsuit accusing OpenAI…" vs "Apple
            // Accuses OpenAI… in Major Lawsuit", title-case vs sentence-case,
            // a different source URL — sails right past it, which is how Jerry
            // got pinged repeatedly about one story. This token-overlap check
            // treats a headline that substantially restates a recent one as a
            // duplicate and drops it silently.
            guard !Self.isNearDuplicate(headline, of: recentHeadlines) else { return }

            let sourceTitle = response.sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let alert = BreakingAlert(
                fingerprint: fingerprint,
                headline: headline,
                summary: summary,
                whyItMatters: whyItMatters,
                sourceTitle: sourceTitle.isEmpty ? domain : sourceTitle,
                sourceDomain: domain,
                sourceURLString: sourceURL,
                detectedAt: now
            )
            alertStore.save(alert)
            await notificationService.sendBreakingAlertNotification(headline: headline)
        } catch {
            // Best-effort only: an hourly check failing for any reason —
            // a timeout, no provider reachable, malformed output, or an
            // HTTP error such as 402 Payment Required / "insufficient
            // credits" — is treated exactly the same as finding nothing:
            // silently skip this hour. Never save an alert or send a
            // notification for a failed check.
        }
    }

    /// Catches the rare case where a provider that's out of credit or
    /// quota returns HTTP 200 with an apology instead of a proper error
    /// status — the normal error path above only covers a thrown error,
    /// so this is a second, content-based check on anything that did
    /// decode successfully.
    private static func looksLikeProviderFailure(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let markers = [
            "insufficient credit", "out of credit", "no credits",
            "payment required", "quota exceeded", "quota has been exceeded",
            "billing", "rate limit", "rate-limited", "api key", "unauthorized",
        ]
        return markers.contains { lowered.contains($0) }
    }

    /// Whether `candidate` substantially restates any headline in `recent` —
    /// i.e. the same event under different wording. Compares significant-word
    /// sets rather than raw strings, so it is resilient to reordering,
    /// title-case vs sentence-case, and filler words that defeat the exact
    /// fingerprint. A pair counts as a duplicate when either the Jaccard
    /// overlap is high or nearly all of the shorter headline's words appear
    /// in the other (the latter catches "X sues Y" vs "X sues Y in landmark
    /// case", where one headline is a superset of the other).
    static func isNearDuplicate(_ candidate: String, of recent: [String]) -> Bool {
        let candidateTokens = significantTokens(candidate)
        guard candidateTokens.count >= 2 else { return false }
        for headline in recent {
            let tokens = significantTokens(headline)
            guard tokens.count >= 2 else { continue }
            let intersection = candidateTokens.intersection(tokens).count
            guard intersection > 0 else { continue }
            let union = candidateTokens.union(tokens).count
            let smaller = min(candidateTokens.count, tokens.count)
            if Double(intersection) / Double(union) >= 0.6
                || Double(intersection) / Double(smaller) >= 0.8 {
                return true
            }
        }
        return false
    }

    /// Content-bearing lowercased words of a headline: alphanumeric tokens of
    /// 3+ characters, minus common filler that carries no topic signal.
    private static func significantTokens(_ text: String) -> Set<String> {
        let stopWords: Set<String> = [
            "the", "and", "for", "with", "from", "its", "are", "was", "were",
            "has", "have", "had", "over", "amid", "into", "after", "before",
            "says", "say", "said", "major", "new", "how", "why", "what", "who",
            "that", "this", "will", "amid", "as", "at", "by", "in", "of", "on",
            "or", "to", "up", "off",
        ]
        let normalized = Fingerprint.normalizeHeadline(text)
        return Set(
            normalized.split(separator: " ")
                .map(String.init)
                .filter { $0.count >= 3 && !stopWords.contains($0) }
        )
    }

    private static func decode(_ content: String) -> BreakingCheckResponse? {
        try? JSONDecoder().decode(BreakingCheckResponse.self, from: Data(extractJSON(content).utf8))
    }

    /// Strip markdown fences and any prose around the outermost JSON object.
    private static func extractJSON(_ content: String) -> String {
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

    // MARK: - Prompt + schema

    private static let systemPrompt = """
    You are a narrow breaking-news watcher for a private briefing app belonging to Jerry. You run silently roughly once an hour, separate from Jerry's daily morning brief.

    Your only job is to decide whether something has happened recently that is so urgent or significant Jerry would want to be interrupted with a push notification right now, rather than wait to read about it in tomorrow's brief.

    The bar is very high. This is NOT another briefing. In the overwhelming majority of checks, nothing qualifies, and you must return hasAlert: false with every other field left as an empty string. Only return hasAlert: true for something like a major confirmed high-impact development directly and specifically relevant to Jerry's stated interests below: think market-moving news, a materially important announcement from a company or person Jerry follows, or a globally significant event. Never alert for routine updates, incremental news, rumors, minor score changes, opinion pieces, or anything that can just as easily wait for the regular brief.

    Never invent a headline, source, or URL. Any alert must cite a real URL you found through web search.

    Return only data matching the required JSON schema.
    """

    private static func userPrompt(preferences: UserPreferences, recentHeadlines: [String], now: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        let interestGroups: [(String, [String])] = [
            ("Topics", preferences.topics),
            ("Companies", preferences.companies),
            ("People", preferences.people),
            ("F1 drivers/teams", preferences.f1DriversAndTeams),
            ("Sports leagues", preferences.sportsLeagues),
            ("Sports teams", preferences.sportsTeams),
            ("Athletes", preferences.athletes),
        ]
        let interests = interestGroups
            .filter { !$0.1.isEmpty }
            .map { "\($0.0): \($0.1.joined(separator: ", "))" }
            .joined(separator: "\n")

        let alreadyCovered = recentHeadlines.isEmpty
            ? "(none)"
            : recentHeadlines.joined(separator: "\n")

        return """
        Current time: \(formatter.string(from: now))

        Jerry's interests:
        \(interests)

        Stories already covered in the last few days — never re-flag one of these unless there is a major new development since:
        \(alreadyCovered)

        Check whether anything has happened recently that is urgent enough to interrupt Jerry right now.
        """
    }

    private static var schema: [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "hasAlert": ["type": "boolean", "description": "True only if something clears the very high urgency bar"],
                "headline": ["type": "string", "description": "Empty string if hasAlert is false"],
                "summary": ["type": "string", "description": "2-3 factual sentences. Empty string if hasAlert is false"],
                "whyItMatters": ["type": "string", "description": "Why this is urgent enough to interrupt Jerry right now. Empty string if hasAlert is false"],
                "sourceTitle": ["type": "string", "description": "Publication name. Empty string if hasAlert is false"],
                "sourceURL": ["type": "string", "description": "URL actually found via web search. Empty string if hasAlert is false"],
            ],
            "required": ["hasAlert", "headline", "summary", "whyItMatters", "sourceTitle", "sourceURL"],
        ]
    }
}

private struct BreakingCheckResponse: Codable {
    var hasAlert: Bool
    var headline: String
    var summary: String
    var whyItMatters: String
    var sourceTitle: String
    var sourceURL: String
}

import Foundation

/// Shared timeout + per-call provider fallback, used by both the full
/// daily-brief pipeline (`BriefingEngine`) and the lightweight hourly
/// breaking check (`BreakingCheckService`). Extracted so both share the
/// exact same resilience behavior instead of drifting apart.
enum ProviderFallback {
    struct TimeoutError: LocalizedError {
        let stage: String
        var errorDescription: String? { "\(stage) took too long and was stopped." }
    }

    /// Races `operation` against a timer so a stuck request fails
    /// cleanly instead of hanging indefinitely.
    static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        stage: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError(stage: stage)
            }
            guard let result = try await group.next() else {
                throw TimeoutError(stage: stage)
            }
            group.cancelAll()
            return result
        }
    }

    /// Tries each provider in `providerOrder` (already filtered to ones
    /// with a saved key) in turn, returning the first success. If every
    /// attempt fails, throws a combined error naming each provider and
    /// what went wrong with it.
    static func complete(
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
        temperature: Double = 0.3,
        maxTokens: Int? = nil
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
                    temperature: temperature,
                    maxTokens: maxTokens
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
}

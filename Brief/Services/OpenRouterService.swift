import Foundation

/// Client for an OpenAI-style chat completions API. Each request is sent
/// against an explicit base URL and API key resolved by the caller —
/// BriefingEngine tries each configured provider (OpenRouter, Bazaarlink)
/// in order and falls back automatically, so this type has no built-in
/// notion of "the" provider. Never logs the API key.
struct OpenRouterService {
    struct Citation: Hashable {
        var url: String
        var title: String
        var domain: String { URLValidation.domain(of: url) }
    }

    struct CompletionResult {
        var content: String
        var citations: [Citation]
        var modelUsed: String
        var inputTokens: Int
        var outputTokens: Int
        var duration: TimeInterval
    }

    enum OpenRouterError: LocalizedError {
        case missingAPIKey
        case httpError(status: Int, message: String)
        case emptyResponse
        case invalidResponse
        case allProvidersFailed(details: String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Add an OpenRouter or Bazaarlink API key in Settings to generate a briefing."
            case .httpError(let status, let message):
                return "The AI provider request failed (HTTP \(status)). \(message)"
            case .emptyResponse:
                return "The AI provider returned an empty response."
            case .invalidResponse:
                return "The AI provider returned a response that could not be read."
            case .allProvidersFailed(let details):
                return "All configured AI providers failed. \(details)"
            }
        }
    }

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 300
        session = URLSession(configuration: configuration)
    }

    /// Run one structured completion against `{baseURL}/chat/completions`.
    /// - Parameters:
    ///   - apiKey: resolved by the caller — BriefingEngine tries each
    ///     configured provider's key in order and falls back to the next
    ///     one on failure, so this service has no opinion on which
    ///     provider or key is "the" one to use.
    ///   - schema: strict JSON schema the response must match (a JSON object).
    ///   - useStructuredOutput: send `response_format`/`provider` fields.
    ///     Turn off in Settings if a provider rejects the OpenRouter-style
    ///     strict json_schema request shape.
    ///   - webSearch: attach the OpenRouter-style web plugin, when enabled
    ///     in Settings.
    ///   - webResults: plugin max_results, configurable via research depth.
    func complete(
        baseURL: URL,
        apiKey: String,
        model: String,
        systemPrompt: String,
        userPrompt: String,
        schemaName: String,
        schema: [String: Any],
        useStructuredOutput: Bool,
        webSearch: Bool,
        webResults: Int = 10,
        temperature: Double = 0.3
    ) async throws -> CompletionResult {
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt],
            ],
            "temperature": temperature,
            "usage": ["include": true],
        ]
        if useStructuredOutput {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": [
                    "name": schemaName,
                    "strict": true,
                    "schema": schema,
                ],
            ]
            // Deliberately not setting provider.require_parameters here.
            // That flag makes OpenRouter hard-reject any endpoint that
            // can't fully honour every requested parameter — for
            // free-tier/open-weight models, that often leaves zero
            // qualifying endpoints and OpenRouter returns 404 "No
            // endpoints found" instead of routing anywhere at all.
            // Structured output is still requested and used when an
            // endpoint honours it; decodeEditor/extractJSON already parse
            // leniently (strip markdown fences, find the outermost JSON
            // object) for the case where it's ignored, so degrading
            // gracefully here is strictly better than a guaranteed
            // failure to get any response at all.
        } else {
            // No enforced schema: ask for JSON in plain language instead.
            // The response is still parsed defensively (extractJSON strips
            // prose/markdown fences around the outermost JSON object).
            body["messages"] = [
                ["role": "system", "content": systemPrompt + "\n\nRespond with ONLY a single JSON object matching this schema, no prose, no markdown fences:\n" + Self.jsonString(schema)],
                ["role": "user", "content": userPrompt],
            ]
        }
        if webSearch {
            body["plugins"] = [["id": "web", "max_results": webResults]]
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Brief", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = Date()
        let (data, http) = try await sendWithRetry(request, maxRetries: 3)
        let duration = Date().timeIntervalSince(started)

        guard (200..<300).contains(http.statusCode) else {
            throw OpenRouterError.httpError(
                status: http.statusCode,
                message: Self.errorMessage(from: data)
            )
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let choice = decoded.choices.first,
              let content = choice.message.content,
              !content.isEmpty
        else {
            throw OpenRouterError.emptyResponse
        }

        let citations = (choice.message.annotations ?? []).compactMap { annotation -> Citation? in
            guard annotation.type == "url_citation",
                  let citation = annotation.urlCitation
            else { return nil }
            return Citation(url: citation.url, title: citation.title ?? "")
        }

        return CompletionResult(
            content: content,
            citations: citations,
            modelUsed: decoded.model ?? model,
            inputTokens: decoded.usage?.promptTokens ?? 0,
            outputTokens: decoded.usage?.completionTokens ?? 0,
            duration: duration
        )
    }

    /// Validates a key by sending one minimal chat completion — this works
    /// against any OpenAI-style provider, unlike OpenRouter's proprietary
    /// `/key` introspection endpoint. Returns a short human-readable result.
    func testConnection(baseURL: URL, apiKey: String, model: String) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Brief", forHTTPHeaderField: "X-Title")
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": "Reply with the single word OK."],
            ],
            "max_tokens": 5,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, http) = try await sendWithRetry(request, maxRetries: 2)
        guard (200..<300).contains(http.statusCode) else {
            throw OpenRouterError.httpError(
                status: http.statusCode,
                message: http.statusCode == 401 ? "The key was rejected." : Self.errorMessage(from: data)
            )
        }
        guard let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data),
              decoded.choices.first?.message.content != nil
        else {
            throw OpenRouterError.invalidResponse
        }
        return "Connected — \(decoded.model ?? model) responded."
    }

    /// Sends `request`, retrying on 429 (rate limited) or 5xx (transient
    /// server error) with backoff before giving up — a 429 means "too
    /// many requests," not "no credits" (that's 402), and it routinely
    /// clears within seconds. Concurrent research requests against a
    /// free-tier model are exactly the kind of burst that trips per-minute
    /// rate limits, so failing on the first 429 was needlessly fragile.
    private func sendWithRetry(_ request: URLRequest, maxRetries: Int) async throws -> (Data, HTTPURLResponse) {
        var lastError = OpenRouterError.invalidResponse
        for attempt in 0...maxRetries {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw OpenRouterError.invalidResponse
            }
            if (http.statusCode == 429 || (500...599).contains(http.statusCode)), attempt < maxRetries {
                lastError = .httpError(status: http.statusCode, message: Self.errorMessage(from: data))
                let delay = Self.retryDelay(response: http, attempt: attempt)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                continue
            }
            return (data, http)
        }
        throw lastError
    }

    /// Honors a `Retry-After` header (seconds) when the provider sends
    /// one; otherwise a short exponential backoff (2s, 4s, 8s), capped at
    /// 30s so a single request can't stall the whole pipeline.
    private static func retryDelay(response: HTTPURLResponse, attempt: Int) -> TimeInterval {
        if let header = response.value(forHTTPHeaderField: "Retry-After"),
           let seconds = Double(header) {
            return min(max(seconds, 1), 30)
        }
        return min(pow(2.0, Double(attempt + 1)), 30)
    }

    private static func jsonString(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Tries several common error-body shapes before giving up. The
    /// original version only understood `{"error": {"message": ...}}`
    /// (OpenAI's shape) and silently returned an empty string for
    /// anything else, which surfaced to the user as a bare "request
    /// failed" with no actual explanation.
    ///
    /// OpenRouter specifically wraps a failure from the upstream company
    /// actually hosting a routed/free model as a generic top-level
    /// `error.message` (often just "Provider returned error") while the
    /// real reason sits one level deeper in `error.metadata` — `raw` (the
    /// upstream's own error text) and `provider_name` (which upstream was
    /// used). Surfacing those turns an opaque "Provider returned error"
    /// into something like "Provider returned error (provider: Example
    /// Inference Co) — rate limit exceeded", which actually says what
    /// happened.
    private static func errorMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Not JSON at all — surface the raw body so something is
            // visible instead of nothing.
            let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? "" : String(raw.prefix(300))
        }

        if let error = object["error"] as? [String: Any] {
            var parts: [String] = []
            if let message = error["message"] as? String, !message.isEmpty {
                parts.append(message)
            }
            if let metadata = error["metadata"] as? [String: Any] {
                if let providerName = metadata["provider_name"] as? String {
                    parts.append("(provider: \(providerName))")
                }
                if let raw = metadata["raw"] as? String, !raw.isEmpty {
                    parts.append("— \(raw.prefix(200))")
                } else if let rawObject = metadata["raw"] as? [String: Any] {
                    if let nestedMessage = (rawObject["error"] as? [String: Any])?["message"] as? String {
                        parts.append("— \(nestedMessage)")
                    } else if let nestedMessage = rawObject["message"] as? String {
                        parts.append("— \(nestedMessage)")
                    }
                }
            }
            if !parts.isEmpty {
                return parts.joined(separator: " ")
            }
        }
        if let error = object["error"] as? String {
            return error
        }
        if let message = object["message"] as? String {
            return message
        }
        if let detail = object["detail"] as? String {
            return detail
        }

        let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "" : String(raw.prefix(300))
    }

    // MARK: - Response decoding

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                struct Annotation: Decodable {
                    struct URLCitation: Decodable {
                        let url: String
                        let title: String?

                        enum CodingKeys: String, CodingKey {
                            case url, title
                        }
                    }

                    let type: String
                    let urlCitation: URLCitation?

                    enum CodingKeys: String, CodingKey {
                        case type
                        case urlCitation = "url_citation"
                    }
                }

                let content: String?
                let annotations: [Annotation]?
            }

            let message: Message
        }

        struct Usage: Decodable {
            let promptTokens: Int?
            let completionTokens: Int?

            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
            }
        }

        let choices: [Choice]
        let usage: Usage?
        let model: String?
    }
}

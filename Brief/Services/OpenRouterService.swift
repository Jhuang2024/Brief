import Foundation

/// Client for an OpenAI-style chat completions API. Defaults to
/// OpenRouter, but the base URL, structured-output request shape, and
/// web-search plugin are all configurable from Settings so any provider
/// exposing a compatible `/chat/completions` endpoint can be used
/// instead. Never logs the API key.
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
        case invalidBaseURL
        case httpError(status: Int, message: String)
        case emptyResponse
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Add your AI provider API key in Settings to generate a briefing."
            case .invalidBaseURL:
                return "The API base URL in Settings isn't a valid https:// address."
            case .httpError(let status, let message):
                return "The AI provider request failed (HTTP \(status)). \(message)"
            case .emptyResponse:
                return "The AI provider returned an empty response."
            case .invalidResponse:
                return "The AI provider returned a response that could not be read."
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
    ///   - schema: strict JSON schema the response must match (a JSON object).
    ///   - useStructuredOutput: send `response_format`/`provider` fields.
    ///     Turn off in Settings if a provider rejects the OpenRouter-style
    ///     strict json_schema request shape.
    ///   - webSearch: attach the OpenRouter-style web plugin, when enabled
    ///     in Settings.
    ///   - webResults: plugin max_results, configurable via research depth.
    func complete(
        baseURL: URL,
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
        guard let apiKey = KeychainService.loadAPIKey() else {
            throw OpenRouterError.missingAPIKey
        }

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
            // Fail cleanly instead of silently routing to a provider that
            // cannot honour structured output. OpenRouter-specific; providers
            // that ignore unknown fields are unaffected either way.
            body["provider"] = ["require_parameters": true]
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
        let (data, response) = try await session.data(for: request)
        let duration = Date().timeIntervalSince(started)

        guard let http = response as? HTTPURLResponse else {
            throw OpenRouterError.invalidResponse
        }
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

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenRouterError.invalidResponse
        }
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

    private static func jsonString(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func errorMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return ""
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

import Foundation

/// Direct client for the OpenRouter chat completions API.
/// Requests use strict JSON-schema structured output and, when asked,
/// the OpenRouter web-search plugin. Never logs the API key.
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

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Add your OpenRouter API key in Settings to generate a briefing."
            case .httpError(let status, let message):
                return "OpenRouter request failed (HTTP \(status)). \(message)"
            case .emptyResponse:
                return "OpenRouter returned an empty response."
            case .invalidResponse:
                return "OpenRouter returned a response that could not be read."
            }
        }
    }

    private static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private static let keyEndpoint = URL(string: "https://openrouter.ai/api/v1/key")!

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 300
        session = URLSession(configuration: configuration)
    }

    /// Run one structured completion.
    /// - Parameters:
    ///   - schema: strict JSON schema the response must match (a JSON object).
    ///   - webSearch: attach the OpenRouter web plugin.
    ///   - webResults: plugin max_results, configurable via research depth.
    func complete(
        model: String,
        systemPrompt: String,
        userPrompt: String,
        schemaName: String,
        schema: [String: Any],
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
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": schemaName,
                    "strict": true,
                    "schema": schema,
                ],
            ],
            // Fail cleanly instead of silently routing to a provider that
            // cannot honour structured output.
            "provider": [
                "require_parameters": true,
            ],
            "usage": ["include": true],
        ]
        if webSearch {
            body["plugins"] = [["id": "web", "max_results": webResults]]
        }

        var request = URLRequest(url: Self.endpoint)
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

    /// Validate an API key against the OpenRouter key endpoint.
    /// Returns a short human-readable description of the key.
    func testConnection(apiKey: String) async throws -> String {
        var request = URLRequest(url: Self.keyEndpoint)
        request.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
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
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let info = object["data"] as? [String: Any] {
            let label = info["label"] as? String ?? "key"
            if let usage = info["usage"] as? Double {
                return "Connected — \(label), $\(String(format: "%.2f", usage)) used."
            }
            return "Connected — \(label)."
        }
        return "Connected."
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

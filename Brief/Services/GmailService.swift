import Foundation

/// Read-only Gmail REST client, structured like `GoogleCalendarService`:
/// same auth service, same bearer-token GET helper, same "faithful to the
/// API, no interpretation" stance. Fetches recent inbox messages for the
/// brief's Email section. Message content never goes anywhere except the
/// rendered section — not to the AI providers, not into diagnostics.
@MainActor
struct GmailService {
    enum GmailError: LocalizedError {
        case httpError(Int)
        var errorDescription: String? {
            switch self {
            case .httpError(let status):
                return "Gmail request failed (HTTP \(status))."
            }
        }
    }

    let auth: GoogleAuthenticationService
    private let session = URLSession.shared

    /// Inbox messages received after `since`, newest first, capped at
    /// `maxResults`. Promotions and social-tab mail are excluded — a
    /// morning brief wants the mail a person would actually open. The
    /// category operators are safely inert on accounts without a tabbed
    /// inbox (excluding a category that doesn't exist excludes nothing).
    func fetchInboxMessages(since: Date, maxResults: Int = 10) async throws -> [EmailMessage] {
        let token = try await auth.accessToken(requiring: GoogleAuthenticationService.gmailReadOnlyScope)

        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        components.queryItems = [
            URLQueryItem(
                name: "q",
                value: "in:inbox -category:promotions -category:social after:\(Int(since.timeIntervalSince1970))"
            ),
            URLQueryItem(name: "maxResults", value: String(maxResults)),
        ]
        let listData = try await get(components.url!, token: token)
        let list = try JSONDecoder().decode(MessageListResponse.self, from: listData)
        let ids = (list.messages ?? []).map(\.id)
        guard !ids.isEmpty else { return [] }

        // Metadata-only per-message fetches (headers + snippet, never the
        // body), concurrently since each is an independent small request.
        // One broken message must not sink the rest.
        let messages = await withTaskGroup(of: EmailMessage?.self) { group in
            for id in ids {
                group.addTask { [session] in
                    try? await Self.fetchMessage(id: id, token: token, session: session)
                }
            }
            var collected: [EmailMessage] = []
            for await message in group {
                if let message { collected.append(message) }
            }
            return collected
        }
        return messages.sorted { $0.receivedAt > $1.receivedAt }
    }

    private nonisolated static func fetchMessage(
        id: String, token: String, session: URLSession
    ) async throws -> EmailMessage? {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)")!
        components.queryItems = [
            URLQueryItem(name: "format", value: "metadata"),
            URLQueryItem(name: "metadataHeaders", value: "From"),
            URLQueryItem(name: "metadataHeaders", value: "Subject"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GmailError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let decoded = try JSONDecoder().decode(MessageResponse.self, from: data)

        let headers = decoded.payload?.headers ?? []
        let from = headers.first { $0.name.caseInsensitiveCompare("From") == .orderedSame }?.value ?? ""
        let subject = headers.first { $0.name.caseInsensitiveCompare("Subject") == .orderedSame }?.value ?? ""
        let (name, address) = parseFrom(from)
        // internalDate is epoch milliseconds as a string.
        let receivedAt = Double(decoded.internalDate ?? "").map { Date(timeIntervalSince1970: $0 / 1000) }

        return EmailMessage(
            id: decoded.id,
            fromName: name,
            fromAddress: address,
            subject: subject.isEmpty ? "(No subject)" : subject,
            snippet: decodeEntities(decoded.snippet ?? ""),
            receivedAt: receivedAt ?? .now,
            isUnread: decoded.labelIds?.contains("UNREAD") ?? false
        )
    }

    /// "Jane Doe <jane@example.com>" → ("Jane Doe", "jane@example.com");
    /// a bare address becomes both name and address.
    private nonisolated static func parseFrom(_ raw: String) -> (name: String, address: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close else {
            return (trimmed, trimmed)
        }
        let address = String(trimmed[trimmed.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
        var name = String(trimmed[..<open]).trimmingCharacters(in: .whitespaces)
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return (name.isEmpty ? address : name, address)
    }

    /// Gmail snippets arrive with the handful of HTML entities the API
    /// leaves encoded. Only these few ever show up in snippets; anything
    /// exotic passes through untouched rather than pulling in a full HTML
    /// parser for a one-line preview.
    private nonisolated static func decodeEntities(_ text: String) -> String {
        var output = text
        let entities = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&nbsp;": " ",
        ]
        for (entity, character) in entities {
            output = output.replacingOccurrences(of: entity, with: character)
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func get(_ url: URL, token: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GmailError.httpError(0)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GmailError.httpError(http.statusCode)
        }
        return data
    }

    // MARK: - Response decoding

    private struct MessageListResponse: Decodable {
        struct Ref: Decodable {
            let id: String
        }
        let messages: [Ref]?
    }

    private struct MessageResponse: Decodable {
        struct Payload: Decodable {
            struct Header: Decodable {
                let name: String
                let value: String
            }
            let headers: [Header]?
        }
        let id: String
        let snippet: String?
        let internalDate: String?
        let labelIds: [String]?
        let payload: Payload?
    }
}

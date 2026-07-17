import Foundation

/// Read-only Gmail REST client, structured like `GoogleCalendarService`:
/// same auth service, same bearer-token GET helper, same "faithful to the
/// API, no interpretation" stance. Fetches recent inbox messages for the
/// brief's Email section. Message content never goes anywhere except the
/// rendered section: not to the AI providers, not into diagnostics.
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
    /// `maxResults`. The bar is deliberately high: mail that is both
    /// important and still unread. An empty result is a real, good answer
    /// ("nothing important overnight"), never something to pad — recent but
    /// unimportant mail (task-app digests, notification chatter) does not
    /// belong in the brief just because it exists.
    ///
    /// Three filters get there. First, the query itself requires Gmail's
    /// own importance marker (`is:important`, the signal Gmail learns from
    /// how Jerry actually treats each sender) AND `is:unread` — mail
    /// already read has been dealt with and needs no morning triage.
    /// Promotions and Social stay excluded too; the category operators are
    /// safely inert on accounts without a tabbed inbox.
    ///
    /// Second, any message carrying a `List-Unsubscribe` header is dropped.
    /// Bulk senders (newsletters, marketing, news digests, job-alert
    /// blasts) are required to include it; genuine one-to-one mail and the
    /// real transactional updates worth keeping generally don't. This
    /// catches bulk mail Gmail's importance model over-rates (it happily
    /// marks a daily digest important once it's been opened a few times).
    ///
    /// Third, on-behalf automation mail is dropped by its From name: a
    /// sender like "Me via Todoist" is an app echoing Jerry's own actions
    /// back at him, not new information. The list request over-fetches so
    /// the per-message filters still leave a full section when there IS
    /// real mail.
    func fetchInboxMessages(since: Date, maxResults: Int = 10) async throws -> [EmailMessage] {
        let token = try await auth.accessToken(requiring: GoogleAuthenticationService.gmailReadOnlyScope)

        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        components.queryItems = [
            URLQueryItem(
                name: "q",
                value: "in:inbox is:important is:unread -category:promotions -category:social after:\(Int(since.timeIntervalSince1970))"
            ),
            // Over-fetch: the List-Unsubscribe and automation filters below
            // remove junk that slipped past the query, so ask for more IDs
            // than we intend to show and trim after filtering.
            URLQueryItem(name: "maxResults", value: String(min(maxResults * 3, 40))),
        ]
        let listData = try await get(components.url!, token: token)
        let list = try JSONDecoder().decode(MessageListResponse.self, from: listData)
        let ids = (list.messages ?? []).map(\.id)
        guard !ids.isEmpty else { return [] }

        // Metadata-only per-message fetches (headers + snippet, never the
        // body), concurrently since each is an independent small request.
        // A message that reads as bulk, or that fails to load, resolves to
        // nil and is dropped; one broken message must not sink the rest.
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
        return Array(messages.sorted { $0.receivedAt > $1.receivedAt }.prefix(maxResults))
    }

    private nonisolated static func fetchMessage(
        id: String, token: String, session: URLSession
    ) async throws -> EmailMessage? {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)")!
        components.queryItems = [
            URLQueryItem(name: "format", value: "metadata"),
            URLQueryItem(name: "metadataHeaders", value: "From"),
            URLQueryItem(name: "metadataHeaders", value: "Subject"),
            // Presence alone marks bulk mail; the value is never shown.
            URLQueryItem(name: "metadataHeaders", value: "List-Unsubscribe"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GmailError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let decoded = try JSONDecoder().decode(MessageResponse.self, from: data)

        let headers = decoded.payload?.headers ?? []
        // Bulk mail (newsletters, marketing, automated digests) is required
        // to carry List-Unsubscribe; genuine one-to-one mail doesn't. Drop
        // it so the section stays real messages and updates worth reading.
        if headers.contains(where: { $0.name.caseInsensitiveCompare("List-Unsubscribe") == .orderedSame }) {
            return nil
        }
        let from = headers.first { $0.name.caseInsensitiveCompare("From") == .orderedSame }?.value ?? ""
        let subject = headers.first { $0.name.caseInsensitiveCompare("Subject") == .orderedSame }?.value ?? ""
        let (name, address) = parseFrom(from)
        // On-behalf automation ("Me via Todoist", "Jerry via Notion"): an
        // app restating the user's own activity, never mail worth triage.
        if name.range(of: " via ", options: .caseInsensitive) != nil {
            return nil
        }
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

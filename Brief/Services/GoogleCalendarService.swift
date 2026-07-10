import Foundation

/// Read-only Google Calendar REST client.
@MainActor
struct GoogleCalendarService {
    enum CalendarError: LocalizedError {
        case httpError(Int)
        var errorDescription: String? {
            switch self {
            case .httpError(let status):
                return "Google Calendar request failed (HTTP \(status))."
            }
        }
    }

    let auth: GoogleAuthenticationService
    private let session = URLSession.shared

    /// The user's calendar list, for the Settings picker.
    func fetchCalendarList() async throws -> [GoogleCalendarInfo] {
        let token = try await auth.accessToken()
        let url = URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!
        let data = try await get(url, token: token)
        let decoded = try JSONDecoder().decode(CalendarListResponse.self, from: data)
        return decoded.items.map {
            GoogleCalendarInfo(id: $0.id, summary: $0.summary ?? $0.id, isPrimary: $0.primary ?? false)
        }
        .sorted { ($0.isPrimary ? 0 : 1, $0.summary) < ($1.isPrimary ? 0 : 1, $1.summary) }
    }

    /// Events for the selected calendars, merged chronologically and deduplicated.
    func fetchEvents(
        calendarIDs: [String],
        from timeMin: Date,
        to timeMax: Date
    ) async throws -> [CalendarEvent] {
        let token = try await auth.accessToken()
        let ids = calendarIDs.isEmpty ? ["primary"] : calendarIDs

        var merged: [CalendarEvent] = []
        var firstError: Error?
        for calendarID in ids {
            do {
                let events = try await fetchEvents(
                    calendarID: calendarID, token: token, timeMin: timeMin, timeMax: timeMax
                )
                merged.append(contentsOf: events)
            } catch {
                // One broken calendar must not sink the rest.
                if firstError == nil { firstError = error }
            }
        }
        if merged.isEmpty, let firstError, !ids.isEmpty {
            throw firstError
        }

        var seen = Set<String>()
        return merged
            .sorted { ($0.isAllDay ? 0 : 1, $0.start) < (($1.isAllDay ? 0 : 1), $1.start) }
            .filter { seen.insert($0.dedupeKey).inserted }
    }

    private func fetchEvents(
        calendarID: String,
        token: String,
        timeMin: Date,
        timeMax: Date
    ) async throws -> [CalendarEvent] {
        var components = URLComponents(
            string: "https://www.googleapis.com/calendar/v3/calendars/\(percentEncode(calendarID))/events"
        )!
        components.queryItems = [
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "timeMin", value: DateFormatting.rfc3339(timeMin)),
            URLQueryItem(name: "timeMax", value: DateFormatting.rfc3339(timeMax)),
            URLQueryItem(name: "timeZone", value: TimeZone.current.identifier),
            URLQueryItem(name: "maxResults", value: "100"),
        ]
        let data = try await get(components.url!, token: token)
        let decoded = try JSONDecoder().decode(EventsResponse.self, from: data)

        return decoded.items.compactMap { item -> CalendarEvent? in
            guard item.status != "cancelled" else { return nil }
            guard let (start, isAllDay) = Self.parse(time: item.start),
                  let (end, _) = Self.parse(time: item.end)
            else { return nil }
            return CalendarEvent(
                id: item.id,
                calendarID: calendarID,
                title: item.summary ?? "(No title)",
                start: start,
                end: end,
                location: item.location,
                isAllDay: isAllDay,
                eventDescription: item.description
            )
        }
    }

    private func get(_ url: URL, token: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CalendarError.httpError(0)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CalendarError.httpError(http.statusCode)
        }
        return data
    }

    private func percentEncode(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    }

    private static func parse(time: EventsResponse.Item.EventTime?) -> (Date, Bool)? {
        guard let time else { return nil }
        if let dateTime = time.dateTime, let date = DateFormatting.parseISO8601(dateTime) {
            return (date, false)
        }
        if let dateOnly = time.date {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = .current
            if let date = formatter.date(from: dateOnly) {
                return (date, true)
            }
        }
        return nil
    }

    // MARK: - Response decoding

    private struct CalendarListResponse: Decodable {
        struct Item: Decodable {
            let id: String
            let summary: String?
            let primary: Bool?
        }
        let items: [Item]
    }

    private struct EventsResponse: Decodable {
        struct Item: Decodable {
            struct EventTime: Decodable {
                let dateTime: String?
                let date: String?
            }
            let id: String
            let status: String?
            let summary: String?
            let location: String?
            let description: String?
            let start: EventTime?
            let end: EventTime?
        }
        let items: [Item]
    }
}

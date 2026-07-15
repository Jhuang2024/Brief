import Foundation

/// Everything gathered in stage 1 of the pipeline, handed to research and
/// editorial stages.
struct BriefContext {
    var now: Date
    var timezone: TimeZone
    var location: LocationService.ResolvedLocation
    var weather: WeatherSnapshot?
    var weatherFailed: Bool
    var todayEvents: [CalendarEvent]
    var weekEvents: [CalendarEvent]
    var calendarAvailable: Bool
    var preferences: UserPreferences
    var recentMemory: [StoryMemory]

    var localDateDescription: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        formatter.timeZone = timezone
        return formatter.string(from: now)
    }
}

/// Prompts, JSON schemas and response types for the OpenRouter pipeline.
enum BriefingPrompts {
    // MARK: - System prompts

    static let editorSystemPrompt = """
    You are the editor of a private morning intelligence briefing for Jerry.

    Your job is not to maximize the number of stories. Your job is to select the smallest set of developments required for Jerry to understand the day.

    Be precise, neutral, current and concise.

    Write in plain prose. Never use em dashes or en dashes in any field. Use commas, colons, parentheses, or separate sentences instead.

    Prioritize genuine developments, material changes, verified results, upcoming events and information connected to Jerry's stated interests.

    Do not include celebrity gossip, manufactured controversy, generic lifestyle content, filler, repetitive stories or conversation starters.

    Separate fact from analysis. Do not describe speculation as confirmed fact.

    Every factual story must have at least one supplied source. Never invent sources or URLs. Reference sources only by the candidate IDs supplied to you. Never supplement a candidate with a detail, score, or outcome from memory that the candidate itself doesn't state.

    The summary must state what happened. The significance section must explain why it matters rather than merely restating the headline.

    Do not alter Calendar event information or weather values supplied by the application. The application renders those values directly; you may only write the one-line practical weather note.

    If little happened in a category, return fewer stories or omit the category. Never add filler to satisfy a section count.

    Return only data matching the required JSON schema.
    """

    static let researchSystemPrompt = """
    You are a research assistant compiling raw candidate stories for a private morning intelligence briefing for Jerry.

    Use web search results to find genuine, current developments. Report only what the sources actually say. Never invent a URL, publication, quote, score, date, market price, event time, or citation. Every candidate must cite the URL of a page you actually found through search.

    Do not rely on memorized/training knowledge for any specific fact, score, or result. Your training data includes many real past events (a past season's championship result, an old product launch, a prior earnings report) that can resemble a current one. Before reporting anything as a recent development, confirm from the actual search results you received that it happened within the stated research window; if you cannot point to a search result confirming that, do not include it, even if you recall a similar-sounding event. When in doubt, omit rather than guess.

    Prefer primary and authoritative sources: government agencies, companies' official announcements, sports governing bodies, teams, universities, research institutions, established news organizations, and high-quality specialist publications. Avoid aggregation sites when an original source exists.

    Deduplicate stories that describe the same underlying event.

    Exclude celebrity gossip, influencer drama, manufactured social-media controversy, routine crime with no wider significance, opinion columns presented as news, unreliable rumours, and stories included solely because they are viral.

    Return only data matching the required JSON schema. If nothing genuinely worthwhile happened, return an empty candidates array.
    """

    // MARK: - JSON schemas (strict)

    private static let categoryValues = SectionCategory.allCases.map(\.rawValue)
    private static let statusValues = StoryStatus.allCases.map(\.rawValue)

    static var researchSchema: [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "candidates": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "id": ["type": "string", "description": "Short unique ID such as tech-1"],
                            "headline": ["type": "string"],
                            "summary": ["type": "string", "description": "2-4 factual sentences"],
                            "developmentTime": ["type": "string", "description": "ISO 8601 timestamp or date of the development"],
                            "category": ["type": "string", "enum": categoryValues],
                            "importance": ["type": "number", "description": "0-1 general importance"],
                            "relevance": ["type": "number", "description": "0-1 relevance to Jerry's interests"],
                            "sourceTitle": ["type": "string"],
                            "sourceURL": ["type": "string", "description": "URL of a page actually found via web search"],
                            "sourceDomain": ["type": "string"],
                            "confidence": ["type": "number", "description": "0-1 confidence the report is accurate"],
                            "isNew": ["type": "boolean", "description": "True if this developed in the research window"],
                            "duplicatesRecentStory": ["type": "boolean", "description": "True if this repeats a recently covered story without a material change"],
                        ],
                        "required": [
                            "id", "headline", "summary", "developmentTime", "category",
                            "importance", "relevance", "sourceTitle", "sourceURL",
                            "sourceDomain", "confidence", "isNew", "duplicatesRecentStory",
                        ],
                    ],
                ],
            ],
            "required": ["candidates"],
        ]
    }

    static var editorSchema: [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "overview": [
                    "type": "array",
                    "description": "3-6 short editorial paragraphs: the day in one minute",
                    "items": ["type": "string"],
                ],
                "practicalWeatherNote": [
                    "type": "string",
                    "description": "One literal practical line, e.g. 'Rain likely after 3 PM.' Empty string if no weather data was supplied.",
                ],
                "estimatedReadingMinutes": ["type": "integer"],
                "sections": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "category": ["type": "string", "enum": categoryValues],
                            "stories": [
                                "type": "array",
                                "items": [
                                    "type": "object",
                                    "additionalProperties": false,
                                    "properties": [
                                        "headline": ["type": "string"],
                                        "summary": ["type": "string", "description": "2-4 sentences stating what happened"],
                                        "whyItMatters": ["type": "string", "description": "Actual significance; never a restatement of the headline"],
                                        "context": ["type": "string", "description": "Fuller explanation and background for the detail view"],
                                        "developmentTime": ["type": "string", "description": "ISO 8601 timestamp or date"],
                                        "status": ["type": "string", "enum": statusValues],
                                        "importance": ["type": "number"],
                                        "relevance": ["type": "number"],
                                        "candidateIDs": [
                                            "type": "array",
                                            "description": "IDs of the supplied research candidates this story is built from",
                                            "items": ["type": "string"],
                                        ],
                                        "isUpdate": ["type": "boolean", "description": "True when this updates a recently covered story"],
                                        "whatChanged": ["type": "string", "description": "When isUpdate, what materially changed; otherwise empty"],
                                    ],
                                    "required": [
                                        "headline", "summary", "whyItMatters", "context",
                                        "developmentTime", "status", "importance", "relevance",
                                        "candidateIDs", "isUpdate", "whatChanged",
                                    ],
                                ],
                            ],
                        ],
                        "required": ["category", "stories"],
                    ],
                ],
            ],
            "required": ["overview", "practicalWeatherNote", "estimatedReadingMinutes", "sections"],
        ]
    }

    // MARK: - Research prompts

    static func researchUserPrompt(group: ResearchGroup, context: BriefContext) -> String {
        let prefs = context.preferences
        var lines: [String] = []
        lines.append("Local date and time: \(context.localDateDescription)")
        lines.append("Timezone: \(context.timezone.identifier)")
        lines.append("Research window: developments from the last 24 hours, with special attention to overnight developments. Include older context only when required to understand something new.")
        lines.append("Jerry's location: \(context.location.name)")
        lines.append("")
        lines.append(groupFocus(group, preferences: prefs))
        lines.append("")
        lines.append("Allowed category values for candidates: \(group.categories.map(\.rawValue).joined(separator: ", ")).")
        lines.append("Return at most \(prefs.researchDepth.candidateCap) candidates. Fewer is better than filler; return only genuinely worthwhile items.")

        if !prefs.preferredDomains.isEmpty {
            lines.append("Preferred domains: \(prefs.preferredDomains.joined(separator: ", ")).")
        }
        if !prefs.excludedDomains.isEmpty {
            lines.append("Never use these domains as sources: \(prefs.excludedDomains.joined(separator: ", ")).")
        }
        if prefs.preferOfficialSources {
            lines.append("Prefer official and primary sources whenever one exists.")
        }
        if prefs.requireMultipleSourcesForBreaking {
            lines.append("For major breaking claims, look for corroboration from more than one credible source; lower your confidence score when only one source exists.")
        }
        if !prefs.excludedKeywords.isEmpty {
            lines.append("Suppress stories about: \(prefs.excludedKeywords.joined(separator: ", ")).")
        }

        let recentHeadlines = context.recentMemory.map(\.headline).prefix(40)
        if !recentHeadlines.isEmpty {
            lines.append("")
            lines.append("Recently covered headlines (mark duplicatesRecentStory=true when a candidate repeats one of these without a material new development):")
            lines.append(contentsOf: recentHeadlines.map { "- \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    private static func groupFocus(_ group: ResearchGroup, preferences prefs: UserPreferences) -> String {
        switch group {
        case .worldPolitics:
            return """
            Focus: major world news; the United States; Canada; China; geopolitics; major public-policy changes. \
            Only include developments of genuine consequence.
            """
        case .businessMarkets:
            return """
            Focus: business; financial markets and major market movements; major companies; acquisitions; \
            semiconductors; significant financial developments. \
            Companies Jerry follows: \(prefs.companies.joined(separator: ", ")).
            """
        case .technology:
            return """
            Focus: technology; artificial intelligence; OpenAI; Anthropic; Google; Apple; Nvidia; startups; \
            venture capital; data-centre infrastructure; computing energy use; electricity grids. \
            Topics Jerry follows: \(prefs.topics.joined(separator: ", ")). \
            Categorize AI/consumer-tech stories as technology_ai and startup/data-centre/computing-infrastructure stories as computing_infrastructure.
            """
        case .formulaOne:
            return """
            Focus: Formula 1. First determine the current phase: normal week, race week, sprint weekend, \
            qualifying day, race day, the day after a race, or the off-season. \
            During a race weekend prioritize the session schedule (report session times in UTC or with an explicit timezone), \
            completed-session results, grid penalties, weather developments, major technical or team news, and championship implications. \
            The day after a race prioritize the result, major incidents, strategy, penalties, championship movement, and material post-race developments. \
            During an ordinary week do NOT fill the section with rumours; return only genuine news, or nothing. \
            Jerry follows: \(prefs.f1DriversAndTeams.joined(separator: ", ")). Never fabricate a result or session time.
            """
        case .sports:
            let interests = (prefs.sportsLeagues + prefs.sportsTeams + prefs.athletes)
                .filter { $0.lowercased() != "formula 1" }
            let spoilerRule = prefs.spoilersEnabled
                ? ""
                : " Jerry has spoilers disabled: keep final scores out of headlines and lead with the matchup instead."
            return """
            Focus: sports Jerry follows: \(interests.isEmpty ? "major US and Canadian sports" : interests.joined(separator: ", ")). \
            Prioritize final scores from the previous evening, games today, playoff implications, major trades, \
            serious injuries, significant records, and major disciplinary decisions. \
            Skip routine transactions. For every game make clear whether it is final, scheduled, live, postponed or cancelled. \
            Never fabricate a score. Exclude Formula 1 (covered separately).\(spoilerRule)
            """
        case .berkeley:
            return """
            Focus: UC Berkeley. Official Berkeley announcements, campus news, academic-calendar dates, \
            operational notices (transportation, closures, campus access), and major university developments. \
            Prefer official Berkeley domains (berkeley.edu, news.berkeley.edu) and the Daily Californian for administrative information. \
            Prioritize information that could affect a student's day, classes, deadlines, or academic planning. \
            Do not present generic promotional university content as important news.
            """
        }
    }

    // MARK: - Editor prompt

    static func editorUserPrompt(
        context: BriefContext,
        packets: [ResearchPacket],
        failedGroups: [ResearchGroup]
    ) -> String {
        let prefs = context.preferences
        var lines: [String] = []

        lines.append("Local date and time: \(context.localDateDescription)")
        lines.append("Timezone: \(context.timezone.identifier)")
        lines.append("Location: \(context.location.name)")
        lines.append("Research window: the last 24 hours before the time above.")
        lines.append("")

        // Enabled sections and limits.
        lines.append("Enabled sections, in order, with hard maximum story counts (maximums, not quotas: if only one story is genuinely worthwhile, return one; if none, omit the section):")
        for section in prefs.enabledSections {
            lines.append("- \(section.category.rawValue) (\"\(section.title)\"): max \(prefs.effectiveMaxStories(for: section.category)) stories")
        }
        lines.append("Overview: at most 6 items. Target total reading time: about \(prefs.maxReadingMinutes) minutes (length preference: \(prefs.briefLength.rawValue)).")
        if !prefs.includeWhyItMatters {
            lines.append("Jerry has disabled 'Why it matters'; keep those fields to one short sentence.")
        }
        lines.append("")

        // Weather (numbers rendered by the app; model writes only the note).
        if let weather = context.weather {
            lines.append("""
            Weather (from Open-Meteo; the app renders these numbers directly: do not restate or alter them, \
            only write practicalWeatherNote as one literal line such as "Rain likely after 3 PM." or "No rain expected."):
            \(weatherJSON(weather))
            """)
        } else {
            lines.append("Weather data is unavailable today. Return an empty practicalWeatherNote.")
        }
        lines.append("")

        // Calendar.
        if context.calendarAvailable {
            lines.append("Today's Google Calendar events (already faithful to Google Calendar; do not alter, and use only for the overview's sense of Jerry's day):")
            lines.append(calendarJSON(context.todayEvents, includeDescriptions: prefs.sendEventDescriptions))
            if !context.weekEvents.isEmpty {
                lines.append("Upcoming events this week (context only):")
                lines.append(calendarJSON(Array(context.weekEvents.prefix(15)), includeDescriptions: false))
            }
        } else if prefs.includeCalendar {
            lines.append("Google Calendar is unavailable today; do not invent events.")
        }
        lines.append("")

        // Recent memory.
        if !context.recentMemory.isEmpty {
            lines.append("""
            Stories covered in the previous seven days. Repeat one only when there is a material new development, \
            a result is now final, a decision has been announced, new numbers materially change the situation, \
            or it directly affects today. When repeating, set isUpdate=true and state what changed in whatChanged:
            """)
            for memory in context.recentMemory.prefix(60) {
                lines.append("- [\(DateFormatting.shortDate.string(from: memory.briefingDate))] \(memory.headline): \(memory.summary)")
            }
            lines.append("")
        }

        if !failedGroups.isEmpty {
            lines.append("Note: research for \(failedGroups.map(\.displayName).joined(separator: ", ")) failed; those sections have no candidates. Omit them rather than inventing content.")
            lines.append("")
        }

        // Candidates.
        lines.append("""
        Research candidates follow, grouped by research request. Build every story only from these candidates and \
        reference them via candidateIDs; never introduce a fact, score, quote, or result that isn't in a supplied \
        candidate. If a topic has no candidate covering it, omit that story entirely rather than filling it in from \
        memory. Deduplicate candidates describing the same underlying event into a single story citing multiple \
        candidateIDs.
        """)
        for packet in packets {
            lines.append("## \(packet.group.displayName)")
            lines.append(candidatesJSON(packet.candidates))
        }

        lines.append("")
        lines.append("""
        Produce the briefing now. The overview is a concise editorial "day in one minute" answering: what materially happened, \
        what changed, and what is likely to matter today, including, briefly, Jerry's schedule and anything time-sensitive. \
        It is not a list of conversation starters.
        """)
        return lines.joined(separator: "\n")
    }

    /// Prompt for one repair attempt after invalid structured output.
    static func repairPrompt(originalContent: String, decodeError: String) -> String {
        """
        The JSON below was produced for the daily_brief schema but failed to decode with this error:
        \(decodeError)

        Return the same content corrected to exactly match the required JSON schema. \
        Do not add new stories or change factual content; only repair the structure.

        Original JSON:
        \(originalContent)
        """
    }

    // MARK: - JSON helpers

    private static func weatherJSON(_ weather: WeatherSnapshot) -> String {
        let object: [String: Any] = [
            "location": weather.locationName,
            "temperature": weather.temperature,
            "apparentTemperature": weather.apparentTemperature,
            "high": weather.high,
            "low": weather.low,
            "precipitationProbabilityPercent": weather.precipitationProbability,
            "condition": weather.conditionDescription,
            "windSpeed": weather.windSpeed,
            "unit": weather.unitSymbol,
        ]
        return jsonString(object)
    }

    private static func calendarJSON(_ events: [CalendarEvent], includeDescriptions: Bool) -> String {
        let array = events.map { event -> [String: Any] in
            var object: [String: Any] = [
                "title": event.title,
                "start": DateFormatting.rfc3339(event.start),
                "end": DateFormatting.rfc3339(event.end),
                "isAllDay": event.isAllDay,
            ]
            if let location = event.location { object["location"] = location }
            if includeDescriptions, let description = event.eventDescription {
                object["description"] = String(description.prefix(280))
            }
            return object
        }
        return jsonString(array)
    }

    private static func candidatesJSON(_ candidates: [CandidateStory]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(candidates) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func jsonString(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Response payloads

struct ResearchResponse: Decodable {
    var candidates: [CandidateStory]
}

struct EditorResponse: Decodable {
    struct Section: Decodable {
        var category: String
        var stories: [Story]
    }

    struct Story: Decodable {
        var headline: String
        var summary: String
        var whyItMatters: String
        var context: String
        var developmentTime: String
        var status: String
        var importance: Double
        var relevance: Double
        var candidateIDs: [String]
        var isUpdate: Bool
        var whatChanged: String
    }

    var overview: [String]
    var practicalWeatherNote: String
    var estimatedReadingMinutes: Int
    var sections: [Section]
}

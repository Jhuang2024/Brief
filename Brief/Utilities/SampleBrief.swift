#if DEBUG
import Foundation

/// A realistic sample briefing for SwiftUI previews and the debug-only
/// "Load sample briefing" button — so the interface can be exercised
/// without spending OpenRouter credits. Never used in release builds.
enum SampleBrief {
    @MainActor
    static func insertSample(into store: BriefStore) {
        store.save(make())
    }

    static func make(now: Date = Date()) -> DailyBrief {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)

        func at(_ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(byAdding: DateComponents(hour: hour, minute: minute), to: dayStart) ?? now
        }

        let weather = WeatherSnapshot(
            locationName: "Berkeley, CA",
            latitude: 37.8715,
            longitude: -122.2730,
            temperature: 57,
            apparentTemperature: 55,
            high: 68,
            low: 52,
            precipitationProbability: 10,
            conditionCode: 2,
            windSpeed: 8,
            sunrise: at(5, 58),
            sunset: at(20, 32),
            unitSymbol: "°F",
            practicalNote: "Cool morning, warmer afternoon. No rain expected."
        )

        let events = [
            CalendarEvent(
                id: "sample-1", calendarID: "primary", title: "CS 189 Lecture",
                start: at(10), end: at(11, 30), location: "Dwinelle 155", isAllDay: false
            ),
            CalendarEvent(
                id: "sample-2", calendarID: "primary", title: "Office hours — ML project",
                start: at(14), end: at(15), location: "Soda 405", isAllDay: false
            ),
            CalendarEvent(
                id: "sample-3", calendarID: "primary", title: "Problem set 6 due",
                start: dayStart, end: calendar.date(byAdding: .day, value: 1, to: dayStart) ?? now,
                location: nil, isAllDay: true
            ),
        ]

        func source(_ title: String, _ domain: String, _ path: String) -> BriefSource {
            BriefSource(
                title: title,
                domain: domain,
                urlString: "https://\(domain)/\(path)",
                publishedAt: calendar.date(byAdding: .hour, value: -7, to: now),
                sourceType: SourceType.classify(domain: domain)
            )
        }

        func story(
            _ headline: String, _ summary: String, _ why: String,
            context: String = "", status: StoryStatus = .none,
            importance: Double, order: Int, sources: [BriefSource],
            category: String
        ) -> BriefStory {
            BriefStory(
                fingerprint: Fingerprint.make(
                    headline: headline,
                    sourceURL: sources.first?.urlString,
                    entities: Fingerprint.entities(from: headline),
                    category: category
                ),
                headline: headline,
                summary: summary,
                whyItMatters: why,
                context: context,
                developmentDate: calendar.date(byAdding: .hour, value: -8, to: now),
                status: status,
                importanceScore: importance,
                relevanceScore: importance,
                order: order,
                sources: sources
            )
        }

        let world = BriefSection(category: .world, title: "World", order: 0, stories: [
            story(
                "EU and Indonesia conclude decade-long trade negotiation",
                "Negotiators announced a completed free-trade agreement overnight after ten years of talks, covering roughly €30 billion in annual trade. Ratification votes are expected in the fall.",
                "It reshapes supply-chain options for European manufacturers in Southeast Asia and signals renewed EU appetite for bilateral deals while broader WTO reform stays stalled.",
                context: "Talks began in 2016 and repeatedly stalled over palm oil and nickel export rules. The final text drops the EU's proposed deforestation certification in favour of a joint monitoring body.",
                status: .developing, importance: 0.8, order: 0,
                sources: [source("EU, Indonesia finalise trade pact", "reuters.com", "world/eu-indonesia-trade")],
                category: "world"
            ),
            story(
                "Overnight storm system disrupts eastern Canada power grid",
                "High winds left about 400,000 customers without power across Ontario and Québec early this morning. Utilities expect most restoration by tomorrow evening.",
                "Beyond the outages, it revives the federal debate over grid-hardening funds that stalled in committee last month.",
                status: .developing, importance: 0.6, order: 1,
                sources: [source("Storm knocks out power across Ontario", "cbc.ca", "news/canada/storm-outages")],
                category: "world"
            ),
        ])

        let tech = BriefSection(category: .technologyAI, title: "Technology & AI", order: 1, stories: [
            story(
                "Anthropic publishes interpretability results for production-scale models",
                "The company released research tracing safety-relevant features in a frontier model, together with tooling it says it now runs on production systems. The paper and code went out overnight.",
                "If feature-level auditing works at production scale, it changes what regulators can reasonably ask of frontier labs — and gives safety teams a concrete artifact to standardize around.",
                context: "This extends the dictionary-learning line of work from 2024–25. The notable claim is operational use, not just a lab demo.",
                status: .official, importance: 0.9, order: 0,
                sources: [source("Interpretability at scale", "anthropic.com", "research/interpretability-scale")],
                category: "technology_ai"
            ),
            story(
                "Nvidia signals supply easing for latest data-centre GPUs",
                "In remarks accompanying a partner event, Nvidia said lead times for its current data-centre generation have fallen to under three months, with volume ramps at two additional packaging sites.",
                "Shorter lead times lower the barrier for smaller AI labs and cloud challengers, and take pressure off the spot-rental market that startups depend on.",
                status: .developing, importance: 0.75, order: 1,
                sources: [source("Nvidia supply update", "nvidia.com", "newsroom/supply-update")],
                category: "technology_ai"
            ),
        ])

        let f1 = BriefSection(category: .formulaOne, title: "Formula 1", order: 2, stories: [
            story(
                "British GP week: Friday practice schedule confirmed",
                "Formula 1 confirmed the Silverstone weekend timetable. FP1 runs Friday 4:30 AM PT, FP2 at 8:00 AM PT, with qualifying Saturday 7:00 AM PT.",
                "McLaren brings its last major aero package of the season; Piastri arrives leading the championship by 14 points, so Saturday's single-lap pace matters more than usual.",
                context: "Silverstone has favoured high-downforce cars this season. Ferrari's upgrade from Austria showed race-pace gains but qualifying remains its weakness.",
                status: .schedule, importance: 0.8, order: 0,
                sources: [source("Silverstone session times", "formula1.com", "en/latest/silverstone-schedule")],
                category: "formula_one"
            ),
        ])

        let berkeley = BriefSection(category: .berkeley, title: "UC Berkeley", order: 3, stories: [
            story(
                "Moffitt Library extends hours through finals prep week",
                "The library announced 24-hour access starting Monday, with the main stacks unaffected. Card access applies after 10 PM.",
                "Useful if the ML project runs long — it's the closest 24-hour study space to north side this month.",
                status: .official, importance: 0.5, order: 0,
                sources: [source("Moffitt hours notice", "berkeley.edu", "library/moffitt-hours")],
                category: "berkeley"
            ),
        ])

        return DailyBrief(
            briefingDate: dayStart,
            generatedAt: calendar.date(byAdding: .minute, value: -20, to: now) ?? now,
            timezoneIdentifier: TimeZone.current.identifier,
            locationName: "Berkeley, CA",
            overviewItems: [
                "A quiet overnight globally, with one exception: the EU–Indonesia trade agreement finally closed after ten years, and ratification now moves to parliaments this fall.",
                "In AI, Anthropic's interpretability release is the story that matters — it claims production-scale feature auditing, which shifts the safety-regulation conversation from theory to tooling.",
                "Nvidia says data-centre GPU lead times are under three months; cheaper, faster compute access ripples through every startup budget you follow.",
                "F1 is back this weekend at Silverstone. Practice starts Friday early morning Pacific time, and Piastri defends a 14-point lead.",
                "Your day: CS 189 at 10, office hours at 2, and the problem set is due tonight. Cool morning, warmer afternoon, no rain expected.",
            ],
            sections: [world, tech, f1, berkeley],
            calendarEvents: events,
            calendarWasAvailable: true,
            weather: weather,
            estimatedReadingMinutes: 5,
            status: .complete,
            researchModel: "openrouter/auto",
            editorModel: "sample/editor",
            inputTokens: 18_400,
            outputTokens: 4_200,
            generationDuration: 74
        )
    }
}
#endif

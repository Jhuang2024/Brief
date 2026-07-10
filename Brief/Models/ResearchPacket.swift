import Foundation

/// The concurrent research requests run in stage 2 of the pipeline.
enum ResearchGroup: String, Codable, CaseIterable, Identifiable {
    case worldPolitics = "world_politics"
    case businessMarkets = "business_markets"
    case technology = "technology"
    case formulaOne = "formula_one"
    case sports = "sports"
    case berkeley = "berkeley"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .worldPolitics: return "World news"
        case .businessMarkets: return "Business & markets"
        case .technology: return "Technology & AI"
        case .formulaOne: return "Formula 1"
        case .sports: return "Sports"
        case .berkeley: return "UC Berkeley"
        }
    }

    /// Section categories this research group is allowed to produce candidates for.
    var categories: [SectionCategory] {
        switch self {
        case .worldPolitics: return [.world, .usCanadaChina, .worthKnowing]
        case .businessMarkets: return [.businessMarkets, .worthKnowing]
        case .technology: return [.technologyAI, .computingInfrastructure, .worthKnowing]
        case .formulaOne: return [.formulaOne]
        case .sports: return [.sports]
        case .berkeley: return [.berkeley]
        }
    }
}

/// One normalized candidate story returned by a research request.
struct CandidateStory: Codable, Identifiable, Hashable {
    var id: String
    var headline: String
    var summary: String
    /// ISO 8601 timestamp of the development, as reported by the model.
    var developmentTime: String
    var category: String
    /// 0–1, general importance.
    var importance: Double
    /// 0–1, relevance to Jerry's stated interests.
    var relevance: Double
    var sourceTitle: String
    var sourceURL: String
    var sourceDomain: String
    /// 0–1, the model's confidence the story is accurate.
    var confidence: Double
    var isNew: Bool
    var duplicatesRecentStory: Bool
    /// Set by the app: whether `sourceURL` appeared in OpenRouter's
    /// citation annotations for the request that produced it.
    var citationVerified: Bool?

    var developmentDate: Date? {
        DateFormatting.parseISO8601(developmentTime)
    }
}

/// The result of one research request, kept for the editor stage.
struct ResearchPacket: Codable {
    var group: ResearchGroup
    var candidates: [CandidateStory]
    /// Every URL OpenRouter actually cited for this request.
    var citedURLs: [String]
    var modelUsed: String
    var inputTokens: Int
    var outputTokens: Int
    var duration: TimeInterval
}

/// Fingerprint memory sent to the editor so stories are not repeated
/// without a material development.
struct StoryMemory: Codable {
    var fingerprint: String
    var headline: String
    var summary: String
    var briefingDate: Date
}

/// Diagnostics for the most recent generation, exportable from Settings.
/// Never contains the OpenRouter key or Google tokens.
struct GenerationDiagnostics: Codable {
    struct StepRecord: Codable {
        var name: String
        var succeeded: Bool
        var detail: String
        var duration: TimeInterval
    }

    var startedAt: Date
    var finishedAt: Date?
    var trigger: String
    var researchModel: String
    var editorModel: String
    var steps: [StepRecord] = []
    var totalInputTokens: Int = 0
    var totalOutputTokens: Int = 0
    var candidateCount: Int = 0
    var storyCount: Int = 0
    var validationNotes: [String] = []
    var errors: [String] = []
    var status: String = "running"

    func exportJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

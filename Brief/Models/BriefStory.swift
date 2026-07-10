import Foundation
import SwiftData

enum StoryStatus: String, Codable, CaseIterable {
    case none
    case breaking
    case developing
    case result
    case schedule
    case analysis
    case official

    var label: String? {
        switch self {
        case .none: return nil
        case .breaking: return "Breaking"
        case .developing: return "Developing"
        case .result: return "Result"
        case .schedule: return "Schedule"
        case .analysis: return "Analysis"
        case .official: return "Official"
        }
    }
}

/// One story inside a briefing section.
@Model
final class BriefStory {
    @Attribute(.unique) var id: UUID
    /// Stable fingerprint used for recent-story deduplication across days.
    var fingerprint: String
    var headline: String
    var summary: String
    var whyItMatters: String
    /// Extra context shown in the detail view.
    var context: String
    var developmentDate: Date?
    var statusRaw: String
    var importanceScore: Double
    var relevanceScore: Double
    /// True when this repeats a recently covered story because of a material change.
    var isUpdate: Bool
    var whatChanged: String
    var order: Int
    var section: BriefSection?
    @Relationship(deleteRule: .cascade, inverse: \BriefSource.story)
    var sources: [BriefSource]

    init(
        id: UUID = UUID(),
        fingerprint: String,
        headline: String,
        summary: String,
        whyItMatters: String,
        context: String = "",
        developmentDate: Date? = nil,
        status: StoryStatus = .none,
        importanceScore: Double = 0.5,
        relevanceScore: Double = 0.5,
        isUpdate: Bool = false,
        whatChanged: String = "",
        order: Int = 0,
        sources: [BriefSource] = []
    ) {
        self.id = id
        self.fingerprint = fingerprint
        self.headline = headline
        self.summary = summary
        self.whyItMatters = whyItMatters
        self.context = context
        self.developmentDate = developmentDate
        self.statusRaw = status.rawValue
        self.importanceScore = importanceScore
        self.relevanceScore = relevanceScore
        self.isUpdate = isUpdate
        self.whatChanged = whatChanged
        self.order = order
        self.sources = sources
    }
}

extension BriefStory {
    var status: StoryStatus {
        StoryStatus(rawValue: statusRaw) ?? .none
    }

    var orderedSources: [BriefSource] {
        sources.sorted { $0.title < $1.title }
    }
}

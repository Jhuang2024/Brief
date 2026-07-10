import Foundation
import SwiftData

/// The fixed set of briefing categories. Titles and limits are editable in Settings.
enum SectionCategory: String, Codable, CaseIterable, Identifiable {
    case world = "world"
    case usCanadaChina = "us_canada_china"
    case businessMarkets = "business_markets"
    case technologyAI = "technology_ai"
    case computingInfrastructure = "computing_infrastructure"
    case formulaOne = "formula_one"
    case sports = "sports"
    case berkeley = "berkeley"
    case worthKnowing = "worth_knowing"

    var id: String { rawValue }

    var defaultTitle: String {
        switch self {
        case .world: return "World"
        case .usCanadaChina: return "U.S., Canada & China"
        case .businessMarkets: return "Business & Markets"
        case .technologyAI: return "Technology & AI"
        case .computingInfrastructure: return "Startups, Computing & Data Centres"
        case .formulaOne: return "Formula 1"
        case .sports: return "Sports"
        case .berkeley: return "UC Berkeley"
        case .worthKnowing: return "Worth Knowing"
        }
    }

    var defaultMaxStories: Int {
        switch self {
        case .world: return 4
        case .usCanadaChina: return 4
        case .businessMarkets: return 4
        case .technologyAI: return 5
        case .computingInfrastructure: return 3
        case .formulaOne: return 4
        case .sports: return 4
        case .berkeley: return 3
        case .worthKnowing: return 3
        }
    }

    var defaultOrder: Int {
        SectionCategory.allCases.firstIndex(of: self) ?? 0
    }

    /// Which research request feeds this section.
    var researchGroup: ResearchGroup? {
        switch self {
        case .world, .usCanadaChina: return .worldPolitics
        case .businessMarkets: return .businessMarkets
        case .technologyAI, .computingInfrastructure: return .technology
        case .formulaOne: return .formulaOne
        case .sports: return .sports
        case .berkeley: return .berkeley
        case .worthKnowing: return nil // fed by every research group
        }
    }
}

/// One rendered section of a saved briefing.
@Model
final class BriefSection {
    @Attribute(.unique) var id: UUID
    var categoryRaw: String
    var title: String
    var order: Int
    var brief: DailyBrief?
    @Relationship(deleteRule: .cascade, inverse: \BriefStory.section)
    var stories: [BriefStory]

    init(
        id: UUID = UUID(),
        category: SectionCategory,
        title: String,
        order: Int,
        stories: [BriefStory] = []
    ) {
        self.id = id
        self.categoryRaw = category.rawValue
        self.title = title
        self.order = order
        self.stories = stories
    }
}

extension BriefSection {
    var category: SectionCategory {
        SectionCategory(rawValue: categoryRaw) ?? .worthKnowing
    }

    var orderedStories: [BriefStory] {
        stories.sorted { $0.order < $1.order }
    }
}

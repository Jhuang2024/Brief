import Foundation
import SwiftData

enum SourceType: String, Codable, CaseIterable {
    case official
    case news
    case specialist
    case university
    case sportsBody
    case other

    /// Rough classification from a domain, used for display only.
    static func classify(domain: String) -> SourceType {
        let d = domain.lowercased()
        if d.hasSuffix(".gov") || d.hasSuffix(".gc.ca") { return .official }
        if d.hasSuffix(".edu") || d.contains("berkeley.edu") { return .university }
        if d.contains("fia.com") || d.contains("formula1.com") || d.contains("nba.com")
            || d.contains("nfl.com") || d.contains("mlb.com") || d.contains("nhl.com") {
            return .sportsBody
        }
        let officialCompanies = [
            "apple.com", "openai.com", "anthropic.com", "blog.google", "nvidia.com",
            "microsoft.com", "meta.com", "deepmind.google",
        ]
        if officialCompanies.contains(where: { d.hasSuffix($0) }) { return .official }
        return .news
    }
}

/// A cited source attached to a story. URLs are validated against
/// OpenRouter citation annotations before they are persisted.
@Model
final class BriefSource {
    @Attribute(.unique) var id: UUID
    var title: String
    var domain: String
    var urlString: String
    var publishedAt: Date?
    var sourceTypeRaw: String
    var story: BriefStory?

    init(
        id: UUID = UUID(),
        title: String,
        domain: String,
        urlString: String,
        publishedAt: Date? = nil,
        sourceType: SourceType = .news
    ) {
        self.id = id
        self.title = title
        self.domain = domain
        self.urlString = urlString
        self.publishedAt = publishedAt
        self.sourceTypeRaw = sourceType.rawValue
    }
}

extension BriefSource {
    var sourceType: SourceType {
        SourceType(rawValue: sourceTypeRaw) ?? .news
    }

    var url: URL? {
        URL(string: urlString)
    }
}

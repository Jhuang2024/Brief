import Foundation
import SwiftData

/// A single, rare, out-of-cycle alert surfaced by the hourly breaking
/// check, reserved for something genuinely urgent enough to interrupt
/// Jerry's day, not the routine news the daily brief already covers.
@Model
final class BreakingAlert {
    @Attribute(.unique) var id: UUID
    var fingerprint: String
    var headline: String
    var summary: String
    var whyItMatters: String
    var sourceTitle: String
    var sourceDomain: String
    var sourceURLString: String
    var detectedAt: Date
    var isRead: Bool

    init(
        id: UUID = UUID(),
        fingerprint: String,
        headline: String,
        summary: String,
        whyItMatters: String,
        sourceTitle: String,
        sourceDomain: String,
        sourceURLString: String,
        detectedAt: Date = Date(),
        isRead: Bool = false
    ) {
        self.id = id
        self.fingerprint = fingerprint
        self.headline = headline
        self.summary = summary
        self.whyItMatters = whyItMatters
        self.sourceTitle = sourceTitle
        self.sourceDomain = sourceDomain
        self.sourceURLString = sourceURLString
        self.detectedAt = detectedAt
        self.isRead = isRead
    }

    var sourceURL: URL? { URL(string: sourceURLString) }
}

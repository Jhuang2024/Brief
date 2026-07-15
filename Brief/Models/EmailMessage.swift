import Foundation

/// One inbox message shown in the brief's Email section, faithful to what
/// Gmail returned: sender, subject, Gmail's own snippet, and read state.
/// Persisted on `DailyBrief` as a JSON blob (like calendar events and
/// weather), and rendered verbatim - email content is never sent to any AI
/// provider.
struct EmailMessage: Codable, Equatable, Identifiable {
    var id: String
    /// The sender's display name, falling back to the address when the
    /// From header carries no name.
    var fromName: String
    var fromAddress: String
    var subject: String
    /// Gmail's short plain-text preview of the body.
    var snippet: String
    var receivedAt: Date
    var isUnread: Bool
}

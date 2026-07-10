import Foundation

/// Shared formatters. Formatter creation is expensive, so they are built once.
enum DateFormatting {
    /// "Friday, July 10"
    static let mastheadDate: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        return f
    }()

    /// "Friday, July 10, 2026"
    static let fullDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .none
        return f
    }()

    /// "7:42 AM"
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    /// "Jul 10"
    static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    private static let isoWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoDateOnly: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        f.timeZone = .current
        return f
    }()

    /// Tolerant ISO 8601 parsing for model-supplied and API timestamps.
    static func parseISO8601(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return iso.date(from: trimmed)
            ?? isoWithFractional.date(from: trimmed)
            ?? isoDateOnly.date(from: trimmed)
    }

    static func rfc3339(_ date: Date) -> String {
        iso.string(from: date)
    }

    /// "in 2h 15m", "in 45m", "now", "started"
    static func countdown(to date: Date, from now: Date = Date()) -> String {
        let interval = date.timeIntervalSince(now)
        if interval < -60 { return "started" }
        if interval < 60 { return "now" }
        let totalMinutes = Int(interval / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return "in \(minutes)m" }
        if hours < 24 { return minutes == 0 ? "in \(hours)h" : "in \(hours)h \(minutes)m" }
        let days = hours / 24
        return "in \(days)d"
    }

    /// "just now", "12 min ago", "2 hours ago", "yesterday"
    static func relativePast(_ date: Date, from now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 90 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60)) min ago" }
        if interval < 24 * 3600 {
            let hours = Int(interval / 3600)
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        }
        if Calendar.current.isDateInYesterday(date) { return "yesterday" }
        return shortDate.string(from: date)
    }

    /// Time-of-day appropriate greeting.
    static func greeting(for date: Date = Date()) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 4..<12: return "Good morning, Jerry"
        case 12..<17: return "Good afternoon, Jerry"
        case 17..<22: return "Good evening, Jerry"
        default: return "Up late, Jerry"
        }
    }
}

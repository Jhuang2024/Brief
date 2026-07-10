import CryptoKit
import Foundation

/// Builds stable story fingerprints for recent-story memory.
enum Fingerprint {
    /// Lowercased alphanumerics and single spaces only.
    static func normalizeHeadline(_ headline: String) -> String {
        let lowered = headline.lowercased()
        let filtered = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            return " "
        }
        return String(filtered)
            .split(separator: " ")
            .joined(separator: " ")
    }

    /// Fingerprint from normalized headline, canonical URL, entities and category.
    static func make(headline: String, sourceURL: String?, entities: [String], category: String) -> String {
        let parts = [
            normalizeHeadline(headline),
            sourceURL.map(URLValidation.canonicalize) ?? "",
            entities.map { $0.lowercased() }.sorted().joined(separator: ","),
            category,
        ]
        let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
        return digest.map { String(format: "%02x", $0) }.prefix(16).joined()
    }

    /// Crude named-entity pull: capitalized words of 3+ characters.
    static func entities(from text: String) -> [String] {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
        let candidates = words.compactMap { word -> String? in
            guard word.count >= 3, let first = word.first, first.isUppercase else { return nil }
            return String(word)
        }
        return Array(Set(candidates)).sorted().prefix(8).map { $0 }
    }
}

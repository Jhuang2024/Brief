import Foundation

/// URL hygiene for model-supplied sources.
enum URLValidation {
    /// A URL is plausible when it is http(s) and has a real-looking host.
    static func isPlausible(_ string: String) -> Bool {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              host.contains("."),
              !host.hasSuffix(".")
        else { return false }
        return true
    }

    /// Canonical form used for deduplication: lowercase host, no scheme
    /// difference, no tracking params, no fragment, no trailing slash.
    static func canonicalize(_ string: String) -> String {
        guard var components = URLComponents(string: string) else {
            return string.lowercased()
        }
        components.scheme = "https"
        components.host = components.host?.lowercased()
        components.fragment = nil
        let trackingPrefixes = ["utm_", "fbclid", "gclid", "ref", "cmpid", "ito"]
        components.queryItems = components.queryItems?.filter { item in
            !trackingPrefixes.contains { item.name.lowercased().hasPrefix($0) }
        }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        var path = components.path
        if path.hasSuffix("/") && path.count > 1 { path.removeLast() }
        components.path = path
        return components.string ?? string.lowercased()
    }

    static func domain(of string: String) -> String {
        guard let host = URL(string: string)?.host?.lowercased() else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// True when `candidate` matches one of the cited URLs, compared canonically
    /// or by domain + significant path overlap. Domain alone is deliberately
    /// NOT enough: a model can fabricate a plausible-looking article on a
    /// domain that genuinely was cited for a completely different, unrelated
    /// (and possibly stale, memorized-from-training) story. Requiring the
    /// last meaningful path segment to also match means the candidate has to
    /// point at the same article the search actually returned, not just the
    /// same publication.
    static func matchesCitations(_ candidate: String, citations: [String]) -> Bool {
        let canonical = canonicalize(candidate)
        let candidateDomain = domain(of: candidate)
        let candidateSlug = significantPathSegment(of: candidate)
        for cited in citations {
            if canonicalize(cited) == canonical { return true }
            if !candidateDomain.isEmpty, domain(of: cited) == candidateDomain,
               let candidateSlug, candidateSlug == significantPathSegment(of: cited) {
                return true
            }
        }
        return false
    }

    /// Last non-empty path component, a proxy for "which article" on a
    /// domain. Nil for a bare domain/root URL, which never counts as a
    /// meaningful match on its own.
    private static func significantPathSegment(of urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        return url.pathComponents.filter { $0 != "/" && !$0.isEmpty }.last
    }
}

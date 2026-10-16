import Foundation
import CoreFoundation

/// Public release settings only. The Ed25519 private signing key never belongs in the app.
struct NativeAppUpdateConfiguration: Equatable, Sendable {
    let feedURL: URL
    let publicEDKey: String

    /// Missing settings mean an unconfigured build; partial or invalid settings are errors.
    static func read(info: [String: Any]) throws -> Self? {
        if info["SUFeedURL"] == nil && info["SUPublicEDKey"] == nil { return nil }
        guard let feed = info["SUFeedURL"] as? String, !feed.isEmpty else {
            throw ConfigurationError.missingFeed
        }
        guard let key = info["SUPublicEDKey"] as? String, !key.isEmpty else {
            throw ConfigurationError.missingPublicKey
        }
        let url = try validatedFeedURL(feed)
        // Require canonical, padded base64. Do not silently ignore whitespace or bad pad bits.
        guard let bytes = Data(base64Encoded: key), bytes.count == 32,
              bytes.base64EncodedString() == key else {
            throw ConfigurationError.invalidPublicKey
        }
        return Self(feedURL: url, publicEDKey: key)
    }

    private static func validatedFeedURL(_ feed: String) throws -> URL {
        // URLComponents may repair spaces and invalid percent escapes. Release settings must
        // already be a well-formed absolute URL, without credentials or query-string secrets.
        guard feed.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }),
              !feed.contains("\\"),
              let components = URLComponents(string: feed),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              let host = components.host?.lowercased(),
              let url = components.url, url.absoluteString == feed,
              let decoded = feed.removingPercentEncoding,
              decoded.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }),
              !decoded.contains("\\") else {
            throw ConfigurationError.invalidFeed
        }

        // Use a public DNS name, rather than a local machine, IP literal, or unresolved template.
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        guard host.count <= 253, labels.count >= 2,
              labels.allSatisfy({ label in
                  !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                      && label.allSatisfy({ allowed.contains($0) })
              }),
              labels.last?.contains(where: { $0.isLetter }) == true else {
            throw ConfigurationError.invalidFeed
        }

        let reserved = ["example.com", "example.net", "example.org", "example", "invalid", "test", "localhost", "local"]
        let lower = decoded.lowercased()
        let tokens = Set(lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let placeholders: Set<String> = ["placeholder", "changeme", "todo", "yourdomain", "yourhost", "yourusername", "yourrepo", "your"]
        guard !reserved.contains(where: { host == $0 || host.hasSuffix("." + $0) }),
              !lower.contains(where: { "<>{}[]$".contains($0) }),
              !lower.contains("__"), !lower.contains("replace-me"), !lower.contains("replace_me"),
              tokens.isDisjoint(with: placeholders) else {
            throw ConfigurationError.placeholderFeed
        }

        // This native host is a separate product. The upstream repository's releases must
        // never be offered as its updates, including GitHub API/raw/Pages feed variants.
        let path = (components.percentEncodedPath.removingPercentEncoding ?? "").lowercased()
        var segments: [Substring] = []
        for segment in path.split(separator: "/") {
            if segment == "." { continue }
            if segment == ".." { _ = segments.popLast() }
            else { segments.append(segment) }
        }
        let upstreamRepository = zip(segments, segments.dropFirst()).contains {
            $0.0 == "timschneeb" && ($0.1 == "galaxybudsclient" || $0.1 == "galaxybudsclient.git")
        }
        let upstreamPages = host == "timschneeb.github.io" && segments.first == "galaxybudsclient"
        let legacyUpstream = host == "timschneeberger.me" || host == "www.timschneeberger.me"
        guard !upstreamRepository && !upstreamPages && !legacyUpstream else { throw ConfigurationError.upstreamFeed }
        return url
    }

    /// Swift's `as? Bool` also accepts some numeric NSNumbers. IPC settings require a
    /// real Swift/CFBoolean (including JSON true/false), never 0/1, strings, or null.
    static func strictBoolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    enum ConfigurationError: LocalizedError, Equatable {
        case missingFeed, missingPublicKey, invalidFeed, placeholderFeed, upstreamFeed, invalidPublicKey

        var errorDescription: String? {
            switch self {
            case .missingFeed: return "Updates are unconfigured: SUFeedURL is missing or is not a nonempty string."
            case .missingPublicKey: return "Updates are unconfigured: SUPublicEDKey is missing or is not a nonempty string."
            case .invalidFeed: return "Updates require a valid public HTTPS feed URL without credentials, query, or fragment."
            case .placeholderFeed: return "Updates are unconfigured: the feed URL contains a placeholder or reserved host."
            case .upstreamFeed: return "The timschneeb/GalaxyBudsClient upstream release feed cannot update this native app."
            case .invalidPublicKey: return "SUPublicEDKey must be canonical base64 encoding exactly 32 Ed25519 public-key bytes."
            }
        }
    }
}

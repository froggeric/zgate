import Foundation

/// Pure port of the CLI's ProviderEndpointRoutingService mapping rules
/// (zcode.cjs 0.17.1 — P_t/Iha/Aha/xha/xvo). No network, fully testable.
///
/// Parse discipline: any invalid entry rejects the WHOLE table — a hostile
/// or malformed `agent/configs` response must never half-apply. `resolve`
/// then matches a request URL whose origin (scheme/host/port, 443 default)
/// equals the entry's and whose path equals `from`'s or extends it at a
/// segment boundary (the CLI's prefix rewrite: `…/zcode-plan/anthropic`
/// maps `…/zcode-plan/anthropic/v1/messages` → `…/ultra-zai/anthropic/v1/messages`,
/// query preserved). No match → nil; the caller serves the original URL
/// (fail-open).
struct EndpointMapping: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let from: URL
        let to: URL
        let flaggedForZcodeAuthorization: Bool
    }

    let entries: [Entry]

    /// The only origin a flagged entry's `to` may target.
    private static let endpointOrigin = URL(string: "https://zcode.z.ai")!
    /// Path prefixes a flagged entry's `to` may carry (segment-boundary
    /// match: the live ultra target is `/api/v1/ultra-zai/anthropic`).
    private static let authorizationTargetAllowlist = ["/api/v1/ultra", "/api/v1/ultra-zai"]
    private static let maxEntries = 256
    private static let maxBodyBytes = 256 * 1024

    /// Parses and validates one `agent/configs` body. nil = rejected
    /// (envelope not `{code:0, data:{proxyEndpoint:{mapping:[…]}}}`, body or
    /// table oversized, or any entry invalid — see `validatedURL` and the
    /// flagged-target rules).
    static func parse(_ data: Data) -> EndpointMapping? {
        guard data.count <= maxBodyBytes,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["code"] as? Int) == 0,
              let mapping = (((json["data"] as? [String: Any])?["proxyEndpoint"] as? [String: Any])?["mapping"] as? [[String: Any]]),
              mapping.count <= maxEntries else { return nil }
        var seen = Set<String>()
        var entries: [Entry] = []
        for raw in mapping {
            guard let fromString = raw["from"] as? String, let toString = raw["to"] as? String,
                  let from = validatedURL(fromString), let to = validatedURL(toString),
                  let fromKey = lookupKey(from), seen.insert(fromKey).inserted else { return nil }
            var flagged = false
            if let header = raw["zcodeAuthorizationHeader"] as? String {
                guard header.caseInsensitiveCompare("X-ZCode-Authorization") == .orderedSame,
                      isAllowedAuthorizationTarget(to) else { return nil }
                flagged = true
            }
            entries.append(Entry(from: from, to: to, flaggedForZcodeAuthorization: flagged))
        }
        return EndpointMapping(entries: entries)
    }

    /// Resolves a request URL through the table, or nil when no entry
    /// matches (the caller serves the original URL — fail-open). A match
    /// rewrites origin+prefix to `to`, preserving the remainder of the path
    /// and the query.
    func resolve(_ raw: String) -> (url: String, addZcodeAuthorization: Bool)? {
        guard let url = URL(string: raw),
              let scheme = url.scheme, let host = url.host
        else { return nil }
        let port = url.port ?? 443
        let requestPath = url.normalizedPath
        for entry in entries {
            guard let from = entry.from.scheme, let fromHost = entry.from.host,
                  from == scheme, fromHost == host, (entry.from.port ?? 443) == port
            else { continue }
            let fromPath = entry.from.normalizedPath
            guard requestPath == fromPath || requestPath.hasPrefix(fromPath + "/") else { continue }
            let suffix = String(requestPath.dropFirst(fromPath.count))
            return (Self.absolute(entry.to, suffix: suffix, query: url.query), entry.flaggedForZcodeAuthorization)
        }
        return nil
    }

    // MARK: - Validation

    /// Bare https URLs only: no userinfo, query, or fragment.
    private static func validatedURL(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
        else { return nil }
        return url
    }

    /// A flagged entry's `to` must share the endpoint origin and carry an
    /// allowlisted path, matched at a path-segment boundary (`/api/v1/ultra`
    /// admits `/api/v1/ultra/…` but not `/api/v1/ultraviolet`).
    private static func isAllowedAuthorizationTarget(_ to: URL) -> Bool {
        guard to.schemeAndHostAndPort == endpointOrigin.schemeAndHostAndPort else { return false }
        let path = to.normalizedPath
        return authorizationTargetAllowlist.contains { allowlisted in
            path == allowlisted || path.hasPrefix(allowlisted + "/")
        }
    }

    /// Lookup identity: scheme//host:port(443 default) + path with trailing
    /// slashes stripped (the CLI's Aha normalization).
    private static func lookupKey(_ url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        return "\(scheme)//\(host):\(url.port ?? 443)\(url.normalizedPath)"
    }

    /// The rewritten URL: `to` (trailing slashes stripped) + the request's
    /// path remainder + its query.
    private static func absolute(_ to: URL, suffix: String, query: String?) -> String {
        var base = to.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        var string = base + suffix
        if let query, !query.isEmpty { string += "?" + query }
        return string
    }
}

// MARK: - URL helpers

extension URL {
    /// Path with trailing slashes stripped ("/" and "" both normalize to "").
    var normalizedPath: String {
        var path = self.path
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Origin identity `scheme//host:port` with 443 as the default port.
    var schemeAndHostAndPort: String {
        "\(scheme ?? "")//\(host ?? ""):\(port ?? 443)"
    }
}

import Foundation

/// Mints the signing-free `api.z.ai/api/anthropic` credential — the
/// fallback edge relay fidelity Task 7 degrades onto while the signed chain
/// is unavailable. The key SECRET is revealed server-side by the `/copy`
/// endpoint; there is no local decryption anywhere in this type. The
/// credential is `"{apiKey}.{secretKey}"` (the CLI's `zai-api` provider
/// form) and persists as the fallback vendor's `apiKey` in config.json.
///
/// Chain (15 s per call, all `api.z.ai`, every call authorized with the
/// Bearer biz JWT SigningClient's chain already holds):
/// 1. `GET /api/biz/customer/getCustomerInfo` → the org whose name contains
///    `默认机构` else the first, and within it the project whose name
///    contains `默认项目` else the first;
/// 2. `GET /api/biz/v1/organization/{o}/projects/{p}/api_keys` → the entry
///    named `zcode-api-key`;
/// 3. missing → `POST` the same URL with body `{"name":"zcode-api-key"}`;
/// 4. `GET …/api_keys/copy/{apiKey}` → `data.secretKey` (`secret_key`
///    accepted) → `"{apiKey}.{secretKey}"`.
///
/// A struct with an injected biz-JWT provider and HTTP execute closure so
/// tests script the chain without network; the production wiring lives in
/// ProxyServer (JWT from `SigningClient.currentBizJWT`, default
/// URLSession execute).
nonisolated struct ApiKeyMinter: Sendable {

    /// The pinned fallback edge. Also the identity marker for "this vendor
    /// IS the fallback edge" in config migrations and routing.
    static let fallbackBaseURL = "https://api.z.ai/api/anthropic"
    /// The API-key entry the chain looks for (or creates).
    static let keyName = "zcode-api-key"

    struct Configuration {
        /// Origin of the api.z.ai biz family. Injectable so tests can point
        /// the default execute closure at a local stub.
        var origin = "https://api.z.ai"
        /// Bound per call (the plan's 15 s).
        var requestTimeout: TimeInterval = 15
        /// Biz-JWT source; production is SigningClient's cached session.
        var bizJWTProvider: (@Sendable () async throws -> String)?
        /// HTTP seam — tests script it or let the default URLSession run.
        var execute: @Sendable (URLRequest) async throws -> (status: Int, body: Data) = { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        }

        init() {}
    }

    enum MintError: Error, Equatable {
        /// No biz-JWT provider configured (or it threw before any call).
        case noBizJWT
        /// Non-success answer: HTTP status + business code, never a body dump.
        case envelope(status: Int, code: Int?)
        /// Payload missing a field the chain requires (reason strings only).
        case malformed(String)
        /// `/copy` answered success but carried no secret.
        case missingSecretKey
    }

    private let configuration: Configuration

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// True when a vendor baseURL points at the pinned fallback edge
    /// (trailing slashes and case are tolerated).
    static func isFallbackEdge(_ baseURL: String) -> Bool {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return !trimmed.isEmpty && trimmed.caseInsensitiveCompare(fallbackBaseURL) == .orderedSame
    }

    /// Runs the whole chain and returns `"{apiKey}.{secretKey}"`.
    func mint() async throws -> String {
        guard let bizJWTProvider = configuration.bizJWTProvider else {
            throw MintError.noBizJWT
        }
        let bizJWT = try await bizJWTProvider()

        // 1. Customer info → org + project.
        let info = try await call(method: "GET", path: "/api/biz/customer/getCustomerInfo", bizJWT: bizJWT)
        let location = try Self.resolveLocation(from: info)

        // 2-3. The pinned key entry, created when missing.
        let keysPath = "/api/biz/v1/organization/\(location.organizationId)"
            + "/projects/\(location.projectId)/api_keys"
        let list = try await call(method: "GET", path: keysPath, bizJWT: bizJWT)
        var entry = Self.findNamedKey(in: Self.keyEntries(from: list))
        if entry == nil {
            let body = try JSONSerialization.data(withJSONObject: ["name": Self.keyName])
            let created = try await call(method: "POST", path: keysPath, bizJWT: bizJWT, body: body)
            entry = Self.findNamedKey(in: Self.keyEntries(from: created)) ?? Self.keyEntries(from: created).first
        }
        guard let entry, let apiKeyID = Self.idField(entry["id"] ?? entry["apiKeyId"] ?? entry["apiKey"]),
            !apiKeyID.isEmpty
        else {
            throw MintError.malformed("api-key entry carries no id")
        }

        // 4. Server-side secret reveal.
        let copy = try await call(method: "GET", path: "\(keysPath)/copy/\(apiKeyID)", bizJWT: bizJWT)
        let secret = (copy["secretKey"] as? String) ?? (copy["secret_key"] as? String)
        guard let secret, !secret.isEmpty else {
            throw MintError.missingSecretKey
        }
        return "\(apiKeyID).\(secret)"
    }

    // MARK: - HTTP

    /// One api/biz call: Bearer biz JWT, JSON envelope gate, payload object.
    /// Success discipline mirrors SigningClient's live-verified api/biz
    /// family: HTTP 2xx AND business `code` absent, 0, or 200.
    private func call(method: String, path: String, bizJWT: String, body: Data? = nil) async throws -> [String: Any] {
        guard let url = URL(string: configuration.origin + path) else {
            throw MintError.malformed("path does not form a URL: \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = configuration.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bizJWT)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (status, data) = try await configuration.execute(request)
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw MintError.envelope(status: status, code: nil)
        }
        let code = Self.numberField(json["code"]).map(Int.init)
        guard (200..<300).contains(status), code == nil || code == 0 || code == 200 else {
            throw MintError.envelope(status: status, code: code)
        }
        if let payload = json["data"] as? [String: Any] {
            return payload
        }
        if json["data"] == nil {
            return json  // payload at the top level (no data envelope)
        }
        throw MintError.envelope(status: status, code: code)
    }

    // MARK: - Payload walking (tolerant)

    /// org `默认机构` else first / project `默认项目` else first.
    private static func resolveLocation(from data: [String: Any]) throws -> (organizationId: String, projectId: String) {
        let orgs = arrayField(data["organizations"] ?? data["organizationList"] ?? data["orgs"] ?? data["list"])
        guard !orgs.isEmpty else {
            throw MintError.malformed("customer info carries no organizations")
        }
        let org = pickNamed(orgs, preferredSubstring: "默认机构")
        guard let organizationId = idField(org["id"] ?? org["organizationId"] ?? org["orgId"]) else {
            throw MintError.malformed("organization entry carries no id")
        }
        var projects = arrayField(org["projects"] ?? org["projectList"])
        if projects.isEmpty {
            projects = arrayField(data["projects"] ?? data["projectList"])
        }
        guard !projects.isEmpty else {
            throw MintError.malformed("organization carries no projects")
        }
        let project = pickNamed(projects, preferredSubstring: "默认项目")
        guard let projectId = idField(project["id"] ?? project["projectId"]) else {
            throw MintError.malformed("project entry carries no id")
        }
        return (organizationId, projectId)
    }

    /// The key entries of a list answer: `data` as an array, `data.list`,
    /// `data.apiKeys`, or `data` itself when it is a single matching entry.
    private static func keyEntries(from data: [String: Any]) -> [[String: Any]] {
        let list = arrayField(data["list"] ?? data["apiKeys"] ?? data["records"])
        if !list.isEmpty {
            return list
        }
        if data["name"] != nil && (data["id"] != nil || data["apiKeyId"] != nil) {
            return [data]
        }
        return []
    }

    /// The entry named exactly `zcode-api-key`, else nil.
    private static func findNamedKey(in entries: [[String: Any]]) -> [String: Any]? {
        entries.first { ($0["name"] as? String) == keyName }
    }

    /// First entry whose `name` contains the preferred substring, else the
    /// first entry (the plan's "else first" rule).
    private static func pickNamed(_ entries: [[String: Any]], preferredSubstring: String) -> [String: Any] {
        if let preferred = entries.first(where: {
            ($0["name"] as? String)?.contains(preferredSubstring) == true
        }) {
            return preferred
        }
        return entries[0]
    }

    /// Array field of objects, empty when absent or of another shape.
    private static func arrayField(_ value: Any?) -> [[String: Any]] {
        if let list = value as? [[String: Any]] { return list }
        if let any = value as? [Any] { return any.compactMap { $0 as? [String: Any] } }
        return []
    }

    /// String-or-numeric id field (the MonitorEnvelope/RelayErrorTaxonomy
    /// number discipline; booleans excluded).
    private static func idField(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        if let number = numberField(value) {
            return number.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int64(number))
                : String(number)
        }
        return nil
    }

    private static func numberField(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.doubleValue
        }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

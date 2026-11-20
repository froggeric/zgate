import Foundation

/// How requests to a vendor are authenticated and forwarded.
enum VendorKind: String, Codable, Sendable {
    /// Anthropic-compatible vendor with a static configured API key.
    case anthropic
    /// The zcode signed relay: per-request V4 signing headers built from the
    /// SigningClient chain (see RelayTarget). The configured API key is unused.
    case relay
    /// The zcode Off-Peak / Idle Plan ticket queue (see OffPeakTarget):
    /// requests routed here walk the async ticket plane. The configured API
    /// key is unused (auth is the plan-JWT chain), and the serving origin
    /// comes from `OffPeakConfig`, not this row's baseURL.
    case offPeak
}

enum VendorDefaults {
    static let supportsThinkingBlocks = false
    static let supportsAnthropicCountTokens = true
    static let repairsAnthropicToolCalls = false
    static let stripsClaudeOnlyRequestFields = false
    static let applyGLMCanonicalization = false

    static func isDeepSeekBaseURL(_ baseURL: String) -> Bool {
        if let host = URL(string: baseURL)?.host?.lowercased() {
            return host == "api.deepseek.com"
        }
        return baseURL.lowercased().contains("api.deepseek.com")
    }

    static func repairsAnthropicToolCalls(forBaseURL baseURL: String) -> Bool {
        isDeepSeekBaseURL(baseURL) ? true : repairsAnthropicToolCalls
    }
}

/// A single upstream API provider.
struct Vendor: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    /// Base URL of the vendor's API (without version path),
    /// e.g. "https://dashscope.aliyuncs.com/compatible-mode".
    /// The request URI (including "/v1/...") is appended directly.
    var baseURL: String
    /// API key stored in plaintext in config.json (personal-use tool; not Keychain by design).
    var apiKey: String
    /// Per-vendor connect timeout in seconds. Default 10.
    var connectTimeoutSeconds: Int
    /// Per-vendor read timeout in seconds. Default 120.
    var readTimeoutSeconds: Int
    /// Links to a ClientConfig.id to indicate which tool this vendor is compatible with.
    /// nil = compatible with all clients.
    var compatibleClientID: UUID?
    /// Vendor model IDs available for quick selection in routing forms.
    var supportedModels: [String]
    /// Whether this vendor accepts Anthropic `thinking` content blocks in request history.
    var supportsThinkingBlocks: Bool
    /// Whether this vendor supports Anthropic `/v1/messages/count_tokens`.
    var supportsAnthropicCountTokens: Bool
    /// Whether ModelProxy should repair returned Anthropic `tool_use.input` blocks for this vendor.
    var repairsAnthropicToolCalls: Bool
    /// Whether ModelProxy removes Claude-only request fields and `anthropic-beta` before forwarding.
    var stripsClaudeOnlyRequestFields: Bool
    /// Whether the outgoing top-level `model` value runs through
    /// `RelayTarget.canonicalModel` before forwarding (documented
    /// routing-compatibility transform — the GLM canonical wire name, so
    /// retired names never leak raw). Seeded on the Task-7 fallback edge.
    var applyGLMCanonicalization: Bool
    /// How this vendor is authenticated: static key (`.anthropic`) or the
    /// signed zcode relay (`.relay`). Legacy configs decode as `.anthropic`.
    var vendorKind: VendorKind
    /// Which signing domain this vendor belongs to for transcript replay compatibility.
    var signingDomain: SigningDomain
    /// Whether requests to this vendor should preserve raw replay-sensitive transcript blocks.
    var replayPolicy: TranscriptReplayPolicy

    init(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        apiKey: String,
        connectTimeoutSeconds: Int = 10,
        readTimeoutSeconds: Int = 120,
        compatibleClientID: UUID? = nil,
        supportedModels: [String] = [],
        supportsThinkingBlocks: Bool = VendorDefaults.supportsThinkingBlocks,
        supportsAnthropicCountTokens: Bool? = nil,
        repairsAnthropicToolCalls: Bool? = nil,
        stripsClaudeOnlyRequestFields: Bool = VendorDefaults.stripsClaudeOnlyRequestFields,
        applyGLMCanonicalization: Bool? = nil,
        vendorKind: VendorKind = .anthropic,
        signingDomain: SigningDomain? = nil,
        replayPolicy: TranscriptReplayPolicy? = nil
    ) {
        let resolvedSigningDomain = signingDomain ?? SigningDomain.infer(fromBaseURL: baseURL)
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.readTimeoutSeconds = readTimeoutSeconds
        self.compatibleClientID = compatibleClientID
        self.supportedModels = supportedModels
        self.supportsThinkingBlocks = supportsThinkingBlocks
        self.supportsAnthropicCountTokens = supportsAnthropicCountTokens
            ?? VendorDefaults.supportsAnthropicCountTokens
        self.repairsAnthropicToolCalls = repairsAnthropicToolCalls
            ?? VendorDefaults.repairsAnthropicToolCalls(forBaseURL: baseURL)
        self.stripsClaudeOnlyRequestFields = stripsClaudeOnlyRequestFields
        self.applyGLMCanonicalization = applyGLMCanonicalization
            ?? VendorDefaults.applyGLMCanonicalization
        self.vendorKind = vendorKind
        self.signingDomain = resolvedSigningDomain
        // The relay speaks the Anthropic protocol end to end: transcript
        // blocks pass through untouched (zbridge forwards byte-for-byte).
        self.replayPolicy = replayPolicy
            ?? (vendorKind == .relay
                ? .transparent
                : TranscriptReplayPolicy.defaultPolicy(for: resolvedSigningDomain))
    }

    // MARK: - Codable (legacy-tolerant)

    enum CodingKeys: String, CodingKey {
        case id, name, baseURL, apiKey
        case connectTimeoutSeconds, readTimeoutSeconds
        case compatibleClientID
        case supportedModels
        case supportsThinkingBlocks
        case supportsAnthropicCountTokens
        case repairsAnthropicToolCalls
        case stripsClaudeOnlyRequestFields
        case applyGLMCanonicalization
        case vendorKind
        case signingDomain
        case replayPolicy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        apiKey = try c.decode(String.self, forKey: .apiKey)
        connectTimeoutSeconds = (try? c.decode(Int.self, forKey: .connectTimeoutSeconds)) ?? 10
        readTimeoutSeconds = (try? c.decode(Int.self, forKey: .readTimeoutSeconds)) ?? 120
        compatibleClientID = try? c.decode(UUID.self, forKey: .compatibleClientID)
        supportedModels = (try? c.decode([String].self, forKey: .supportedModels)) ?? []
        supportsThinkingBlocks = (try? c.decode(Bool.self, forKey: .supportsThinkingBlocks))
            ?? VendorDefaults.supportsThinkingBlocks
        supportsAnthropicCountTokens = (try? c.decodeIfPresent(Bool.self, forKey: .supportsAnthropicCountTokens))
            ?? VendorDefaults.supportsAnthropicCountTokens
        repairsAnthropicToolCalls = (try? c.decodeIfPresent(Bool.self, forKey: .repairsAnthropicToolCalls))
            ?? VendorDefaults.repairsAnthropicToolCalls(forBaseURL: baseURL)
        stripsClaudeOnlyRequestFields = (try? c.decodeIfPresent(Bool.self, forKey: .stripsClaudeOnlyRequestFields))
            ?? VendorDefaults.stripsClaudeOnlyRequestFields
        applyGLMCanonicalization = (try? c.decodeIfPresent(Bool.self, forKey: .applyGLMCanonicalization))
            ?? VendorDefaults.applyGLMCanonicalization
        let decodedVendorKind = (try? c.decodeIfPresent(VendorKind.self, forKey: .vendorKind))
            ?? .anthropic
        vendorKind = decodedVendorKind
        let resolvedSigningDomain = (try? c.decode(SigningDomain.self, forKey: .signingDomain))
            ?? SigningDomain.infer(fromBaseURL: baseURL)
        signingDomain = resolvedSigningDomain
        replayPolicy = (try? c.decode(TranscriptReplayPolicy.self, forKey: .replayPolicy))
            ?? (decodedVendorKind == .relay
                ? .transparent
                : TranscriptReplayPolicy.defaultPolicy(for: resolvedSigningDomain))
    }
}

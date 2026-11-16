import Foundation
import Observation
import OSLog

// MARK: - Debug Config

struct DebugConfig: Codable, Hashable {
    var isEnabled: Bool = false
    var minimumLogLevel: LogLevel = .info
    var autoCleanupEnabled: Bool = true
    var cleanupAfterDays: Int = 7
    var compressAfterDays: Int = 3

    enum LogLevel: String, Codable, CaseIterable, Comparable {
        case debug, info, warning, error

        var osLogType: OSLogType {
            switch self {
            case .debug: return .debug
            case .info: return .info
            case .warning: return .default
            case .error: return .error
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            let order: [Self] = [.debug, .info, .warning, .error]
            return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
        }
    }
}

// Tolerant decode: hand-edited or partially written config files may carry a
// `debug` object with only some keys. Property defaults do not participate
// in Swift's synthesized decoder (a missing key throws keyNotFound), which
// used to make AppConfig's `try?` fall back to a fully-defaulted
// DebugConfig — silently discarding the keys the file DID carry (notably
// `isEnabled: true`, disabling file logging). Decode each key if present,
// with the same defaults as the memberwise init. The extension keeps the
// memberwise initializer available.
extension DebugConfig {
    enum CodingKeys: String, CodingKey {
        case isEnabled, minimumLogLevel, autoCleanupEnabled, cleanupAfterDays, compressAfterDays
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        minimumLogLevel = try c.decodeIfPresent(LogLevel.self, forKey: .minimumLogLevel) ?? .info
        autoCleanupEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoCleanupEnabled) ?? true
        cleanupAfterDays = try c.decodeIfPresent(Int.self, forKey: .cleanupAfterDays) ?? 7
        compressAfterDays = try c.decodeIfPresent(Int.self, forKey: .compressAfterDays) ?? 3
    }
}

// MARK: - App Config

/// Top-level configuration container.
/// Loaded from and persisted to config.json by ConfigStore.
/// `@Observable` so SwiftUI views automatically update when properties change.
@Observable
final class AppConfig: Codable {
    var vendors: [Vendor]
    var clients: [ClientConfig]
    /// Global model routing rules, shared across all clients.
    var modelMappings: [ModelMapping]
    var debug: DebugConfig
    /// User-overridden model pricing ($/1M tokens). Keys are model ID strings.
    var modelPricingOverrides: [String: ModelPrice]
    var webSearch: WebSearchConfig

    // MARK: - Init

    init(
        vendors: [Vendor] = [],
        clients: [ClientConfig] = [],
        modelMappings: [ModelMapping] = [],
        debug: DebugConfig = DebugConfig(),
        modelPricingOverrides: [String: ModelPrice] = [:],
        webSearch: WebSearchConfig = WebSearchConfig()
    ) {
        self.vendors = vendors
        self.clients = clients
        self.modelMappings = modelMappings
        self.debug = debug
        self.modelPricingOverrides = modelPricingOverrides
        self.webSearch = webSearch
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case vendors
        case clients
        case modelMappings
        case debug
        case modelPricingOverrides
        case webSearch
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vendors = try container.decode([Vendor].self, forKey: .vendors)
        clients = try container.decode([ClientConfig].self, forKey: .clients)
        if container.contains(.modelMappings) {
            modelMappings = try container.decode([ModelMapping].self, forKey: .modelMappings)
        } else {
            modelMappings = []
        }
        debug = (try? container.decode(DebugConfig.self, forKey: .debug)) ?? DebugConfig()
        modelPricingOverrides = (try? container.decode([String: ModelPrice].self, forKey: .modelPricingOverrides)) ?? [:]
        webSearch = (try? container.decode(WebSearchConfig.self, forKey: .webSearch)) ?? WebSearchConfig()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(vendors, forKey: .vendors)
        try container.encode(clients, forKey: .clients)
        try container.encode(modelMappings, forKey: .modelMappings)
        try container.encode(debug, forKey: .debug)
        if !modelPricingOverrides.isEmpty {
            try container.encode(modelPricingOverrides, forKey: .modelPricingOverrides)
        }
        try container.encode(webSearch, forKey: .webSearch)
    }
}

// MARK: - Default config

extension AppConfig {
    /// Sensible defaults created on first launch. Clients are upstream
    /// model-proxy's; vendors and routing rules are the ZGate spec §2
    /// default matrix (see `makeZGateDefaultRouting`).
    static func makeDefault() -> AppConfig {
        let claudeCodeClient = ClientConfig(
            clientName: "Claude Code",
            port: 8080,
            defaultUpstream: "https://api.anthropic.com"
        )
        let codexClient = ClientConfig(
            clientName: "Codex",
            port: 8081,
            defaultUpstream: "https://api.openai.com"
        )
        return makeZGateDefaultRouting(
            AppConfig(clients: [claudeCodeClient, codexClient]))
    }

    /// Spec §2 default matrix, editable in Settings. Ordered rules, first
    /// match wins: `auto` first (CC auto mode), then the class rules; the
    /// opus peak-hours cost lever ships DISABLED (user opts in) but sits
    /// before the plain opus rule so enabling it wins during the window; a
    /// terminal catch-all fallback to relay flash means no request is ever
    /// dropped for an unmatched model.
    ///
    /// No secrets: the relay vendor's key is empty (`.relay` auth comes from
    /// the signing chain), splash is a local server.
    static func makeZGateDefaultRouting(_ config: AppConfig) -> AppConfig {
        var config = config
        let relay = Vendor(
            name: "zcode relay",
            baseURL: "https://zcode.z.ai/api/v1/ultra-zai/anthropic",
            apiKey: "",
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 300,
            supportsThinkingBlocks: true,
            supportsAnthropicCountTokens: false,
            vendorKind: .relay)
        let splash = Vendor(
            name: "splash (local)",
            baseURL: "http://127.0.0.1:8000",
            apiKey: "",
            replayPolicy: .portableOnly)
        config.vendors = [relay, splash]

        let peakHours = RuleCondition(
            type: .timeWindow, days: .weekdays, from: "07:00", to: "11:00", tz: "Europe/Paris")
        config.modelMappings = [
            ModelMapping(
                sourceModel: "auto", targetModel: "GLM-5.3", targetVendorID: relay.id,
                matchClass: .auto),
            ModelMapping(
                sourceModel: "haiku", targetModel: "Qwen3.8-27B-4bit", targetVendorID: splash.id,
                backupTargetModel: "GLM-5.3-Flash", backupTargetVendorID: relay.id,
                matchClass: .haiku),
            ModelMapping(
                sourceModel: "sonnet", targetModel: "GLM-5.3", targetVendorID: relay.id,
                matchClass: .sonnet),
            // Cost lever: opus downgrades to flash during Paris weekday peak
            // (3× metering). Disabled until the user opts in.
            ModelMapping(
                sourceModel: "opus (peak hours)", targetModel: "GLM-5.3-Flash",
                targetVendorID: relay.id, isEnabled: false,
                matchClass: .opus, conditions: [peakHours]),
            ModelMapping(
                sourceModel: "opus", targetModel: "GLM-5.3", targetVendorID: relay.id,
                matchClass: .opus),
            ModelMapping(
                sourceModel: "fallback", targetModel: "GLM-5.3-Flash", targetVendorID: relay.id,
                catchAll: true),
        ]
        return config
    }
}

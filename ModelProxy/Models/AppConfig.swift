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
    /// Splash supervision settings; absent in pre-splash configs, seeded by
    /// `makeZGateDefaultRouting` on first launch.
    var splash: SplashSettings?
    /// Update-check preferences + last-seen/dismissed tags (spec §3.4/§4);
    /// nil in pre-update configs until first write.
    var update: UpdateSettings?
    /// Credential-store data base (item 2, login-flow wave): nil = the
    /// GUI/CLI shared default (`$HOME/.zcode`); an absolute path string
    /// (tilde-expanded) selects another base — notably the legacy
    /// `~/.zcode-scratch-v3`. Settings UI ships in the wave's UI task;
    /// this is the persistence + plumbing.
    var credentialStoreBase: String?

    // MARK: - Init

    init(
        vendors: [Vendor] = [],
        clients: [ClientConfig] = [],
        modelMappings: [ModelMapping] = [],
        debug: DebugConfig = DebugConfig(),
        modelPricingOverrides: [String: ModelPrice] = [:],
        webSearch: WebSearchConfig = WebSearchConfig(),
        splash: SplashSettings? = nil,
        update: UpdateSettings? = nil,
        credentialStoreBase: String? = nil
    ) {
        self.vendors = vendors
        self.clients = clients
        self.modelMappings = modelMappings
        self.debug = debug
        self.modelPricingOverrides = modelPricingOverrides
        self.webSearch = webSearch
        self.splash = splash
        self.update = update
        self.credentialStoreBase = credentialStoreBase
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case vendors
        case clients
        case modelMappings
        case debug
        case modelPricingOverrides
        case webSearch
        case splash
        case update
        case credentialStoreBase
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
        splash = try? container.decode(SplashSettings.self, forKey: .splash)
        update = try? container.decode(UpdateSettings.self, forKey: .update)
        // Absent in every pre-wave config — nil = shared default store.
        credentialStoreBase = try? container.decodeIfPresent(String.self, forKey: .credentialStoreBase)
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
        if let splash {
            try container.encode(splash, forKey: .splash)
        }
        if let update {
            try container.encode(update, forKey: .update)
        }
        if let credentialStoreBase {
            try container.encode(credentialStoreBase, forKey: .credentialStoreBase)
        }
    }
}

// MARK: - Default config

extension AppConfig {
    /// Sensible defaults created on first launch. Client names/upstreams are
    /// upstream model-proxy's; ports are the ZGate plan's (Claude Code 8787 —
    /// "default port 8787, next free port if taken"; Codex 8789, skipping
    /// 8788 which zbridge owns on the target machine); vendors and routing
    /// rules are the default matrix of the owner's 2026-11-16 ruling (which
    /// corrects spec §2 — see `makeZGateDefaultRouting`).
    static func makeDefault() -> AppConfig {
        let claudeCodeClient = ClientConfig(
            clientName: "Claude Code",
            port: 8787,
            defaultUpstream: "https://api.anthropic.com"
        )
        let codexClient = ClientConfig(
            clientName: "Codex",
            port: 8789,
            defaultUpstream: "https://api.openai.com"
        )
        return makeZGateDefaultRouting(
            AppConfig(clients: [claudeCodeClient, codexClient]))
    }

    /// Default matrix — v2.1, owner ruling 2026-11-17 (supersedes the
    /// 2026-11-16 correction of spec §2). Editable in Settings. Ordered
    /// rules, first match wins: each peak twin sits before its plain rule so
    /// it wins during the window only; a terminal catch-all fallback to
    /// relay flash means no request is ever dropped for an unmatched model.
    ///
    /// v2.1 semantics: ALL deliberate work runs opus-class GLM-5.3 on the
    /// relay (sonnet and opus classes alike); haiku-class work rides the
    /// fast relay tier GLM-5.3-Flash. Local qwen is OFF every default route
    /// — its names match no class rule and fall to the catch-all.
    ///
    /// The two peak twins (weekdays 07:00–11:00 Paris → Flash) STAY in the
    /// matrix but ship DISABLED — a dormant cost lever (user ruling
    /// 2026-11-17): if peak metering ever returns, re-enabling is one
    /// toggle. The time window keeps an enabled twin inert outside peak.
    ///
    /// These defaults apply ONLY on first launch with no config.json
    /// (`ConfigStore.loadOrCreateDefault` writes them exactly once).
    /// Existing installs are brought to the same shape by ConfigStore's
    /// one-time migration 5; a config that already shows user edits is left
    /// alone.
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
            baseURL: "http://127.0.0.1:8123",
            apiKey: "",
            replayPolicy: .portableOnly)
        config.vendors = [relay, splash]

        let peakHours = RuleCondition(
            type: .timeWindow, days: .weekdays, from: "07:00", to: "11:00", tz: "Europe/Paris")
        config.modelMappings = [
            // Peak twins (Package C rider + opus lever): DISABLED by default —
            // dormant cost lever, user ruling 2026-11-17. Same window both;
            // inert outside it when enabled.
            ModelMapping(
                sourceModel: "auto (peak hours)", targetModel: "GLM-5.3-Flash",
                targetVendorID: relay.id, isEnabled: false,
                matchClass: .auto, conditions: [peakHours]),
            ModelMapping(
                sourceModel: "auto", targetModel: "GLM-5.3", targetVendorID: relay.id,
                matchClass: .auto),
            // Qwen levers (2026-11-18): DISABLED rows routing a tier to the
            // local splash qwen model with relay-Flash failover — enable in
            // Settings → Rules to take that tier local (health-gated: splash
            // down = the backup serves). Existing installs get the same rows
            // from migration 7. ABOVE the plain rows: matching is
            // first-eligible-wins in config order, so an enabled lever must
            // precede its tier's plain row (same position migration 7 uses).
            ModelMapping(
                sourceModel: "sonnet (local qwen)", targetModel: "local/qwen3.8-27b-q8",
                targetVendorID: splash.id,
                backupTargetModel: "GLM-5.3-Flash", backupTargetVendorID: relay.id,
                isEnabled: false, matchClass: .sonnet),
            // v2.1: sonnet-class work → main opus-class relay model (was
            // flash-tier metering under the 2026-11-16 ruling).
            ModelMapping(
                sourceModel: "sonnet", targetModel: "GLM-5.3", targetVendorID: relay.id,
                matchClass: .sonnet),
            ModelMapping(
                sourceModel: "haiku (local qwen)", targetModel: "local/qwen3.8-27b-q8",
                targetVendorID: splash.id,
                backupTargetModel: "GLM-5.3-Flash", backupTargetVendorID: relay.id,
                isEnabled: false, matchClass: .haiku),
            // v2.1: haiku-class work → fast relay tier; the splash q8 target
            // and its relay backup are gone (local qwen off default routes).
            ModelMapping(
                sourceModel: "haiku", targetModel: "GLM-5.3-Flash", targetVendorID: relay.id,
                matchClass: .haiku),
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
        config.splash = SplashSettings.defaultSeeded()
        return config
    }

    /// Spec §6.1: the stored splash vendor baseURL (default 8123) goes stale
    /// the moment the user changes the port. Pure in-memory rewrite used to
    /// build routing; NEVER persisted (the stored row keeps its default).
    static func syncingSplashVendor(_ vendors: [Vendor], splashPort: Int?) -> [Vendor] {
        let port = splashPort ?? 8123
        return vendors.map { v in
            guard v.name.lowercased().contains("splash"),
                  v.baseURL.contains("127.0.0.1") else { return v }
            var out = v
            out.baseURL = "http://127.0.0.1:\(port)"
            return out
        }
    }
}

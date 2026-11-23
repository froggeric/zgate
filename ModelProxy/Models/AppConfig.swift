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

// MARK: - Off-Peak Config (relay fidelity Task 10)

/// Settings for the opt-in, default-OFF async relay surface
/// (`/async/v1/messages` — the Off-Peak / Idle Plan ticket queue).
/// Absent in every pre-wave config: tolerant per-key decode (a hand edit
/// carrying only `{"enabled": true}` keeps the rest of the defaults — the
/// DebugConfig lesson) and encode-if-changed below keep existing installs
/// byte-stable until the user actually edits the section.
struct OffPeakConfig: Hashable, Sendable {
    /// Default-OFF: the surface answers a local 404-style error and
    /// contacts nothing until the user opts in.
    var enabled: Bool = false
    /// Origin of both the ticket control plane and the data plane.
    static let defaultOrigin = "https://zcode.z.ai"
    var origin: String = OffPeakConfig.defaultOrigin
    /// Bound on the whole availability+queue wait, in minutes.
    var maxWaitMinutes: Int = 60
    /// Status-poll floor in seconds; the server's `next_poll_after` wins
    /// when larger.
    var pollIntervalSeconds: Int = 5
    /// Downstream `": keepalive"` cadence while queued/waiting.
    var keepaliveSeconds: Int = 3
}

extension OffPeakConfig: Codable {
    enum CodingKeys: String, CodingKey {
        case enabled, origin, maxWaitMinutes, pollIntervalSeconds, keepaliveSeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        origin = try c.decodeIfPresent(String.self, forKey: .origin) ?? OffPeakConfig.defaultOrigin
        maxWaitMinutes = try c.decodeIfPresent(Int.self, forKey: .maxWaitMinutes) ?? 60
        pollIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? 5
        keepaliveSeconds = try c.decodeIfPresent(Int.self, forKey: .keepaliveSeconds) ?? 3
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
    /// Server-driven relay client-version pin (relay fidelity Task 4): the
    /// impersonated zcode CLI version — the single source of RelayTarget's
    /// four version surfaces (UA, `x-zcode-app-version`, `x-client-version`,
    /// sig message). Absent in pre-wave configs → the bundled default; only
    /// `VersionPinService` writes it (greater-only, persisted on bump).
    var relayClientVersion: String
    /// Relay fidelity Task 7 migration marker: the fallback-edge seed
    /// (vendor + catch-all backup) has been applied at least once.
    /// Run-once gate (controller ruling, fix round 1): after the first
    /// application a user-removed edge vendor STAYS removed — migration 10
    /// never re-seeds. Encoded only when true (pre-fix configs and fresh
    /// hand-edits stay byte-stable until the migration records itself).
    var fallbackEdgeSeeded: Bool
    /// Off-peak wave 2 migration marker: the seeded off-peak rule-target
    /// vendor (migration 11) has been applied at least once. Run-once gate
    /// with the same contract as `fallbackEdgeSeeded` / migration 10:
    /// after the first application a user-removed row STAYS removed —
    /// migration 11 never re-seeds. Encoded only when true (legacy configs
    /// stay byte-stable until the migration records itself).
    var offPeakVendorSeeded: Bool
    /// Off-Peak async surface settings (relay fidelity Task 10). Absent in
    /// every pre-wave config → defaults (disabled); the `relayClientVersion`
    /// pattern — defaulted decode, encode-if-changed, no ConfigStore
    /// migration needed (a user setting enabled=false stays false; there is
    /// no "delete the section" UX to resurrect).
    var offPeak: OffPeakConfig

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
        credentialStoreBase: String? = nil,
        relayClientVersion: String = RelayTarget.clientVersion,
        fallbackEdgeSeeded: Bool = false,
        offPeakVendorSeeded: Bool = false,
        offPeak: OffPeakConfig = OffPeakConfig()
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
        self.relayClientVersion = relayClientVersion
        self.fallbackEdgeSeeded = fallbackEdgeSeeded
        self.offPeakVendorSeeded = offPeakVendorSeeded
        self.offPeak = offPeak
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
        case relayClientVersion
        case fallbackEdgeSeeded
        case offPeakVendorSeeded
        case offPeak
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
        // Absent in every pre-wave config — the bundled pin is the default
        // (an emptied hand-edit falls back to it too). Encode-if-changed
        // below keeps existing installs byte-identical until a real
        // server-driven bump writes the key.
        if let stored = try? container.decodeIfPresent(String.self, forKey: .relayClientVersion),
            !stored.isEmpty
        {
            relayClientVersion = stored
        } else {
            relayClientVersion = RelayTarget.clientVersion
        }
        // Absent in every pre-fix config — false until migration 10 records
        // its first application.
        fallbackEdgeSeeded = (try? container.decodeIfPresent(Bool.self, forKey: .fallbackEdgeSeeded)) ?? false
        // Absent in every pre-wave-2 config — false until migration 11
        // records its first application.
        offPeakVendorSeeded = (try? container.decodeIfPresent(Bool.self, forKey: .offPeakVendorSeeded)) ?? false
        // Absent in every pre-wave config — defaults (disabled). A malformed
        // section also falls to defaults rather than failing the whole load.
        offPeak = (try? container.decode(OffPeakConfig.self, forKey: .offPeak)) ?? OffPeakConfig()
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
        if relayClientVersion != RelayTarget.clientVersion {
            try container.encode(relayClientVersion, forKey: .relayClientVersion)
        }
        if fallbackEdgeSeeded {
            try container.encode(true, forKey: .fallbackEdgeSeeded)
        }
        if offPeakVendorSeeded {
            try container.encode(true, forKey: .offPeakVendorSeeded)
        }
        // Encode-if-changed (the relayClientVersion pattern): untouched
        // installs stay byte-stable; a real edit persists the whole section.
        if offPeak != OffPeakConfig() {
            try container.encode(offPeak, forKey: .offPeak)
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

    /// Default matrix — v2.2 (GLM-5.4 launch 2026-11-23) on the v2.1 shape
    /// of the owner ruling 2026-11-17. Editable in Settings. Ordered rules,
    /// first match wins: each peak twin sits before its plain rule so it
    /// wins during the window only; a terminal catch-all fallback to relay
    /// flash means no request is ever dropped for an unmatched model.
    ///
    /// v2.1 semantics: ALL deliberate work runs opus-class on the relay —
    /// GLM-5.4 since v2.2, GLM-5.3 before (sonnet and opus classes alike);
    /// haiku-class work rides the fast relay tier GLM-5.3-Flash. Local qwen
    /// is OFF every default route — its names match no class rule and fall
    /// to the catch-all.
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
        // Relay pin (relay fidelity wave, 2026-11-20, probe-A outcome): the
        // wave first moved the default to the CLI's pre-routing URL
        // (zcode-plan/anthropic) expecting agent/configs to map it per
        // request — the live probe showed the server's mapping table has no
        // zcode-plan entry and the relay 401s that URL, while ultra-zai
        // (a live mapping `to` value) answers 200 with the same signed
        // face. The RESOLVED ultra URL stays the pin; ConfigStore
        // migration 9 heals any config the reverted build repinned.
        let relay = Vendor(
            name: "zcode relay",
            baseURL: "https://zcode.z.ai/api/v1/ultra-zai/anthropic",
            apiKey: "",
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 300,
            supportsThinkingBlocks: true,
            supportsAnthropicCountTokens: false,
            vendorKind: .relay)
        // Unsigned fallback edge (relay fidelity Task 7): the
        // `api.z.ai/api/anthropic` API-key channel the degraded machine
        // serves through while the signed chain is down. The key (minted
        // lazily via the /copy chain, `ApiKeyMinter`) persists here as
        // `apiKey`; the same weekly quota is billed.
        let fallbackEdge = Vendor(
            name: "z.ai API key (fallback)",
            baseURL: ApiKeyMinter.fallbackBaseURL,
            apiKey: "",
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 300,
            supportsThinkingBlocks: true,
            stripsClaudeOnlyRequestFields: true,
            applyGLMCanonicalization: true)
        let splash = Vendor(
            name: "splash (local)",
            baseURL: "http://127.0.0.1:8123",
            apiKey: "",
            replayPolicy: .portableOnly)
        // Order matters: migration 7 identifies splash as the FIRST
        // non-relay vendor, so the fallback edge must sit AFTER it.
        config.vendors = [relay, splash, fallbackEdge]

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
                sourceModel: "auto", targetModel: "GLM-5.4", targetVendorID: relay.id,
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
            // flash-tier metering under the 2026-11-16 ruling). v2.2: GLM-5.4.
            ModelMapping(
                sourceModel: "sonnet", targetModel: "GLM-5.4", targetVendorID: relay.id,
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
                sourceModel: "opus", targetModel: "GLM-5.4", targetVendorID: relay.id,
                matchClass: .opus),
            ModelMapping(
                sourceModel: "fallback", targetModel: "GLM-5.3-Flash", targetVendorID: relay.id,
                backupTargetModel: "GLM-5.3-Flash", backupTargetVendorID: fallbackEdge.id,
                catchAll: true),
        ]
        config.splash = SplashSettings.defaultSeeded()
        // The default matrix IS the fallback-edge-seeded shape — record the
        // migration marker so a fresh install's second launch never rewrites
        // (fix round 1: migration 10 is run-once).
        config.fallbackEdgeSeeded = true
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

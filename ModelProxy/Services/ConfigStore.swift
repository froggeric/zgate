import Foundation
import Observation
import OSLog

/// Loads and saves AppConfig to ~/Library/Application Support/ModelProxy/config.json.
/// @MainActor because AppConfig is @Observable and mutated from SwiftUI context.
@MainActor
@Observable
final class ConfigStore {
    private(set) var config: AppConfig
    /// True if config.json was corrupt at launch and was reset to defaults.
    private(set) var didResetFromCorrupt: Bool = false

    private let configFileURL: URL

    // MARK: - Init

    init(configFileURL: URL = AppPaths.appSupport.appendingPathComponent("config.json")) {
        self.configFileURL = configFileURL
        let result = ConfigStore.loadOrCreateDefault(from: configFileURL)
        self.config = result.config
        self.didResetFromCorrupt = result.wasCorrupt
    }

    func clearCorruptFlag() {
        didResetFromCorrupt = false
    }

    // MARK: - Load

    private static func loadOrCreateDefault(from fileURL: URL) -> (config: AppConfig, wasCorrupt: Bool) {
        let fm = FileManager.default

        // Ensure directory exists.
        if !fm.fileExists(atPath: fileURL.deletingLastPathComponent().path) {
            try? fm.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        guard fm.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            let defaults = AppConfig.makeDefault()
            try? JSONEncoder.pretty.encode(defaults).write(to: fileURL)
            return (defaults, false)
        }

        do {
            var config = try JSONDecoder().decode(AppConfig.self, from: data)
            let preMigration = try? JSONEncoder.pretty.encode(config)

            // Migration 1: strip trailing /v1 from baseURLs (Phase 2 convention change).
            for i in 0..<config.vendors.count {
                if config.vendors[i].baseURL.hasSuffix("/v1") {
                    config.vendors[i].baseURL = String(config.vendors[i].baseURL.dropLast(3))
                }
            }

            // Migration 2: clients missing defaultUpstream get a sensible default.
            for i in 0..<config.clients.count {
                if config.clients[i].defaultUpstream.isEmpty {
                    config.clients[i].defaultUpstream = config.clients[i].clientName
                        .lowercased().contains("claude")
                        ? "https://api.anthropic.com"
                        : "https://api.openai.com"
                }
            }

            config = applyMigrations(config)

            // Persist launch-path migrations (1-5) the FIRST time they change
            // something: the E2E live-config test, the release swap's
            // post-install checks, and any external reader all see the
            // migrated shape on disk. Write-once by encoded-value comparison —
            // on an already-migrated config the encodings match and this
            // never writes (the migrations are idempotent), so a user edit
            // between launches is never clobbered.
            if let preMigration,
               let postMigration = try? JSONEncoder.pretty.encode(config),
               postMigration != preMigration {
                do {
                    try postMigration.write(to: fileURL, options: .atomic)
                } catch {
                    AppLog.config.error("[ConfigStore] Failed to persist migrated config.json: \(error)")
                }
            }

            return (config, false)
        } catch {
            // Corrupt config: reset to defaults. StatusPopover shows one-time alert via didResetFromCorrupt flag.
            AppLog.config.error("[ConfigStore] Failed to decode config.json: \(error). Resetting to defaults.")
            let defaults = AppConfig.makeDefault()
            try? JSONEncoder.pretty.encode(defaults).write(to: fileURL)
            return (defaults, true)
        }
    }

    // MARK: - Migrations (idempotent, testable)

    /// Package C (spec §6 riders) + the v2.1 one-time pass: seed the splash
    /// section when absent, insert the auto-class peak twin into pre-wave
    /// configs, and bring pre-v2 tier targets to the all-relay v2.1 shape.
    /// Existing rules, ids and order are otherwise preserved; running twice
    /// changes nothing.
    static func applyMigrations(_ config: AppConfig) -> AppConfig {
        var config = config
        // Migration 3: seed splash section only when absent.
        if config.splash == nil {
            config.splash = SplashSettings.defaultSeeded()
        }
        // Migration 4: auto-class peak twin (only when no auto rule already
        // carries a timeWindow condition). Inserted DISABLED — v2.1 ships the
        // twins as a dormant cost lever (user ruling 2026-11-17).
        let hasAutoTwin = config.modelMappings.contains {
            $0.matchClass == .auto && !($0.conditions ?? []).isEmpty
        }
        if !hasAutoTwin {
            let relay = config.vendors.first { $0.vendorKind == .relay }
            if let relayID = relay?.id,
               let plainIndex = config.modelMappings.firstIndex(where: {
                   $0.matchClass == .auto && ($0.conditions ?? []).isEmpty
               }) {
                let twin = ModelMapping(
                    sourceModel: "auto (peak hours)", targetModel: "GLM-5.3-Flash",
                    targetVendorID: relayID, isEnabled: false, matchClass: .auto,
                    conditions: [RuleCondition(
                        type: .timeWindow, days: .weekdays,
                        from: "07:00", to: "11:00", tz: "Europe/Paris")])
                config.modelMappings.insert(twin, at: plainIndex)
            }
        }
        // Migration 5 (v2.1, one-time): tier targets to all-relay (sonnet →
        // GLM-5.3, haiku → GLM-5.3-Flash, backups dropped) and both peak
        // twins disabled. Gated on the FULL pre-v2 default shape — the old
        // sonnet row AND the old haiku row — so it runs exactly once per
        // config: after the pass (or once the user edits either row) the gate
        // goes cold and later launches never fight those edits (re-enabling
        // a twin survives). Shape-gated, not version-marked: reverting BOTH
        // rows to the exact pre-v2 shape re-arms the gate and the pass runs
        // once more — the inherent limit of value-gating without a schema
        // version marker; acceptable.
        let relayID = config.vendors.first { $0.vendorKind == .relay }?.id
        // `isEnabled` in every predicate below (tightened 2026-11-18): the
        // pre-v2 live shape was ENABLED rows, and migration 7 now inserts
        // DISABLED haiku/sonnet qwen rows that must never satisfy this gate
        // or its retarget actions.
        if let relayID,
           config.modelMappings.contains(where: {
               $0.matchClass == .sonnet && $0.targetModel == "GLM-5.3-Flash"
                   && $0.targetVendorID == relayID && $0.isEnabled
           }),
           config.modelMappings.contains(where: {
               $0.matchClass == .haiku && $0.targetModel == "local/qwen3.8-27b-q8"
                   && $0.isEnabled
           }) {
            if let i = config.modelMappings.firstIndex(where: {
                $0.matchClass == .sonnet && $0.targetModel == "GLM-5.3-Flash"
                    && $0.targetVendorID == relayID && $0.isEnabled
            }) {
                config.modelMappings[i].targetModel = "GLM-5.3"
            }
            if let i = config.modelMappings.firstIndex(where: {
                $0.matchClass == .haiku && $0.targetModel == "local/qwen3.8-27b-q8"
                    && $0.isEnabled
            }) {
                config.modelMappings[i].targetModel = "GLM-5.3-Flash"
                config.modelMappings[i].targetVendorID = relayID
                config.modelMappings[i].backupTargetModel = nil
                config.modelMappings[i].backupTargetVendorID = nil
            }
            for i in config.modelMappings.indices where !(config.modelMappings[i].conditions ?? []).isEmpty {
                config.modelMappings[i].isEnabled = false
            }
        }
        // Migration 6 (2026-11-18): splash off port 8000 — it collided with
        // local webservers. Retarget the splash vendor's baseURL to 8123
        // ONLY where it still equals the old default; hand-edited ports
        // survive. (The settings' `port` field itself needs no migration:
        // tolerant decode defaults it.)
        for i in config.vendors.indices
        where config.vendors[i].vendorKind != .relay
            && config.vendors[i].baseURL == "http://127.0.0.1:8000" {
            config.vendors[i].baseURL = "http://127.0.0.1:8123"
        }
        // Migration 7 (2026-11-18): qwen routing lever — two DISABLED rows
        // (haiku + sonnet → splash, local/qwen3.8-27b-q8, relay GLM-5.3-Flash
        // backup) so flipping local routing on later is a single toggle in
        // Settings → Rules. Inserted once per class: absent = insert;
        // present (disabled OR user-enabled) = gate cold.
        let splashID = config.vendors.first { $0.vendorKind != .relay }?.id
        if let splashID, let relayID {
            for cls in [ModelClass.haiku, ModelClass.sonnet] {
                let targetsSplash = config.modelMappings.contains {
                    $0.matchClass == cls && $0.targetVendorID == splashID
                }
                if !targetsSplash, let idx = config.modelMappings.firstIndex(where: {
                    $0.matchClass == cls && ($0.conditions ?? []).isEmpty
                }) {
                    let qwen = ModelMapping(
                        sourceModel: "\(cls.rawValue) (local qwen)",
                        targetModel: "local/qwen3.8-27b-q8",
                        targetVendorID: splashID,
                        backupTargetModel: "GLM-5.3-Flash",
                        backupTargetVendorID: relayID,
                        isEnabled: false, matchClass: cls)
                    config.modelMappings.insert(qwen, at: idx)
                }
            }
        }
        // Migration 8 (spec §3.6, 2026-11-19): one-shot lift of cache flags
        // from the ACTIVE profile's extraArgs into splash.storage so the
        // Storage UI is truthful. Other profiles keep theirs (extraArgs
        // still win per-profile). Guarded by `storage == nil` — a fresh
        // seed already carries storage, so only hand-written configs run it.
        if config.splash?.storage == nil {
            var settings = config.splash ?? SplashSettings()
            let idx = settings.profiles.firstIndex(where: { $0.id == settings.activeProfileID })
                ?? (settings.activeProfileID == nil ? settings.profiles.indices.first : nil)
            if let idx {
                let lifted = SplashStorage.lift(from: &settings.profiles[idx].extraArgs)
                if lifted.persistentCache || lifted.cacheDir != nil
                    || lifted.maxCacheDisk != nil || lifted.maxCacheDiskWrites != nil {
                    settings.storage = lifted
                    config.splash = settings
                }
            }
        }
        // Migration 9 (relay fidelity wave, 2026-11-20): repin the relay
        // vendor from the RESOLVED ultra URL to the CLI's baked-in
        // PRE-routing URL — endpoint routing (agent/configs) now maps
        // zcode-plan → the live ultra target per request, exactly like the
        // official CLI. Exact-value gate: only the old default rewrites, a
        // user-edited URL survives; idempotent by construction (the new
        // value never matches the gate again).
        for i in config.vendors.indices
        where config.vendors[i].vendorKind == .relay
            && config.vendors[i].baseURL == "https://zcode.z.ai/api/v1/ultra-zai/anthropic" {
            config.vendors[i].baseURL = "https://zcode.z.ai/api/v1/zcode-plan/anthropic"
        }
        return config
    }

    // MARK: - Save

    func save() {
        do {
            let data = try JSONEncoder.pretty.encode(config)
            try data.write(to: configFileURL, options: .atomic)
        } catch {
            AppLog.config.error("[ConfigStore] Failed to save config.json: \(error)")
        }
    }

    /// Save config and push updated routing snapshot to running listeners.
    /// Call this from Settings UI after any config change.
    func saveAndReload(proxyServer: ProxyServer) {
        save()
        proxyServer.updateRouting(config: config)
    }
}

// MARK: - JSONEncoder helper

private extension JSONEncoder {
    nonisolated(unsafe) static let pretty: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

import Foundation
import Testing
@testable import ZGate

extension AppConfig {
    func also(_ mutate: (inout AppConfig) -> Void) -> AppConfig {
        var copy = self; mutate(&copy); return copy
    }
}

@MainActor
@Suite struct ConfigMigrationTests {

    private func legacyConfig() -> AppConfig {
        // Shape of the installed config BEFORE this wave: no splash section,
        // auto rule without a peak twin (wave-0 matrix), no Task-7 marker.
        AppConfig.makeZGateDefaultRouting(AppConfig()).also { c in
            c.modelMappings.removeAll { $0.matchClass == .auto && $0.conditions?.isEmpty == false }
            // keep plain auto only
            c.modelMappings.removeAll { $0.sourceModel == "auto (peak hours)" }
            c.splash = nil
            c.fallbackEdgeSeeded = false
        }
    }

    @Test func defaultMatrixContainsAutoTwinBeforePlainAuto() {
        let m = AppConfig.makeZGateDefaultRouting(AppConfig()).modelMappings
        let twin = m.firstIndex { $0.sourceModel == "auto (peak hours)" }
        let plain = m.firstIndex { $0.matchClass == .auto && $0.sourceModel == "auto" }
        #expect(twin != nil && plain != nil && twin! < plain!)
        #expect(m[twin!].conditions?.first?.type == .timeWindow)
        #expect(m[twin!].targetModel == "GLM-5.3-Flash")
        // v2.1 (ruling 2026-11-17): the twin ships DISABLED — dormant lever.
        #expect(m[twin!].isEnabled == false)
    }

    // MARK: - v2.2 defaults (GLM-5.4, 2026-11-23)

    /// Enabled, condition-less class rules → target model (the plain tier
    /// rows; disabled levers and timed twins are not part of the shape).
    private func plainTierTargets(_ c: AppConfig) -> [ModelClass: String] {
        var out: [ModelClass: String] = [:]
        for m in c.modelMappings
        where m.isEnabled && m.matchClass != nil && (m.conditions ?? []).isEmpty {
            out[m.matchClass!] = m.targetModel
        }
        return out
    }

    private func setMainTierTargets(_ c: inout AppConfig, to model: String) {
        for i in c.modelMappings.indices where c.modelMappings[i].isEnabled {
            guard let cls = c.modelMappings[i].matchClass, cls != .haiku else { continue }
            if (c.modelMappings[i].conditions ?? []).isEmpty { c.modelMappings[i].targetModel = model }
        }
    }

    /// An install still on the untouched v2.1 shape: the three main tiers on
    /// GLM-5.3 at the relay, no conditions, no backups.
    private func untouchedV21Config() -> AppConfig {
        AppConfig.makeZGateDefaultRouting(AppConfig()).also { c in
            setMainTierTargets(&c, to: "GLM-5.3")
        }
    }

    @Test func defaultMatrixTargetsGLM54ForTheMainTiers() {
        let targets = plainTierTargets(AppConfig.makeZGateDefaultRouting(AppConfig()))
        #expect(targets[.opus] == "GLM-5.4")
        #expect(targets[.sonnet] == "GLM-5.4")
        #expect(targets[.auto] == "GLM-5.4")
        // The fast tier stays on flash.
        #expect(targets[.haiku] == "GLM-5.3-Flash")
    }

    @Test func migration12RetargetsTheUntouchedV21Shape() {
        let config = untouchedV21Config()
        let beforeIDs = config.modelMappings.map(\.id)
        let after = ConfigStore.applyMigrations(config)
        let targets = plainTierTargets(after)
        #expect(targets[.opus] == "GLM-5.4")
        #expect(targets[.sonnet] == "GLM-5.4")
        #expect(targets[.auto] == "GLM-5.4")
        #expect(targets[.haiku] == "GLM-5.3-Flash")
        // Same rows, same order.
        #expect(after.modelMappings.map(\.id) == beforeIDs)
        // Idempotent: a second pass changes nothing.
        let twice = ConfigStore.applyMigrations(after)
        #expect(twice.modelMappings.map(\.targetModel) == after.modelMappings.map(\.targetModel))
    }

    /// Any edit to those rows opts the WHOLE set out — a pinned model, a
    /// backup target, a condition, or an extra rule in a main tier.
    @Test func migration12LeavesEditedRulesAlone() {
        let relayID = untouchedV21Config().vendors.first { $0.vendorKind == .relay }?.id
        let edited: [(String, (inout AppConfig) -> Void)] = [
            ("opus pinned by hand", { c in
                if let i = c.modelMappings.firstIndex(where: { $0.matchClass == .opus && $0.isEnabled }) {
                    c.modelMappings[i].targetModel = "GLM-4.6"
                }
            }),
            ("sonnet carries a backup", { c in
                if let i = c.modelMappings.firstIndex(where: { $0.matchClass == .sonnet && $0.isEnabled }) {
                    c.modelMappings[i].backupTargetVendorID = relayID
                }
            }),
            ("auto carries a condition", { c in
                if let i = c.modelMappings.firstIndex(where: { $0.matchClass == .auto && $0.isEnabled }) {
                    c.modelMappings[i].conditions = [RuleCondition(
                        type: .quotaBelow, percent: 20)]
                }
            }),
            ("an extra enabled opus row", { c in
                if let opus = c.modelMappings.first(where: { $0.matchClass == .opus && $0.isEnabled }) {
                    c.modelMappings.append(ModelMapping(
                        sourceModel: "opus (second)", targetModel: "GLM-5.3",
                        targetVendorID: relayID ?? UUID(), matchClass: .opus))
                }
            }),
        ]
        for (name, edit) in edited {
            let config = untouchedV21Config().also(edit)
            let after = ConfigStore.applyMigrations(config)
            // Not one row is retargeted.
            #expect(after.modelMappings.map(\.targetModel) == config.modelMappings.map(\.targetModel), "\(name)")
        }
    }

    @Test func migrationInsertsTwinIntoLegacyConfig() {
        let before = legacyConfig()
        let beforeIDs = before.modelMappings.map(\.id)
        let after = ConfigStore.applyMigrations(before)
        let m = after.modelMappings
        let twin = m.firstIndex { $0.sourceModel == "auto (peak hours)" }
        let plain = m.firstIndex { $0.matchClass == .auto && $0.sourceModel == "auto" }
        #expect(twin != nil && plain != nil && twin! < plain!)
        // v2.1: the inserted twin is DISABLED (dormant lever default).
        #expect(m[twin!].isEnabled == false)
        // existing rules untouched, same order, same ids
        #expect(m.filter { $0.sourceModel != "auto (peak hours)" }.map(\.id) == beforeIDs)
    }

    @Test func migrationIsIdempotent() {
        let once = ConfigStore.applyMigrations(legacyConfig())
        let twice = ConfigStore.applyMigrations(once)
        #expect(once.modelMappings.map(\.id) == twice.modelMappings.map(\.id))
        #expect(once.modelMappings.count == twice.modelMappings.count)
    }

    @Test func migrationSeedsSplashOnlyWhenAbsent() {
        var c = legacyConfig()
        c.splash = nil
        #expect(ConfigStore.applyMigrations(c).splash?.profiles.first?.model == "local/qwen3.8-27b-q8")
        var existing = legacyConfig()
        var custom = SplashSettings.defaultSeeded()
        custom.keepRunning = false
        existing.splash = custom
        #expect(ConfigStore.applyMigrations(existing).splash == custom)
    }

    // MARK: - Migration 5 (v2.1 one-time pass, ruling 2026-11-17)

    @Test func migrationOneTimeV2Pass() {
        // Legacy shape: old tier targets + ENABLED opus twin (the live config).
        var before = AppConfig.makeZGateDefaultRouting(AppConfig())
        before.modelMappings.removeAll { !($0.conditions ?? []).isEmpty }  // wave-0: no twins
        let relayID = before.vendors.first { $0.vendorKind == .relay }!.id
        let splashID = before.vendors.first { $0.name.lowercased().contains("splash") }!.id
        // Plain-row lookups: the default matrix's qwen levers now precede
        // the plain tier rows, so a bare matchClass lookup would edit them.
        if let i = before.modelMappings.firstIndex(where: {
            $0.matchClass == .sonnet && $0.targetModel != "local/qwen3.8-27b-q8"
        }) {
            before.modelMappings[i].targetModel = "GLM-5.3-Flash"
            before.modelMappings[i].targetVendorID = relayID
        }
        if let i = before.modelMappings.firstIndex(where: {
            $0.matchClass == .haiku && $0.targetModel != "local/qwen3.8-27b-q8"
        }) {
            before.modelMappings[i].targetModel = "local/qwen3.8-27b-q8"
            before.modelMappings[i].targetVendorID = splashID
            before.modelMappings[i].backupTargetModel = "GLM-5.3-Flash"
            before.modelMappings[i].backupTargetVendorID = relayID
        }
        // The live wave-1 install left its opus twin ENABLED — re-add it
        // before plain opus so the twin-disable loop has real work (strip +
        // migration 4's disabled insert alone would leave nothing to pin).
        if let plainOpus = before.modelMappings.firstIndex(where: {
            $0.matchClass == .opus && ($0.conditions ?? []).isEmpty
        }) {
            before.modelMappings.insert(
                ModelMapping(
                    sourceModel: "opus (peak hours)", targetModel: "GLM-5.3-Flash",
                    targetVendorID: relayID, isEnabled: true, matchClass: .opus,
                    conditions: [RuleCondition(
                        type: .timeWindow, days: .weekdays,
                        from: "07:00", to: "11:00", tz: "Europe/Paris")]),
                at: plainOpus)
        }
        let after = ConfigStore.applyMigrations(before)
        let sonnet = after.modelMappings.first { $0.matchClass == .sonnet && $0.targetModel != "local/qwen3.8-27b-q8" }!
        #expect(sonnet.targetModel == "GLM-5.3")
        let haiku = after.modelMappings.first { $0.matchClass == .haiku && $0.targetModel != "local/qwen3.8-27b-q8" }!
        #expect(haiku.targetModel == "GLM-5.3-Flash" && haiku.backupTargetModel == nil)
        // Migration 4 inserted the auto twin (disabled); v2 pass disabled any twins.
        let twins = after.modelMappings.filter { !($0.conditions ?? []).isEmpty }
        #expect(!twins.isEmpty && twins.allSatisfy { $0.isEnabled == false })
        // One-time: a second apply is a no-op even if the user re-enables a twin.
        var reenabled = after
        if let i = reenabled.modelMappings.firstIndex(where: { $0.sourceModel == "opus (peak hours)" || $0.sourceModel == "auto (peak hours)" }) {
            reenabled.modelMappings[i].isEnabled = true
        }
        let third = ConfigStore.applyMigrations(reenabled)
        #expect(third.modelMappings.filter { !($0.conditions ?? []).isEmpty }.contains { $0.isEnabled })
        // Custom sonnet target survives.
        var custom = after
        if let i = custom.modelMappings.firstIndex(where: { $0.matchClass == .sonnet }) {
            custom.modelMappings[i].targetModel = "GLM-5.3-Flash"
        }
        #expect(ConfigStore.applyMigrations(custom).modelMappings.first { $0.matchClass == .sonnet }?.targetModel == "GLM-5.3-Flash")
    }

    // MARK: - Launch-path persistence (Task 11 fix round 1)

    private func tempConfigURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zgate-configstore-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    /// The wave-1 install's on-disk shape: no splash section, no auto twin,
    /// sonnet → relay GLM-5.3-Flash, haiku → splash q8 with relay backup,
    /// opus peak twin present but disabled.
    private func wave1LiveConfig() -> AppConfig {
        var before = AppConfig.makeZGateDefaultRouting(AppConfig())
        before.modelMappings.removeAll { !($0.conditions ?? []).isEmpty }
        let relayID = before.vendors.first { $0.vendorKind == .relay }!.id
        let splashID = before.vendors.first { $0.name.lowercased().contains("splash") }!.id
        // Plain-row lookups: the default matrix's qwen levers now precede
        // the plain tier rows, so a bare matchClass lookup would edit them.
        if let i = before.modelMappings.firstIndex(where: {
            $0.matchClass == .sonnet && $0.targetModel != "local/qwen3.8-27b-q8"
        }) {
            before.modelMappings[i].targetModel = "GLM-5.3-Flash"
            before.modelMappings[i].targetVendorID = relayID
        }
        if let i = before.modelMappings.firstIndex(where: {
            $0.matchClass == .haiku && $0.targetModel != "local/qwen3.8-27b-q8"
        }) {
            before.modelMappings[i].targetModel = "local/qwen3.8-27b-q8"
            before.modelMappings[i].targetVendorID = splashID
            before.modelMappings[i].backupTargetModel = "GLM-5.3-Flash"
            before.modelMappings[i].backupTargetVendorID = relayID
        }
        if let plainOpus = before.modelMappings.firstIndex(where: {
            $0.matchClass == .opus && ($0.conditions ?? []).isEmpty
        }) {
            before.modelMappings.insert(
                ModelMapping(
                    sourceModel: "opus (peak hours)", targetModel: "GLM-5.3-Flash",
                    targetVendorID: relayID, isEnabled: false, matchClass: .opus,
                    conditions: [RuleCondition(
                        type: .timeWindow, days: .weekdays,
                        from: "07:00", to: "11:00", tz: "Europe/Paris")]),
                at: plainOpus)
        }
        before.splash = nil
        return before
    }

    @Test func storePersistsLaunchMigrationsToDisk() throws {
        let url = try tempConfigURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(wave1LiveConfig()).write(to: url)

        let store = ConfigStore(configFileURL: url)  // the launch path, incl. persistence

        // The file ON DISK now carries the post-migration shape.
        let reread = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))
        #expect(reread.splash != nil)  // migration 3 seeded + persisted
        #expect(reread.modelMappings.contains { $0.sourceModel == "auto (peak hours)" && !$0.isEnabled })  // migration 4
        #expect(reread.modelMappings.first { $0.matchClass == .sonnet && $0.targetModel != "local/qwen3.8-27b-q8" }?.targetModel == "GLM-5.3")  // migration 5
        #expect(reread.modelMappings.first { $0.matchClass == .haiku && $0.targetModel != "local/qwen3.8-27b-q8" }?.targetModel == "GLM-5.3-Flash")
        #expect(reread.modelMappings.first { $0.matchClass == .haiku && $0.targetModel != "local/qwen3.8-27b-q8" }?.backupTargetModel == nil)
        #expect(reread.modelMappings.filter { !($0.conditions ?? []).isEmpty }.allSatisfy { !$0.isEnabled })
        // The store serves exactly what it persisted.
        #expect(store.config.modelMappings.map(\.id) == reread.modelMappings.map(\.id))

        // Write-once: relaunching over the migrated file rewrites nothing —
        // byte-identical AND untouched mtime (an unconditional resave would
        // keep the bytes but bump the file; .atomic writes rename-replace).
        let bytes = try Data(contentsOf: url)
        let mtimeBefore = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        _ = ConfigStore(configFileURL: url)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == mtimeBefore)
    }

    @Test func storeFreshInstallWritesDefaultsOnce() throws {
        let url = try tempConfigURL()  // directory exists, no config.json yet
        let store = ConfigStore(configFileURL: url)
        #expect(store.didResetFromCorrupt == false)
        let bytes = try Data(contentsOf: url)  // defaults were written
        #expect(try JSONDecoder().decode(AppConfig.self, from: bytes).modelMappings.last?.catchAll == true)
        // Second launch performs migration 11's ONE-TIME off-peak seed (the
        // fresh-write default matrix deliberately does not carry the row —
        // seeding is migration 11's job, not makeDefault's), then never
        // rewrites again: the third launch is byte-identical with untouched
        // mtime (the write-once contract, generalized past the seed).
        let seeded = ConfigStore(configFileURL: url)
        let seededBytes = try Data(contentsOf: url)
        #expect(try JSONDecoder().decode(AppConfig.self, from: seededBytes).offPeakVendorSeeded)
        #expect(seeded.config.vendors.contains { $0.vendorKind == .offPeak })
        let mtimeBefore = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        _ = ConfigStore(configFileURL: url)
        #expect(try Data(contentsOf: url) == seededBytes)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == mtimeBefore)
    }

    @Test func storeCorruptConfigResetsAndFlags() throws {
        let url = try tempConfigURL()
        try Data("not json".utf8).write(to: url)
        let store = ConfigStore(configFileURL: url)
        #expect(store.didResetFromCorrupt == true)
        let reread = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))
        #expect(reread.modelMappings.last?.catchAll == true)
    }

    // MARK: - Splash port + qwen rules (post-2.6(3) wave, 2026-11-18)

    /// Old splash sections predate the `port` field — tolerant decode must
    /// default it to 8123 (the new default; 8000 conflicted with local
    /// webservers), not fail the whole config.
    @Test func splashSettingsDecodeDefaultsPort() throws {
        let legacyJSON = """
        {"keepRunning":true,"activeProfileID":null,"profiles":[],"binaryPathOverride":null}
        """
        let legacy = try JSONDecoder().decode(SplashSettings.self, from: Data(legacyJSON.utf8))
        #expect(legacy.port == 8123)
        let fresh = SplashSettings(keepRunning: true, profiles: [])
        #expect(fresh.port == 8123)
        let custom = SplashSettings(keepRunning: false, profiles: [], port: 9001)
        #expect(custom.port == 9001)
        // Round-trip keeps the stored port.
        let data = try JSONEncoder().encode(custom)
        #expect(try JSONDecoder().decode(SplashSettings.self, from: data).port == 9001)
    }

    /// Serve argv carries the configured port unless the profile already
    /// pins one (either `--port X` or `--port=X` — an explicit profile port
    /// wins, preserving extraArgs' documented override semantics).
    @Test func serveArgumentsAppendPortUnlessProfilePinsOne() {
        let plain = SplashProfile(name: "p", model: "m")
        #expect(plain.serveArguments(port: 8123).suffix(2) == ["--port", "8123"])
        #expect(plain.serveArguments(port: 8123).first == "serve")

        let space = SplashProfile(name: "p", model: "m", extraArgs: ["--port", "9001"])
        #expect(space.serveArguments(port: 8123) == space.launchArguments())  // no double append

        let equals = SplashProfile(name: "p", model: "m", extraArgs: ["--port=9001"])
        #expect(equals.serveArguments(port: 8123) == equals.launchArguments())  // = form respected too
    }

    private func configWithSplashVendor(baseURL: String) -> AppConfig {
        var config = AppConfig.makeZGateDefaultRouting(AppConfig())
        for i in config.vendors.indices where config.vendors[i].vendorKind != .relay {
            config.vendors[i].baseURL = baseURL
        }
        return config
    }

    /// Migration 6: the splash vendor's baseURL retargets from the old
    /// :8000 default to :8123 — but ONLY where it still equals the old
    /// default; a hand-edited port survives untouched.
    @Test func migration6RetargetsOnlyOldDefaultSplashPort() {
        var migrated = ConfigStore.applyMigrations(configWithSplashVendor(baseURL: "http://127.0.0.1:8000"))
        let splash = migrated.vendors.first { $0.vendorKind != .relay }
        #expect(splash?.baseURL == "http://127.0.0.1:8123")

        migrated = ConfigStore.applyMigrations(configWithSplashVendor(baseURL: "http://127.0.0.1:9999"))
        #expect(migrated.vendors.first { $0.vendorKind != .relay }?.baseURL == "http://127.0.0.1:9999")

        // Idempotent: a second pass changes nothing.
        let once = ConfigStore.applyMigrations(configWithSplashVendor(baseURL: "http://127.0.0.1:8000"))
        #expect(ConfigStore.applyMigrations(once).vendors.first { $0.vendorKind != .relay }?.baseURL == "http://127.0.0.1:8123")
    }

    /// Migration 7: two DISABLED qwen rows (haiku + sonnet → splash,
    /// local/qwen3.8-27b-q8, relay GLM-5.3-Flash backup) inserted once;
    /// enabling them later survives (gate goes cold once the rows exist).
    /// Base strips the default matrix's qwen rows to exercise the insert
    /// path a pre-defaults config (e.g. the 2026-11-17 live config) takes.
    @Test func migration7InsertsDisabledQwenRowsOnce() {
        var stripped = configWithSplashVendor(baseURL: "http://127.0.0.1:8123")
        stripped.modelMappings.removeAll { $0.targetModel == "local/qwen3.8-27b-q8" }
        let migrated = ConfigStore.applyMigrations(stripped)

        func qwenRows(_ c: AppConfig) -> [ModelMapping] {
            c.modelMappings.filter { $0.targetModel == "local/qwen3.8-27b-q8" }
        }
        let rows = qwenRows(migrated)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { !$0.isEnabled })
        #expect(Set(rows.map(\.matchClass)) == [.haiku, .sonnet])
        #expect(rows.allSatisfy { $0.backupTargetModel == "GLM-5.3-Flash" })

        // Idempotent + enabling survives: flip one on, re-run, still 2 rows.
        var enabled = migrated
        if let i = enabled.modelMappings.firstIndex(where: { $0.targetModel == "local/qwen3.8-27b-q8" && $0.matchClass == .sonnet }) {
            enabled.modelMappings[i].isEnabled = true
        }
        let again = ConfigStore.applyMigrations(enabled)
        #expect(qwenRows(again).count == 2)
        #expect(qwenRows(again).contains { $0.matchClass == .sonnet && $0.isEnabled })
    }

    /// Migration 5's retarget must never touch the DISABLED qwen rows
    /// migration 7 inserts: its gate and action predicates accept only
    /// ENABLED rows (the pre-v2 live shape was enabled).
    @Test func migration5IgnoresDisabledQwenRows() {
        var config = configWithSplashVendor(baseURL: "http://127.0.0.1:8123")
        // Simulate the dangerous state: sonnet row back at the pre-v2
        // target (gate half-warm) while a disabled qwen haiku row exists.
        let relayID = config.vendors.first { $0.vendorKind == .relay }!.id
        let splashID = config.vendors.first { $0.vendorKind != .relay }!.id
        if let i = config.modelMappings.firstIndex(where: { $0.matchClass == .sonnet }) {
            config.modelMappings[i].targetModel = "GLM-5.3-Flash"
            config.modelMappings[i].targetVendorID = relayID
        }
        config.modelMappings.insert(
            ModelMapping(
                sourceModel: "haiku (local qwen)", targetModel: "local/qwen3.8-27b-q8",
                targetVendorID: splashID, isEnabled: false, matchClass: .haiku),
            at: 0)
        let migrated = ConfigStore.applyMigrations(config)
        let disabledQwen = migrated.modelMappings.filter { $0.targetModel == "local/qwen3.8-27b-q8" }
        #expect(disabledQwen.allSatisfy { $0.targetModel == "local/qwen3.8-27b-q8" })
        #expect(!disabledQwen.isEmpty)
    }

    // MARK: - Migration 8 (splash storage lift, 2026-11-19)

    /// Migration 8: one-shot lift of the owner's hand-written cache flags
    /// (spec §2/§3.6) out of the ACTIVE profile's extraArgs into
    /// splash.storage. `applyMigrations` mutates its class argument in place,
    /// so the one-shot check compares the splash VALUE across a second pass.
    @Test func migration8LiftsActiveProfileCacheFlags() {
        var cfg = AppConfig.makeDefault()
        cfg.splash?.storage = nil
        // active profile carries the owner's hand-written flags (spec §2)
        if let i = cfg.splash?.profiles.firstIndex(where: { $0.id == cfg.splash?.activeProfileID }) {
            cfg.splash?.profiles[i].extraArgs = ["--persistent-cache", "--cache-dir", "/v/s", "--max-cache-disk", "20G"]
        }
        let out = ConfigStore.applyMigrations(cfg)
        #expect(out.splash?.storage?.cacheDir == "/v/s")
        #expect(out.splash?.storage?.maxCacheDisk == "20G")
        let active = out.splash!.profiles.first { $0.id == out.splash!.activeProfileID }!
        #expect(!active.extraArgs.contains("--persistent-cache"))
        // one-shot: running again changes nothing
        let snapshot = out.splash
        _ = ConfigStore.applyMigrations(out)
        #expect(out.splash == snapshot)
    }

    // MARK: - Migration 9 (relay pre-routing URL pin, 2026-11-20; reverted
    // same day by live probe A — see ConfigStore.swift's comment)

    /// The briefly-shipped wave shape: relay vendor repinned to the CLI's
    /// pre-routing URL by the reverted migration (what a main-branch build
    /// between the wave and the revert wrote).
    private func preRoutingPinnedConfig() -> AppConfig {
        var config = AppConfig.makeZGateDefaultRouting(AppConfig())
        for i in config.vendors.indices where config.vendors[i].vendorKind == .relay {
            config.vendors[i].baseURL = "https://zcode.z.ai/api/v1/zcode-plan/anthropic"
        }
        return config
    }

    /// Migration 9 (reverted direction): the relay vendor's baseURL heals
    /// back to the RESOLVED ultra URL — but ONLY where it still equals the
    /// reverted-build pin; a user-edited URL survives, and the pass is
    /// idempotent.
    @Test func migration9HealsPreRoutingPinBackToUltra() {
        let migrated = ConfigStore.applyMigrations(preRoutingPinnedConfig())
        let relay = migrated.vendors.first { $0.vendorKind == .relay }
        #expect(relay?.baseURL == "https://zcode.z.ai/api/v1/ultra-zai/anthropic")

        // User-edited URL: untouched (any other value).
        var edited = preRoutingPinnedConfig()
        for i in edited.vendors.indices where edited.vendors[i].vendorKind == .relay {
            edited.vendors[i].baseURL = "https://zcode.z.ai/api/v1/custom/anthropic"
        }
        #expect(ConfigStore.applyMigrations(edited).vendors.first { $0.vendorKind == .relay }?.baseURL
            == "https://zcode.z.ai/api/v1/custom/anthropic")

        // Fresh defaults already carry the ultra pin; a second pass is a no-op.
        #expect(AppConfig.makeDefault().vendors.first { $0.vendorKind == .relay }?.baseURL
            == "https://zcode.z.ai/api/v1/ultra-zai/anthropic")
        #expect(ConfigStore.applyMigrations(migrated).vendors.first { $0.vendorKind == .relay }?.baseURL
            == "https://zcode.z.ai/api/v1/ultra-zai/anthropic")
    }

    /// The launch path persists migration 9 to disk like the earlier
    /// launch-path migrations.
    @Test func storePersistsMigration9ToDisk() throws {
        let url = try tempConfigURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(preRoutingPinnedConfig()).write(to: url)

        _ = ConfigStore(configFileURL: url)  // launch path, incl. persistence

        let reread = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))
        #expect(reread.vendors.first { $0.vendorKind == .relay }?.baseURL
            == "https://zcode.z.ai/api/v1/ultra-zai/anthropic")
    }
}

// MARK: - Credential store base setting (item 2)

extension ConfigMigrationTests {

    @Test func credentialStoreBaseDefaultsNilAndRoundTrips() throws {
        // Existing live configs have no key — nil = shared default store.
        let decoded = try JSONDecoder().decode(
            AppConfig.self, from: Data(#"{"vendors":[],"clients":[]}"#.utf8))
        #expect(decoded.credentialStoreBase == nil)

        var config = AppConfig()
        config.credentialStoreBase = "~/.zcode-scratch-v3"
        let reloaded = try JSONDecoder().decode(
            AppConfig.self, from: JSONEncoder().encode(config))
        #expect(reloaded.credentialStoreBase == "~/.zcode-scratch-v3")

        // nil is omitted from the encoded form — existing configs stay stable.
        let plain = try String(data: JSONEncoder().encode(AppConfig()), encoding: .utf8) ?? ""
        #expect(!plain.contains("credentialStoreBase"))
    }
}

// MARK: - Migration 10 (relay fidelity Task 7: fallback edge)

extension ConfigMigrationTests {

    /// A config in the pre-Task-7 shape: default matrix minus the fallback
    /// vendor, the catch-all's backup, and the migration marker.
    private func preTask7Config() -> AppConfig {
        legacyConfig().also { c in
            c.vendors.removeAll { ApiKeyMinter.isFallbackEdge($0.baseURL) }
            if let i = c.modelMappings.firstIndex(where: { $0.catchAll }) {
                c.modelMappings[i].backupTargetVendorID = nil
                c.modelMappings[i].backupTargetModel = nil
            }
            c.fallbackEdgeSeeded = false
        }
    }

    @Test func defaultRoutingSeedsFallbackEdgeAndCatchAllBackup() throws {
        let config = AppConfig.makeZGateDefaultRouting(AppConfig())
        let edge = config.vendors.first { ApiKeyMinter.isFallbackEdge($0.baseURL) }
        let edgeVendor = try #require(edge)
        #expect(edgeVendor.vendorKind == .anthropic)
        #expect(edgeVendor.apiKey.isEmpty)  // minted lazily at runtime
        #expect(edgeVendor.stripsClaudeOnlyRequestFields)
        #expect(edgeVendor.applyGLMCanonicalization)
        let catchAll = config.modelMappings.first { $0.catchAll }
        #expect(catchAll?.backupTargetVendorID == edgeVendor.id)
        #expect(catchAll?.backupTargetModel == catchAll?.targetModel)
    }

    @Test func migrationSeedsFallbackVendorAndCatchAllBackup() throws {
        let before = preTask7Config()
        let after = ConfigStore.applyMigrations(before)

        let edge = after.vendors.first { ApiKeyMinter.isFallbackEdge($0.baseURL) }
        let edgeVendor = try #require(edge)
        #expect(edgeVendor.vendorKind == .anthropic)
        #expect(edgeVendor.stripsClaudeOnlyRequestFields)
        #expect(edgeVendor.applyGLMCanonicalization)
        #expect(edgeVendor.readTimeoutSeconds == 300)

        let catchAll = after.modelMappings.first { $0.catchAll }
        #expect(catchAll?.backupTargetVendorID == edgeVendor.id)
        #expect(catchAll?.backupTargetModel == catchAll?.targetModel)
        // Everything else about the catch-all is untouched.
        if let beforeRule = before.modelMappings.first(where: { $0.catchAll }),
           let afterRule = after.modelMappings.first(where: { $0.catchAll }) {
            #expect(afterRule.id == beforeRule.id)
            #expect(afterRule.targetModel == beforeRule.targetModel)
            #expect(afterRule.targetVendorID == beforeRule.targetVendorID)
            #expect(afterRule.isEnabled == beforeRule.isEnabled)
        }
    }

    @Test func fallbackMigrationIsIdempotent() {
        let before = preTask7Config()
        #expect(before.fallbackEdgeSeeded == false)
        let once = ConfigStore.applyMigrations(before)
        let twice = ConfigStore.applyMigrations(once)
        #expect(once.fallbackEdgeSeeded == true)  // first application records the marker
        #expect(twice.fallbackEdgeSeeded == true)
        #expect(once.vendors.map(\.id) == twice.vendors.map(\.id))
        #expect(once.vendors.count == twice.vendors.count)
        #expect(once.modelMappings.map(\.id) == twice.modelMappings.map(\.id))
        #expect(once.modelMappings.count == twice.modelMappings.count)
        let edgeCount = twice.vendors.filter { ApiKeyMinter.isFallbackEdge($0.baseURL) }.count
        #expect(edgeCount == 1)
    }

    @Test func fallbackEdgeMigrationRunOnceUserDeletionSticks() throws {
        // Fix round 1, ruling 2: after the first application a user-removed
        // edge vendor and a cleared catch-all backup must STAY removed —
        // presence-gating used to resurrect both on the next launch.
        let applied = ConfigStore.applyMigrations(preTask7Config())
        #expect(applied.fallbackEdgeSeeded)
        var userRemoved = applied
        userRemoved.vendors.removeAll { ApiKeyMinter.isFallbackEdge($0.baseURL) }
        if let i = userRemoved.modelMappings.firstIndex(where: { $0.catchAll }) {
            userRemoved.modelMappings[i].backupTargetVendorID = nil
            userRemoved.modelMappings[i].backupTargetModel = nil
        }

        let relaunched = ConfigStore.applyMigrations(userRemoved)

        #expect(!relaunched.vendors.contains { ApiKeyMinter.isFallbackEdge($0.baseURL) })
        let catchAll = relaunched.modelMappings.first { $0.catchAll }
        #expect(catchAll?.backupTargetVendorID == nil)
        #expect(catchAll?.backupTargetModel == nil)
        // Round-trip keeps the marker: the deletion survives the disk too.
        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(relaunched))
        #expect(decoded.fallbackEdgeSeeded)
        #expect(!decoded.vendors.contains { ApiKeyMinter.isFallbackEdge($0.baseURL) })
    }

    @Test func fallbackEdgeMarkerEncodesOnlyWhenSet() throws {
        // Fresh AppConfig() omits the key (byte-stable pre-fix configs);
        // the seeded default matrix carries it (a fresh install's second
        // launch never rewrites).
        let plain = try String(data: JSONEncoder().encode(AppConfig()), encoding: .utf8) ?? ""
        #expect(!plain.contains("fallbackEdgeSeeded"))
        let seeded = try String(
            data: JSONEncoder().encode(AppConfig.makeZGateDefaultRouting(AppConfig())),
            encoding: .utf8) ?? ""
        #expect(seeded.contains("fallbackEdgeSeeded"))
        let decoded = try JSONDecoder().decode(
            AppConfig.self, from: Data(#"{"vendors":[],"clients":[]}"#.utf8))
        #expect(decoded.fallbackEdgeSeeded == false)
    }

    @Test func migrationReusesAUserEditedFallbackVendorWithoutDuplicating() {
        var edited = preTask7Config()
        let userEdge = Vendor(
            name: "my own edge", baseURL: ApiKeyMinter.fallbackBaseURL,
            apiKey: "ak.existing", readTimeoutSeconds: 42)
        edited.vendors.append(userEdge)

        let after = ConfigStore.applyMigrations(edited)

        let edges = after.vendors.filter { ApiKeyMinter.isFallbackEdge($0.baseURL) }
        #expect(edges.count == 1)
        #expect(edges.first?.id == userEdge.id)
        #expect(edges.first?.apiKey == "ak.existing")  // never clobbered
        #expect(edges.first?.readTimeoutSeconds == 42)
        let catchAll = after.modelMappings.first { $0.catchAll }
        #expect(catchAll?.backupTargetVendorID == userEdge.id)  // attached to the existing row
    }

    @Test func migrationLeavesAUserConfiguredCatchAllBackupAlone() {
        var edited = preTask7Config()
        let ownBackup = Vendor(name: "my backup", baseURL: "https://api.deepseek.com/anthropic", apiKey: "k")
        edited.vendors.append(ownBackup)
        if let i = edited.modelMappings.firstIndex(where: { $0.catchAll }) {
            edited.modelMappings[i].backupTargetVendorID = ownBackup.id
            edited.modelMappings[i].backupTargetModel = "deepseek-v4-pro[1m]"
        }

        let after = ConfigStore.applyMigrations(edited)

        let catchAll = after.modelMappings.first { $0.catchAll }
        #expect(catchAll?.backupTargetVendorID == ownBackup.id)
        #expect(catchAll?.backupTargetModel == "deepseek-v4-pro[1m]")
        // The fallback vendor is still seeded (available for manual use),
        // it just does not displace the user's backup.
        #expect(after.vendors.contains { ApiKeyMinter.isFallbackEdge($0.baseURL) })
    }

    @Test func migrationWithoutACatchAllRuleSeedsOnlyTheVendor() {
        var noCatchAll = preTask7Config()
        noCatchAll.modelMappings.removeAll { $0.catchAll }

        let after = ConfigStore.applyMigrations(noCatchAll)

        #expect(after.vendors.contains { ApiKeyMinter.isFallbackEdge($0.baseURL) })
        #expect(!after.modelMappings.contains { $0.catchAll })
    }
}

// MARK: - Migration 11 (off-peak wave 2, Task 2: seeded rule-target vendor)

extension ConfigMigrationTests {

    /// A config in the pre-wave-2 shape: fully migrated except it carries no
    /// off-peak vendor and no migration-11 marker.
    private func preOffPeakConfig() -> AppConfig {
        legacyConfig().also { c in
            c.vendors.removeAll { $0.vendorKind == .offPeak }
            c.offPeakVendorSeeded = false
        }
    }

    @Test func migration11SeedsOffPeakVendorOnceAndNeverResurrects() throws {
        let once = ConfigStore.applyMigrations(preOffPeakConfig())
        let seeded = try #require(once.vendors.first { $0.vendorKind == .offPeak })
        #expect(once.offPeakVendorSeeded)  // first application records the marker
        #expect(seeded.name == "ZCode Off-Peak")
        #expect(seeded.baseURL == OffPeakConfig.defaultOrigin)
        #expect(seeded.apiKey.isEmpty)  // ticket plane: auth is the plan-JWT chain, not a stored key
        #expect(seeded.connectTimeoutSeconds == 15)
        #expect(seeded.readTimeoutSeconds == 5400)  // maxWait 60 min × 60 + 30 min headroom (OffPeakTarget's data-plane bound)
        // Seeding is inert: no rule gains the vendor as target or backup —
        // the row changes no routing until the user attaches it to a rule.
        #expect(once.modelMappings.allSatisfy {
            $0.targetVendorID != seeded.id && $0.backupTargetVendorID != seeded.id
        })

        // User deletes the row, app relaunches: the marker is set, so the
        // deletion sticks — migration 11 never resurrects the row.
        var deleted = once
        deleted.vendors.removeAll { $0.vendorKind == .offPeak }
        let twice = ConfigStore.applyMigrations(deleted)
        #expect(twice.offPeakVendorSeeded)
        #expect(!twice.vendors.contains { $0.vendorKind == .offPeak })
    }

    @Test func migration11DoesNotDuplicateAnExistingOffPeakVendor() {
        // A user-created off-peak-kind row already present on the first
        // application: reused (marker set), never duplicated.
        var edited = preOffPeakConfig()
        let own = Vendor(
            name: "my off-peak", baseURL: "https://example.invalid",
            apiKey: "", vendorKind: .offPeak)
        edited.vendors.append(own)

        let after = ConfigStore.applyMigrations(edited)

        let rows = after.vendors.filter { $0.vendorKind == .offPeak }
        #expect(rows.count == 1)
        #expect(rows.first?.id == own.id)
        #expect(after.offPeakVendorSeeded)
        #expect(!after.vendors.contains { $0.name == "ZCode Off-Peak" })
    }

    @Test func offPeakVendorMarkerEncodesOnlyWhenSet() throws {
        // Fresh AppConfig() omits the key (byte-stable legacy configs); the
        // marker records itself only after migration 11's first application.
        let plain = try String(data: JSONEncoder().encode(AppConfig()), encoding: .utf8) ?? ""
        #expect(!plain.contains("offPeakVendorSeeded"))
        var seeded = AppConfig()
        seeded.offPeakVendorSeeded = true
        let recorded = try String(data: JSONEncoder().encode(seeded), encoding: .utf8) ?? ""
        #expect(recorded.contains("offPeakVendorSeeded"))
        // A legacy config without the key decodes the marker false.
        let decoded = try JSONDecoder().decode(
            AppConfig.self, from: Data(#"{"vendors":[],"clients":[]}"#.utf8))
        #expect(decoded.offPeakVendorSeeded == false)
    }
}

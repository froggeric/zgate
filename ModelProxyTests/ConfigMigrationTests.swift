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
        // auto rule without a peak twin (wave-0 matrix).
        AppConfig.makeZGateDefaultRouting(AppConfig()).also { c in
            c.modelMappings.removeAll { $0.matchClass == .auto && $0.conditions?.isEmpty == false }
            // keep plain auto only
            c.modelMappings.removeAll { $0.sourceModel == "auto (peak hours)" }
            c.splash = nil
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
        if let i = before.modelMappings.firstIndex(where: { $0.matchClass == .sonnet }) {
            before.modelMappings[i].targetModel = "GLM-5.3-Flash"
            before.modelMappings[i].targetVendorID = relayID
        }
        if let i = before.modelMappings.firstIndex(where: { $0.matchClass == .haiku }) {
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
        let sonnet = after.modelMappings.first { $0.matchClass == .sonnet }!
        #expect(sonnet.targetModel == "GLM-5.3")
        let haiku = after.modelMappings.first { $0.matchClass == .haiku }!
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
        if let i = before.modelMappings.firstIndex(where: { $0.matchClass == .sonnet }) {
            before.modelMappings[i].targetModel = "GLM-5.3-Flash"
            before.modelMappings[i].targetVendorID = relayID
        }
        if let i = before.modelMappings.firstIndex(where: { $0.matchClass == .haiku }) {
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
        #expect(reread.modelMappings.first { $0.matchClass == .sonnet }?.targetModel == "GLM-5.3")  // migration 5
        #expect(reread.modelMappings.first { $0.matchClass == .haiku }?.targetModel == "GLM-5.3-Flash")
        #expect(reread.modelMappings.first { $0.matchClass == .haiku }?.backupTargetModel == nil)
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
        // Second launch rewrites nothing (byte-identical, untouched mtime).
        let mtimeBefore = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        _ = ConfigStore(configFileURL: url)
        #expect(try Data(contentsOf: url) == bytes)
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
}

import Foundation
import Testing
@testable import ZGate

/// Migration 13: the `local` routing rule behind the configurator's local
/// model id. Seeded once — a user who deletes the row keeps it deleted.
@MainActor
@Suite struct ClaudeSetupMigrationTests {

    private func localRules(_ config: AppConfig) -> [ModelMapping] {
        config.modelMappings.filter { $0.sourceModel == ClaudeSetupSettings.localID }
    }

    @Test func migration13SeedsTheLocalRuleOnce() throws {
        let fresh = AppConfig.makeDefault()
        #expect(!fresh.localRuleSeeded)
        let config = ConfigStore.applyMigrations(fresh)
        let rule = try #require(localRules(config).first)
        #expect(localRules(config).count == 1)
        #expect(rule.isEnabled && rule.matchClass == nil && !rule.catchAll)
        #expect(rule.targetModel == "local/qwen3.8-27b-q8")
        #expect(rule.targetVendorID == config.vendors.first(where: { AppConfig.isSplashVendor($0) })?.id)
        #expect(rule.backupTargetModel == "GLM-5.3-Flash")
        #expect(rule.backupTargetVendorID == config.vendors.first { $0.vendorKind == .relay }?.id)
        #expect(config.localRuleSeeded)
        // Listed with the other routes, not behind the catch-all.
        let localIndex = try #require(config.modelMappings.firstIndex { $0.sourceModel == ClaudeSetupSettings.localID })
        let catchAllIndex = try #require(config.modelMappings.firstIndex { $0.catchAll })
        #expect(localIndex < catchAllIndex)
        #expect(localRules(ConfigStore.applyMigrations(config)).count == 1)
    }

    @Test func aDeletedLocalRuleStaysDeleted() {
        let config = ConfigStore.applyMigrations(AppConfig.makeDefault())
        config.modelMappings.removeAll { $0.sourceModel == ClaudeSetupSettings.localID }
        #expect(localRules(ConfigStore.applyMigrations(config)).isEmpty)
    }

    @Test func aConfigWithoutSplashWaitsForOne() {
        let fresh = AppConfig.makeDefault()
        fresh.vendors.removeAll { AppConfig.isSplashVendor($0) }
        let config = ConfigStore.applyMigrations(fresh)
        #expect(localRules(config).isEmpty)
        #expect(!config.localRuleSeeded)
    }

    @Test func theLocalRuleFollowsTheActiveProfile() throws {
        let fresh = AppConfig.makeDefault()
        let settings = try #require(fresh.splash)
        var other = try #require(settings.profiles.first)
        other.id = UUID()
        other.model = "local/another-model"
        fresh.splash?.profiles.append(other)
        fresh.splash?.activeProfileID = other.id
        let config = ConfigStore.applyMigrations(fresh)
        #expect(localRules(config).first?.targetModel == "local/another-model")
    }

    @Test func localRoutesToSplashWithTheRelayAsBackup() throws {
        let config = ConfigStore.applyMigrations(AppConfig.makeDefault())
        let client = try #require(config.clients.first { $0.clientName.lowercased().contains("claude") })
        let snapshot = RoutingSnapshot(from: config, for: client)
        let targets = try #require(snapshot.targets(for: ClaudeSetupSettings.localID))
        #expect(targets.count == 2)
        #expect(targets[0].vendorName.lowercased().contains("splash"))
        #expect(targets[0].targetModel == "local/qwen3.8-27b-q8")
        #expect(targets[1].targetModel == "GLM-5.3-Flash")
    }

    @Test func syncCreatesTheRuleAndThenStaysQuiet() throws {
        let config = AppConfig.makeDefault()
        #expect(ClaudeSetupLocalRule.sync(into: config))
        #expect(localRules(config).count == 1)
        #expect(config.localRuleSeeded)
        #expect(!ClaudeSetupLocalRule.sync(into: config))
        #expect(!ClaudeSetupLocalRule.isStale(in: config))
    }

    @Test func syncFollowsAChangedProfile() throws {
        let config = ConfigStore.applyMigrations(AppConfig.makeDefault())
        let settings = try #require(config.splash)
        var other = try #require(settings.profiles.first)
        other.id = UUID()
        other.model = "local/another-model"
        config.splash?.profiles.append(other)
        config.splash?.activeProfileID = other.id
        #expect(ClaudeSetupLocalRule.isStale(in: config))
        #expect(ClaudeSetupLocalRule.sync(into: config))
        #expect(localRules(config).first?.targetModel == "local/another-model")
        #expect(localRules(config).count == 1)
    }

    @Test func syncWithoutSplashChangesNothing() {
        let fresh = AppConfig.makeDefault()
        fresh.vendors.removeAll { AppConfig.isSplashVendor($0) }
        #expect(!ClaudeSetupLocalRule.sync(into: fresh))
        #expect(localRules(fresh).isEmpty)
    }

    /// A request named like a rule's label takes that row before any class
    /// rule. With the bare aliases the plain rows are labelled `opus`,
    /// `sonnet`, `haiku`, so a lever enabled beside them does not catch the
    /// request — documented in the README's tier-alias section.
    @Test func aRequestNamedLikeAPlainRowTakesThatRow() throws {
        let config = ConfigStore.applyMigrations(AppConfig.makeDefault())
        let lever = try #require(config.modelMappings.firstIndex {
            $0.matchClass == .haiku && $0.targetModel == "local/qwen3.8-27b-q8"
        })
        config.modelMappings[lever].isEnabled = true
        let client = try #require(config.clients.first { $0.clientName.lowercased().contains("claude") })
        let snapshot = RoutingSnapshot(from: config, for: client)
        let targets = try #require(snapshot.targets(for: "haiku"))
        #expect(targets.first?.targetModel == "GLM-5.3-Flash")
    }

    @Test func noOtherRouteChanges() throws {
        // AppConfig is a class: the migration edits the same instance.
        let before = AppConfig.makeDefault().modelMappings.map(\.targetModel)
        let config = ConfigStore.applyMigrations(AppConfig.makeDefault())
        let others = config.modelMappings.filter { $0.sourceModel != ClaudeSetupSettings.localID }
        #expect(others.map(\.targetModel) == before)
    }
}

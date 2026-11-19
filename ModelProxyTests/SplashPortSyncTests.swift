import Testing
import Foundation
@testable import ZGate

@Suite struct SplashPortSyncTests {
    private func qwenLeverConfig(port: Int?) -> AppConfig {
        var cfg = AppConfig.makeDefault()
        cfg.splash?.port = port ?? 8123
        // enable the shipped disabled sonnet→local-qwen lever so a class
        // rule targets the splash vendor
        if let i = cfg.modelMappings.firstIndex(where: { $0.sourceModel.contains("local qwen") }) {
            cfg.modelMappings[i].isEnabled = true
        }
        return cfg
    }

    @Test func baseURLFollowsPort() {
        let vendors = AppConfig.syncingSplashVendor(
            qwenLeverConfig(port: 9999).vendors, splashPort: 9999)
        let splash = vendors.first { $0.name.lowercased().contains("splash") }!
        #expect(splash.baseURL == "http://127.0.0.1:9999")
    }

    @Test func nilPortKeepsDefault8123() {
        let vendors = AppConfig.syncingSplashVendor(
            qwenLeverConfig(port: nil).vendors, splashPort: nil)
        let splash = vendors.first { $0.name.lowercased().contains("splash") }!
        #expect(splash.baseURL == "http://127.0.0.1:8123")
    }

    @Test func relayVendorUntouched() {
        let vendors = AppConfig.syncingSplashVendor(
            qwenLeverConfig(port: 9999).vendors, splashPort: 9999)
        let relay = vendors.first { $0.vendorKind == .relay }!
        #expect(relay.baseURL.contains("zcode.z.ai"))
    }

    @Test func routingTableSeesSyncedPort() {
        let cfg = qwenLeverConfig(port: 9555)
        let vendors = AppConfig.syncingSplashVendor(cfg.vendors, splashPort: 9555)
        let table = ClassRuleTable(from: cfg.modelMappings, vendors: vendors, clientID: cfg.clients.first!.id)
        let targets = table.targets(
            for: "glm-5.3[1m]-sonnet", context: ConditionContext(now: Date()))?
            .map(\.baseURL) ?? []
        #expect(targets.contains("http://127.0.0.1:9555"))
    }
}

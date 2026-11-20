import Foundation
import Testing
@testable import ZGate

/// Off-peak wave 2 Task 2: the seeded off-peak vendor as a routing-rule
/// target. Pins the RoutingSnapshot flow with NO snapshot-side changes —
/// `vendor.vendorKind` copies through to the RouteTarget verbatim, and a
/// rule whose vendor row was deleted is skipped by the existing vendor
/// guard (the rule is inert; the unmapped policy serves). Separate from
/// RouterTests on purpose: that suite is a known port-race flake class,
/// while this one binds no ports at all.
@MainActor
@Suite struct OffPeakRoutingSnapshotTests {

    private func makeConfig(vendors: [Vendor], rule: ModelMapping) -> (config: AppConfig, client: ClientConfig) {
        let client = ClientConfig(
            clientName: "Batch harness", port: 0,
            defaultUpstream: "https://api.anthropic.com", unmappedPolicy: .passthrough)
        let config = AppConfig(vendors: vendors, clients: [client], modelMappings: [rule])
        return (config, client)
    }

    @Test func snapshotRoutesAnOffPeakRuleTargetWithTheRulesModel() {
        let vendor = Vendor(
            name: "ZCode Off-Peak", baseURL: OffPeakConfig.defaultOrigin,
            apiKey: "", vendorKind: .offPeak)
        let rule = ModelMapping(
            sourceModel: "batch-model", targetModel: "glm-5.3-flash",
            targetVendorID: vendor.id)
        let (config, client) = makeConfig(vendors: [vendor], rule: rule)

        let snapshot = RoutingSnapshot(from: config, for: client)
        let result = snapshot.resolve(model: "batch-model", originalAPIKey: "client-key").result

        guard case .routed(let target) = result else {
            Issue.record("expected a routed target, got \(result)")
            return
        }
        #expect(target.vendorKind == .offPeak)
        #expect(target.targetModel == "glm-5.3-flash")
        #expect(target.vendorID == vendor.id)
        #expect(target.baseURL == OffPeakConfig.defaultOrigin)
        #expect(!target.isPassthrough)
    }

    @Test func snapshotSkipsARuleWhoseOffPeakVendorRowWasDeleted() {
        // The rule still points at the deleted vendor's id; the snapshot's
        // existing vendor guard skips it — the rule is inert and the unmapped
        // policy (passthrough here) serves. No crash, no off-peak leak.
        let vendor = Vendor(
            name: "ZCode Off-Peak", baseURL: OffPeakConfig.defaultOrigin,
            apiKey: "", vendorKind: .offPeak)
        let rule = ModelMapping(
            sourceModel: "batch-model", targetModel: "glm-5.3-flash",
            targetVendorID: vendor.id)
        let (config, client) = makeConfig(vendors: [], rule: rule)  // row deleted

        let snapshot = RoutingSnapshot(from: config, for: client)
        let result = snapshot.resolve(model: "batch-model", originalAPIKey: "client-key").result

        guard case .routed(let target) = result else {
            Issue.record("expected a passthrough route, got \(result)")
            return
        }
        #expect(target.isPassthrough)  // fell through to the unmapped policy
        #expect(target.targetModel == nil)
        #expect(target.vendorID == nil)
        #expect(target.vendorKind == .anthropic)  // the passthrough target's default
    }
}

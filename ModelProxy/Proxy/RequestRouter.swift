import Foundation
import NIOCore
import NIOFoundationCompat

/// Thread-safe routing resolver.
/// Holds an atomic snapshot of routing config; swapped on config change.
actor RequestRouter {

    private var snapshot: RoutingSnapshot
    /// Routing-condition seams; Tasks 7 (health) / 8 (quota) provide the
    /// real implementations. nil = the condition reads as not-satisfied /
    /// fail-open (see RouterExtensions).
    private let healthProvider: (any TargetHealthProviding)?
    private let quotaProvider: (any QuotaSnapshotProviding)?

    init(
        snapshot: RoutingSnapshot,
        healthProvider: (any TargetHealthProviding)? = nil,
        quotaProvider: (any QuotaSnapshotProviding)? = nil
    ) {
        self.snapshot = snapshot
        self.healthProvider = healthProvider
        self.quotaProvider = quotaProvider
    }

    /// Atomically replace the routing table. In-flight requests keep the old snapshot.
    func updateSnapshot(_ newSnapshot: RoutingSnapshot) {
        self.snapshot = newSnapshot
    }

    /// Parse raw HTTP body bytes, extract the `model` field, and return a resolved target.
    /// With class/catch-all rules configured, a missing or empty model field
    /// routes as class `auto` (spec §2); without them the legacy 400 stands.
    func resolve(
        bodyBytes: ByteBuffer,
        originalAPIKey: String
    ) throws -> (result: RoutingSnapshot.ResolveResult, model: String, state: RoutingSnapshot.RouteState) {
        guard let data = bodyBytes.getData(at: bodyBytes.readerIndex, length: bodyBytes.readableBytes) else {
            throw RouterError.unreadableBody
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let model: String
        if let parsed = json?["model"] as? String, !parsed.isEmpty {
            model = parsed
        } else if snapshot.ruleTable.allowsMissingModel {
            model = ""  // unset model field → class auto
        } else {
            throw RouterError.missingModelField
        }
        let conditions = ConditionContext(
            now: Date(), health: healthProvider, quota: quotaProvider)
        let (result, state) = snapshot.resolve(
            model: model, originalAPIKey: originalAPIKey, conditions: conditions)
        return (result, model, state)
    }

    /// Returns all targets for a mapped model (for failover).
    func targets(for model: String) -> [RoutingSnapshot.RouteTarget]? {
        snapshot.targets(for: model)
    }

    /// Write back mutated failover state from ProxyForwarder.
    func updateRouteState(model: String, state: RoutingSnapshot.RouteState) {
        snapshot.updateRouteState(for: model, state: state)
    }
}

enum RouterError: Error, CustomStringConvertible {
    case unreadableBody
    case missingModelField

    var description: String {
        switch self {
        case .unreadableBody:   return "Request body could not be read as bytes"
        case .missingModelField: return "Request JSON missing or empty 'model' field"
        }
    }
}

import Foundation

// MARK: - Class map (spec §2)

extension ModelClass {

    /// Case-insensitive pattern map from the incoming Claude Code model name
    /// to its class; nil = no class matched (falls through to the terminal
    /// fallback rule). CC env aliases mean the wire names are GLM strings:
    /// opus/sonnet both alias to `glm-5.3` (and `glm-5.3[1m]`), haiku to
    /// `glm-5.3-flash`. v2.1 (ruling 2026-11-17): ALL deliberate work runs
    /// opus-class, so the bare `glm-5.3` prefix maps to .opus; the flash
    /// substring is still checked BEFORE the prefix (fast relay tier = haiku
    /// class). Local qwen names match nothing here → terminal fallback.
    static func classify(_ model: String?) -> ModelClass? {
        guard let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return .auto  // spec §2: unset model field → auto
        }
        let name = trimmed.lowercased()
        if name.contains("haiku") { return .haiku }
        if name.contains("flash") { return .haiku }  // glm-5.3-flash = fast relay tier
        if name.contains("opus") || name.contains("fable") { return .opus }
        if name.contains("sonnet") { return .sonnet }
        if name.hasPrefix("glm-5.3") { return .opus }  // bare glm-5.3 = main relay model (opus class)
        if name == "default" || name.hasPrefix("auto") { return .auto }
        return nil  // unknown (incl. qwen names) → terminal fallback rule
    }
}

// MARK: - Condition seams (Tasks 7/8 implement the real providers)

/// Health seam: the time of the last successful reachability probe per
/// target. Task 7 (LocalTarget) provides the real implementation — a TCP
/// probe against the local splash server. The router only ever READS.
protocol TargetHealthProviding: Sendable {
    /// Last successful probe for the vendor; nil when it was never probed.
    func lastSuccess(forVendor id: UUID) -> Date?
}

/// Quota snapshot consumed by `quotaBelow` conditions.
struct QuotaSnapshot: Sendable, Equatable {
    /// Remaining fraction of the billing-period quota, 0...1.
    var fractionRemaining: Double
    var fetchedAt: Date
    /// Per-window rows for the popover's quota list (Package A). Empty when
    /// the poll returned no parseable rows; the weekly row's fraction is the
    /// `fractionRemaining` above.
    var windows: [QuotaWindow] = []
}

/// One quota window the monitor reports (weekly tokens = the binding plan
/// quota, 5-hour tokens, monthly MCP). A UI-facing projection of the wire's
/// `limits[]` rows — unknown row shapes never reach this type.
struct QuotaWindow: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case weeklyTokens
        case fiveHourTokens
        case monthlyMCP
    }

    var kind: Kind
    /// Remaining fraction of this window, 0...1.
    var fractionRemaining: Double
    /// Next reset instant; nil when the wire row omits it.
    var resetsAt: Date?
}

/// Quota seam. Task 8 (QuotaService) provides the real implementation
/// (billing poll + cache); the router reads the last-known snapshot.
protocol QuotaSnapshotProviding: Sendable {
    func quotaSnapshot() -> QuotaSnapshot?
}

/// Inputs for per-request condition evaluation. `now` is injected so tests
/// can pin fixed dates; the seams are optional because Tasks 7/8 land later.
struct ConditionContext: Sendable {
    var now: Date
    var health: (any TargetHealthProviding)?
    var quota: (any QuotaSnapshotProviding)?

    init(
        now: Date = Date(),
        health: (any TargetHealthProviding)? = nil,
        quota: (any QuotaSnapshotProviding)? = nil
    ) {
        self.now = now
        self.health = health
        self.quota = quota
    }
}

// MARK: - Condition predicates

extension RuleCondition {

    /// A quota snapshot older than this makes `quotaBelow` read as false —
    /// fail-open: quota-gated rules are skipped, non-quota-gated rules still
    /// serve (never a dropped request).
    static let quotaStalenessLimit: TimeInterval = 2 * 60 * 60

    /// A condition that cannot be evaluated (missing seam data, unparseable
    /// window) reads as false: the rule is skipped and evaluation continues
    /// with the next matching rule.
    func isSatisfied(in context: ConditionContext) -> Bool {
        switch type {
        case .timeWindow:
            return timeWindowSatisfied(now: context.now)
        case .quotaBelow:
            return quotaBelowSatisfied(context: context)
        }
    }

    private func timeWindowSatisfied(now: Date) -> Bool {
        let timeZone = tz.flatMap(TimeZone.init(identifier:)) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let comps = calendar.dateComponents([.weekday, .hour, .minute], from: now)
        guard let weekday = comps.weekday, let hour = comps.hour, let minute = comps.minute else {
            return false
        }
        switch days ?? .daily {
        case .weekdays:
            guard weekday != 1, weekday != 7 else { return false }  // 1=Sun, 7=Sat
        case .weekend:
            guard weekday == 1 || weekday == 7 else { return false }
        case .daily:
            break
        }
        guard let from = Self.minutesFromMidnight(from),
              let to = Self.minutesFromMidnight(to) else {
            return false
        }
        let nowMinutes = hour * 60 + minute
        if from <= to {
            return nowMinutes >= from && nowMinutes < to
        }
        return nowMinutes >= from || nowMinutes < to  // window wraps midnight
    }

    /// "HH:mm" → minutes since midnight (also tolerates "HH:mm:ss").
    static func minutesFromMidnight(_ string: String?) -> Int? {
        guard let string else { return nil }
        let parts = string.split(separator: ":")
        guard parts.count >= 2,
              let hours = Int(parts[0]), let minutes = Int(parts[1]) else { return nil }
        guard hours >= 0, hours < 24, minutes >= 0, minutes < 60 else { return nil }
        return hours * 60 + minutes
    }

    private func quotaBelowSatisfied(context: ConditionContext) -> Bool {
        guard let percent,
              let snapshot = context.quota?.quotaSnapshot(),
              context.now.timeIntervalSince(snapshot.fetchedAt) <= Self.quotaStalenessLimit else {
            return false
        }
        return snapshot.fractionRemaining * 100 < percent
    }
}

// MARK: - Ordered class-rule table

/// Class-pattern and terminal-fallback rules built from `AppConfig.modelMappings`,
/// evaluated AFTER exact-match mappings and BEFORE the client's unmapped
/// policy. Class rules run in config order (first match wins); catch-all
/// rules are terminal (always last).
struct ClassRuleTable: Sendable {

    struct Rule: Sendable {
        /// nil on a catch-all rule (matches every model).
        let matchClass: ModelClass?
        let catchAll: Bool
        let conditions: [RuleCondition]
        /// Primary first, backup (if configured) second — same shape as the
        /// exact-match engine's per-model target arrays.
        let targets: [RoutingSnapshot.RouteTarget]
        /// Failover-state key, shared by `resolve` read and
        /// `updateRouteState` write so the paths stay symmetric.
        let stateKey: String
    }

    let rules: [Rule]

    var isEmpty: Bool { rules.isEmpty }

    /// True when any class/catch-all rule exists — a missing model field may
    /// then route as class `auto` instead of failing with 400.
    var allowsMissingModel: Bool { !rules.isEmpty }

    init(from mappings: [ModelMapping], vendors: [Vendor], clientID: UUID) {
        var built: [Rule] = []
        for mapping in mappings {
            guard mapping.isEnabled, mapping.matchClass != nil || mapping.catchAll else {
                continue
            }
            var targets: [RoutingSnapshot.RouteTarget] = []
            if let vendor = vendors.first(where: { $0.id == mapping.targetVendorID }) {
                targets.append(Self.routeTarget(vendor: vendor, targetModel: mapping.targetModel))
            }
            if let backupVendorID = mapping.backupTargetVendorID,
               let vendor = vendors.first(where: { $0.id == backupVendorID }),
               vendor.compatibleClientID == nil || vendor.compatibleClientID == clientID {
                targets.append(Self.routeTarget(
                    vendor: vendor,
                    targetModel: mapping.backupTargetModel ?? mapping.targetModel))
            }
            guard let primary = targets.first else { continue }  // vendor deleted
            let stateKey = mapping.catchAll
                ? "catchall:\(primary.vendorID?.uuidString ?? primary.baseURL)"
                : "class:\(mapping.matchClass!.rawValue):\(primary.vendorID?.uuidString ?? primary.baseURL)"
            built.append(Rule(
                matchClass: mapping.matchClass,
                catchAll: mapping.catchAll,
                conditions: mapping.conditions ?? [],
                targets: targets,
                stateKey: stateKey))
        }
        self.rules = built
    }

    /// First rule whose class matches the model AND whose conditions and
    /// primary-target health hold; nil when nothing matched (caller falls to
    /// the unmapped policy).
    func firstMatch(model: String, context: ConditionContext) -> Rule? {
        let modelClass = ModelClass.classify(model)
        for rule in rules where !rule.catchAll && rule.matchClass == modelClass {
            if isEligible(rule, context: context) { return rule }
        }
        for rule in rules where rule.catchAll {
            if isEligible(rule, context: context) { return rule }
        }
        return nil
    }

    /// All targets of the first ELIGIBLE rule matching the model (used by
    /// the 429 failover path) — the same eligibility `firstMatch` applies, so
    /// a rule the resolver just skipped (conditions failed, stale probe) is
    /// never resurrected as a failover candidate. nil when nothing eligible
    /// matches.
    func targets(for model: String, context: ConditionContext) -> [RoutingSnapshot.RouteTarget]? {
        firstMatch(model: model, context: context)?.targets
    }

    /// Failover-state key of the first eligible rule — the same derivation
    /// `resolve` used for its read, so `updateRouteState` writes the key of
    /// the rule that actually served, never a skipped rule's key.
    func stateKey(for model: String, context: ConditionContext) -> String? {
        firstMatch(model: model, context: context)?.stateKey
    }

    /// A target is skipped only when its last successful probe is stale
    /// (> `healthStalenessLimit` old). Never probed or no seam = no data =
    /// fail-open (healthy). Task 7's probe cadence keeps fresh entries warm.
    static let healthStalenessLimit: TimeInterval = 60

    private func isEligible(_ rule: Rule, context: ConditionContext) -> Bool {
        guard rule.conditions.allSatisfy({ $0.isSatisfied(in: context) }) else { return false }
        if let primary = rule.targets.first, isKnownUnhealthy(primary, context: context) {
            return false
        }
        return true
    }

    private func isKnownUnhealthy(
        _ target: RoutingSnapshot.RouteTarget, context: ConditionContext
    ) -> Bool {
        guard let health = context.health,
              let vendorID = target.vendorID,
              let lastSuccess = health.lastSuccess(forVendor: vendorID) else {
            return false
        }
        return context.now.timeIntervalSince(lastSuccess) > Self.healthStalenessLimit
    }

    private static func routeTarget(vendor: Vendor, targetModel: String) -> RoutingSnapshot.RouteTarget {
        RoutingSnapshot.RouteTarget(
            baseURL: vendor.baseURL,
            apiKey: vendor.apiKey,
            vendorName: vendor.name,
            vendorID: vendor.id,
            targetModel: targetModel,
            isPassthrough: false,
            connectTimeoutSeconds: vendor.connectTimeoutSeconds,
            readTimeoutSeconds: vendor.readTimeoutSeconds,
            signingDomain: vendor.signingDomain,
            replayPolicy: vendor.replayPolicy,
            supportsThinkingBlocks: vendor.supportsThinkingBlocks,
            supportsAnthropicCountTokens: vendor.supportsAnthropicCountTokens,
            repairsAnthropicToolCalls: vendor.repairsAnthropicToolCalls,
            stripsClaudeOnlyRequestFields: vendor.stripsClaudeOnlyRequestFields,
            applyGLMCanonicalization: vendor.applyGLMCanonicalization,
            vendorKind: vendor.vendorKind)
    }
}

import Foundation
import OSLog

/// Routing snapshot for one client port.
/// Built from AppConfig global mappings + the ClientConfig for the receiving port.
/// Captured at request time; safe to use from any concurrency context.
struct RoutingSnapshot: Sendable {

    struct RouteTarget: Sendable {
        /// Vendor baseURL, e.g. "https://dashscope.aliyuncs.com/compatible-mode"
        let baseURL: String
        /// Vendor API key (empty string = use original key from request).
        /// `var` for the fallback edge's lazily minted credential: the
        /// snapshot copy stays empty until the mint persists + hot-reloads,
        /// so the serving path resolves the live key per request.
        var apiKey: String
        let vendorName: String
        /// Vendor UUID for token stats keying; nil for passthrough routes.
        let vendorID: UUID?
        /// Replacement model name; nil = no model field substitution.
        /// `var` for the direct degraded serve (fix round 1), which reuses
        /// the matched rule's tier target on the fallback edge.
        var targetModel: String?
        /// true = pure passthrough — proxy does not touch headers, key, or body
        let isPassthrough: Bool
        /// Per-vendor connect timeout in seconds.
        let connectTimeoutSeconds: Int
        /// Per-vendor read timeout in seconds.
        let readTimeoutSeconds: Int
        /// Transcript signing domain for replay portability decisions.
        let signingDomain: SigningDomain
        /// Replay policy for this target.
        let replayPolicy: TranscriptReplayPolicy
        /// Whether this target accepts Anthropic `thinking` content blocks.
        let supportsThinkingBlocks: Bool
        /// Whether this target accepts Anthropic `/v1/messages/count_tokens`.
        let supportsAnthropicCountTokens: Bool
        /// Whether ModelProxy should repair returned Anthropic `tool_use.input` blocks.
        let repairsAnthropicToolCalls: Bool
        /// Whether Claude-only request fields and `anthropic-beta` are removed before forwarding.
        let stripsClaudeOnlyRequestFields: Bool
        /// Whether the outgoing top-level `model` value runs through
        /// `RelayTarget.canonicalModel` (the Task-7 fallback edge's flag —
        /// GLM canonical wire names, retired names never leak raw).
        let applyGLMCanonicalization: Bool
        /// Auth/forward mode: static-key vendor (`.anthropic`) or the signed
        /// zcode relay (`.relay` — routed through RelayTarget).
        let vendorKind: VendorKind

        init(
            baseURL: String,
            apiKey: String,
            vendorName: String,
            vendorID: UUID?,
            targetModel: String?,
            isPassthrough: Bool,
            connectTimeoutSeconds: Int,
            readTimeoutSeconds: Int,
            signingDomain: SigningDomain,
            replayPolicy: TranscriptReplayPolicy,
            supportsThinkingBlocks: Bool = VendorDefaults.supportsThinkingBlocks,
            supportsAnthropicCountTokens: Bool = VendorDefaults.supportsAnthropicCountTokens,
            repairsAnthropicToolCalls: Bool = VendorDefaults.repairsAnthropicToolCalls,
            stripsClaudeOnlyRequestFields: Bool = VendorDefaults.stripsClaudeOnlyRequestFields,
            applyGLMCanonicalization: Bool = VendorDefaults.applyGLMCanonicalization,
            vendorKind: VendorKind = .anthropic
        ) {
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.vendorName = vendorName
            self.vendorID = vendorID
            self.targetModel = targetModel
            self.isPassthrough = isPassthrough
            self.connectTimeoutSeconds = connectTimeoutSeconds
            self.readTimeoutSeconds = readTimeoutSeconds
            self.signingDomain = signingDomain
            self.replayPolicy = replayPolicy
            self.supportsThinkingBlocks = supportsThinkingBlocks
            self.supportsAnthropicCountTokens = supportsAnthropicCountTokens
            self.repairsAnthropicToolCalls = repairsAnthropicToolCalls
            self.stripsClaudeOnlyRequestFields = stripsClaudeOnlyRequestFields
            self.applyGLMCanonicalization = applyGLMCanonicalization
            self.vendorKind = vendorKind
        }

        /// Copy with a resolved API key — the fallback edge's serving path
        /// (its snapshot key stays empty until the first mint persists and
        /// the routing snapshot hot-reloads).
        func withAPIKey(_ newKey: String) -> RouteTarget {
            var copy = self
            copy.apiKey = newKey
            return copy
        }

        /// Copy with a different replacement model — the direct degraded
        /// serve reuses the matched rule's tier target on the fallback edge.
        func withTargetModel(_ newModel: String?) -> RouteTarget {
            var copy = self
            copy.targetModel = newModel
            return copy
        }
    }

    // MARK: - Failover state

    enum ActiveTarget: Sendable {
        case primary
        case backup
    }

    struct RouteState: Sendable {
        var failCount: Int = 0
        var activeTarget: ActiveTarget = .primary
    }

    enum ResolveResult: Sendable {
        case routed(RouteTarget)
        case blocked(reason: String)
    }

    /// sourceModel -> [RouteTarget], built from AppConfig.modelMappings.
    /// Array: first = primary, second = backup (if present).
    private let modelMappings: [String: [RouteTarget]]
    /// Per-model failover state (failCount + activeTarget). Keyed by sourceModel.
    private var routeStates: [String: RouteState]
    /// Passthrough target for unmapped models: the client's configured defaultUpstream.
    private let passthroughBaseURL: String
    /// Policy for unmapped models.
    private let unmappedPolicy: UnmappedModelPolicy
    /// Fallback vendor target (resolved at snapshot build time); used when policy is .routeAll.
    private let fallbackTarget: RouteTarget?
    /// Class-pattern / terminal-fallback rules (spec §2), evaluated after
    /// exact-match mappings and before the unmapped policy.
    let ruleTable: ClassRuleTable

    /// Build a snapshot for a specific client port.
    /// - Parameters:
    ///   - config: full AppConfig (provides global modelMappings + vendor lookup)
    ///   - clientConfig: the ClientConfig whose port received the request
    ///   - vendors: vendor rows to route against; nil = `config.vendors`.
    ///     ProxyServer passes the splash-port-synced array (spec §6.1) so the
    ///     stored row's seeded 8123 default never leaks into routing.
    init(from config: AppConfig, for clientConfig: ClientConfig, vendors syncedVendors: [Vendor]? = nil) {
        let vendors = syncedVendors ?? config.vendors
        var mappings: [String: [RouteTarget]] = [:]
        for mapping in config.modelMappings {
            guard mapping.isEnabled else {
                continue
            }
            guard let vendor = vendors.first(where: { $0.id == mapping.targetVendorID }) else {
                continue
            }
            let primary = RouteTarget(
                baseURL: vendor.baseURL,
                apiKey: vendor.apiKey,
                vendorName: vendor.name,
                vendorID: vendor.id,
                targetModel: mapping.targetModel,
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
                vendorKind: vendor.vendorKind
            )
            var targets = [primary]

            // Build backup target if configured and compatible.
            if let backupVendorID = mapping.backupTargetVendorID,
               let backupVendor = vendors.first(where: { $0.id == backupVendorID }),
               backupVendor.compatibleClientID == nil || backupVendor.compatibleClientID == clientConfig.id {
                let backup = RouteTarget(
                    baseURL: backupVendor.baseURL,
                    apiKey: backupVendor.apiKey,
                    vendorName: backupVendor.name,
                    vendorID: backupVendor.id,
                    targetModel: mapping.backupTargetModel ?? mapping.targetModel,
                    isPassthrough: false,
                    connectTimeoutSeconds: backupVendor.connectTimeoutSeconds,
                    readTimeoutSeconds: backupVendor.readTimeoutSeconds,
                    signingDomain: backupVendor.signingDomain,
                    replayPolicy: backupVendor.replayPolicy,
                    supportsThinkingBlocks: backupVendor.supportsThinkingBlocks,
                    supportsAnthropicCountTokens: backupVendor.supportsAnthropicCountTokens,
                    repairsAnthropicToolCalls: backupVendor.repairsAnthropicToolCalls,
                    stripsClaudeOnlyRequestFields: backupVendor.stripsClaudeOnlyRequestFields,
                    applyGLMCanonicalization: backupVendor.applyGLMCanonicalization,
                    vendorKind: backupVendor.vendorKind
                )
                targets.append(backup)
            }

            // Defensive fallback for hand-edited config: first enabled row wins.
            if mappings[mapping.sourceModel] == nil {
                mappings[mapping.sourceModel] = targets
            }
        }
        self.modelMappings = mappings
        self.routeStates = [:]
        self.passthroughBaseURL = clientConfig.defaultUpstream
        self.unmappedPolicy = clientConfig.unmappedPolicy
        self.ruleTable = ClassRuleTable(
            from: config.modelMappings, vendors: vendors, clientID: clientConfig.id)

        // Resolve fallback vendor for .routeAll at build time.
        if clientConfig.unmappedPolicy == .routeAll,
           let vid = clientConfig.fallbackVendorID,
           let vendor = vendors.first(where: { $0.id == vid }) {
            let resolvedModel: String? = {
                guard let m = clientConfig.fallbackTargetModel, !m.isEmpty else { return nil }
                return m
            }()
            self.fallbackTarget = RouteTarget(
                baseURL: vendor.baseURL,
                apiKey: vendor.apiKey,
                vendorName: vendor.name,
                vendorID: vendor.id,
                targetModel: resolvedModel,
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
                vendorKind: vendor.vendorKind
            )
        } else {
            self.fallbackTarget = nil
        }
    }

    /// Resolve a route for the given model.
    /// Order: exact-match mappings (upstream engine, untouched) → class /
    /// catch-all rules (spec §2, conditions + health per request) → unmapped
    /// policy (final safety net; a terminal catch-all rule normally wins).
    func resolve(
        model: String,
        originalAPIKey: String,
        conditions: ConditionContext = ConditionContext()
    ) -> (result: ResolveResult, state: RouteState) {
        // Exact match first, then prefix match (longest-prefix-wins).
        if let targets = modelMappings[model]
            ?? modelMappings.filter({ model.hasPrefix($0.key) }).max(by: { $0.key.count < $1.key.count })?.value {
            let state = routeStates[model] ?? RouteState()
            let target = selectTarget(from: targets, state: state)
            return (.routed(target), state)
        }

        // Class-pattern rules, then terminal catch-all rules (first eligible wins).
        if let rule = ruleTable.firstMatch(model: model, context: conditions) {
            let state = routeStates[rule.stateKey] ?? RouteState()
            let target = selectTarget(from: rule.targets, state: state)
            return (.routed(target), state)
        }

        let defaultState = RouteState()
        switch unmappedPolicy {
        case .passthrough:
            return (.routed(passthroughTarget(originalAPIKey: originalAPIKey)), defaultState)
        case .routeAll:
            if let fallback = fallbackTarget {
                return (.routed(fallback), defaultState)
            }
            AppLog.proxy.warning("[RoutingSnapshot] routeAll fallback vendor missing or deleted for model '\(model)'; falling back to passthrough")
            return (.routed(passthroughTarget(originalAPIKey: originalAPIKey)), defaultState)
        case .block:
            return (.blocked(reason: "Model '\(model)' is not mapped and this client is set to block unmapped models."), defaultState)
        }
    }

    /// Matches Claude Code's own `API_TIMEOUT_MS` default so a slow non-streaming passthrough
    /// response is not cut off by the proxy before Claude Code itself would give up.
    static let passthroughResponseTimeoutSeconds = 600

    func passthroughTarget(originalAPIKey: String) -> RouteTarget {
        RouteTarget(
            baseURL: passthroughBaseURL,
            apiKey: originalAPIKey,
            vendorName: "passthrough",
            vendorID: nil,
            targetModel: nil,
            isPassthrough: true,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: Self.passthroughResponseTimeoutSeconds,
            signingDomain: SigningDomain.infer(fromBaseURL: passthroughBaseURL),
            replayPolicy: .transparent,
            supportsThinkingBlocks: true,
            supportsAnthropicCountTokens: true,
            repairsAnthropicToolCalls: false
        )
    }

    /// Returns all targets for a mapped model (for failover use by ProxyForwarder).
    /// Consults the class-rule table too — with the same eligibility the
    /// resolver applied — so class-routed requests get the same 429 backup
    /// behavior without resurrecting a skipped rule. Returns nil if model is
    /// not mapped.
    func targets(for model: String, conditions: ConditionContext = ConditionContext()) -> [RouteTarget]? {
        if let targets = modelMappings[model]
            ?? modelMappings.filter({ model.hasPrefix($0.key) }).max(by: { $0.key.count < $1.key.count })?.value {
            return targets
        }
        return ruleTable.targets(for: model, context: conditions)
    }

    /// Write back mutated failover state from ProxyForwarder. Class-routed
    /// models key by the first eligible rule — mirroring the key `resolve`
    /// read for the rule that actually served.
    mutating func updateRouteState(
        for model: String, state: RouteState, conditions: ConditionContext = ConditionContext()
    ) {
        if modelMappings[model] != nil
            || modelMappings.contains(where: { model.hasPrefix($0.key) }) {
            routeStates[model] = state
            return
        }
        if let key = ruleTable.stateKey(for: model, context: conditions) {
            routeStates[key] = state
        }
    }

    // MARK: - Private

    private func selectTarget(from targets: [RouteTarget], state: RouteState) -> RouteTarget {
        switch state.activeTarget {
        case .primary:
            return targets[0]
        case .backup:
            // Guard: if no backup exists, fall back to primary.
            return targets.count > 1 ? targets[1] : targets[0]
        }
    }
}

import Foundation
import OSLog

/// Relay-plane health machine + fallback-edge key lifecycle (relay fidelity
/// Task 7). TWO strictly separated planes — neither ever writes the other:
///
/// - The RELAY machine — `healthy | degradedSigning | riskCooldown`.
///   A signing-class terminal failure (`.signingUnavailable` or a post-retry
///   `.transportFailed`) enters `degradedSigning`; while degraded, a signed
///   attempt runs only on the half-open probe cadence (60 s base, ×2
///   backoff, 300 s cap — the admitted request IS the probe, and it CLAIMS
///   the slot, so concurrent requests serve via the fallback edge instead
///   of stacking attempts on a dead chain); a probe that completes any
///   exchange (any non-signing-class outcome — the chain demonstrably
///   works) returns the machine to `healthy` with the backoff reset. A
///   Task-6 risk-control event enters `riskCooldown` for 900 s — relay
///   attempts are blocked (the client gets a clear 502; the fallback may
///   still serve) — and expires back to healthy. `.credentialsExpired`
///   NEVER enters a state: recovery is an interactive re-login, not a timed
///   probe, so the request serves via the fallback with health untouched.
///
/// - The FALLBACK KEY plane — the minted `api.z.ai/api/anthropic`
///   credential cache with a lazy single-flight mint, a re-mint seam for a
///   fallback 401, and a 1 h cooldown after a fallback no-balance 1113.
///   Fallback outcomes NEVER launder relay state and relay notes never
///   touch this plane.
actor RelayHealth {

    // MARK: - State

    nonisolated enum State: Equatable, Sendable {
        case healthy
        case degradedSigning(nextProbeAtMs: Int64, backoffSeconds: Double)
        case riskCooldown(untilMs: Int64)
    }

    /// What a relay request may do, asked BEFORE the signed ladder runs.
    nonisolated enum Admission: Equatable, Sendable {
        /// Healthy — run the signed ladder.
        case attempt
        /// Degraded but due — THIS request carries the recovery probe.
        case probe
        /// Degraded and not due — serve via the fallback edge.
        case serveViaFallback
        /// Risk cooldown — relay attempts blocked; the fallback may serve.
        case riskBlocked
    }

    nonisolated struct Configuration: Sendable {
        /// Half-open probe base interval.
        var probeBaseSeconds: Double = 60
        /// Probe backoff cap.
        var probeMaxSeconds: Double = 300
        /// Risk-control cooldown (Task 6 event).
        var riskCooldownSeconds: Double = 900
        /// Fallback-key no-balance (business 1113) cooldown.
        var keyCooldownSeconds: Double = 3600
        /// Re-mint guard after a failed mint chain.
        var mintFailureCooldownSeconds: Double = 60
        /// The mint chain for the fallback edge's credential; nil = no
        /// minting (a stored config key still serves when present).
        var minter: ApiKeyMinter?
        /// The fallback edge this health actor serves — routing keys the
        /// key lifecycle off it. Defaults to the pinned edge; tests point
        /// it at their stub.
        var fallbackEdgeBaseURL = ApiKeyMinter.fallbackBaseURL
        /// Fired once per successful mint (persistence lives in the app layer).
        var onKeyMinted: (@Sendable (String) -> Void)?
        var now: @Sendable () -> Date = { Date() }

        init() {}
    }

    private let configuration: Configuration
    private var state: State = .healthy

    // Fallback-key plane (never read or written by the relay machine).
    private var fallbackKeyValue: String?
    private var keyCooldownUntilMs: Int64?
    private var mintFailureCooldownUntilMs: Int64?
    private var mintInFlight: Task<String?, Never>?
    /// The fallback edge's route target, pushed from the live config by
    /// ProxyServer (nil = no edge vendor configured — the direct degraded
    /// serve then finds nothing and today's terminal answers). Fix round 1:
    /// class rules carry no rule backup, so degraded admission serves the
    /// edge DIRECTLY through this target.
    private var fallbackEdgeServeTarget: RoutingSnapshot.RouteTarget?

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: - Relay machine

    func currentState() -> State { state }

    /// The admission decision for the next relay attempt. A due probe
    /// CLAIMS its slot: `nextProbeAt` moves forward by the current backoff
    /// immediately, so requests racing the in-flight probe serve via the
    /// fallback; a failed probe then doubles the backoff, a successful one
    /// resets everything. A probe whose request never reports re-arms after
    /// the claimed interval.
    func admission() -> Admission {
        let nowMs = currentMs()
        switch state {
        case .healthy:
            return .attempt
        case .riskCooldown(let untilMs):
            guard nowMs < untilMs else {
                state = .healthy
                return .attempt
            }
            return .riskBlocked
        case .degradedSigning(let nextProbeAtMs, let backoffSeconds):
            guard nowMs >= nextProbeAtMs else { return .serveViaFallback }
            state = .degradedSigning(
                nextProbeAtMs: nowMs + Self.ms(backoffSeconds),
                backoffSeconds: backoffSeconds)
            return .probe
        }
    }

    /// A signing-class terminal failure. From healthy: enter degraded at
    /// the base interval. While degraded (a failed probe): double the
    /// backoff, capped. During a risk cooldown: ignored (risk supersedes).
    func noteSigningFailure() {
        switch state {
        case .healthy:
            state = .degradedSigning(
                nextProbeAtMs: currentMs() + Self.ms(configuration.probeBaseSeconds),
                backoffSeconds: configuration.probeBaseSeconds)
        case .degradedSigning(_, let backoffSeconds):
            let doubled = min(backoffSeconds * 2, configuration.probeMaxSeconds)
            state = .degradedSigning(
                nextProbeAtMs: currentMs() + Self.ms(doubled),
                backoffSeconds: doubled)
        case .riskCooldown:
            break
        }
    }

    /// A completed signed exchange — any non-signing-class outcome proves
    /// the chain works: leave every state, reset the backoff.
    func noteRelayServed() {
        state = .healthy
    }

    /// Task-6 risk event: block relay attempts for the cooldown.
    func noteRiskControl() {
        state = .riskCooldown(untilMs: currentMs() + Self.ms(configuration.riskCooldownSeconds))
    }

    // MARK: - Fallback key plane

    /// Whether a target baseURL points at the fallback edge THIS actor
    /// serves (the configured edge, not the global pinned constant — tests
    /// point it at their stub).
    func isFallbackEdge(_ baseURL: String) -> Bool {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return !trimmed.isEmpty
            && trimmed.caseInsensitiveCompare(configuration.fallbackEdgeBaseURL) == .orderedSame
    }

    /// The fallback-edge credential, minting lazily on first use
    /// (single-flight). nil when the key is cooling (no-balance 1113), when
    /// a recent mint failed, or when no minter is configured. A failed mint
    /// is guarded by a re-mint cooldown so a dead chain does not pay the
    /// full chain latency per request; `forceRemint` (the fallback-401
    /// remediation) bypasses that guard deliberately.
    func fallbackKey(forceRemint: Bool = false) async -> String? {
        let nowMs = currentMs()
        if let untilMs = keyCooldownUntilMs, nowMs < untilMs { return nil }
        if !forceRemint, let fallbackKeyValue { return fallbackKeyValue }
        if !forceRemint, let untilMs = mintFailureCooldownUntilMs, nowMs < untilMs { return nil }
        if forceRemint {
            mintInFlight = nil  // a forced re-mint never joins a stale flight
            return await performMint()
        }
        if let mintInFlight { return await mintInFlight.value }
        let task = Task { await self.performMint() }
        mintInFlight = task
        let key = await task.value
        mintInFlight = nil
        return key
    }

    /// Fallback no-balance (business code 1113): cool the KEY for 1 h. The
    /// response surfaces to the client; the relay machine is untouched
    /// (the never-launder rule).
    func noteFallbackKeyNoBalance() {
        keyCooldownUntilMs = currentMs() + Self.ms(configuration.keyCooldownSeconds)
    }

    func isFallbackKeyCooling() -> Bool {
        if let untilMs = keyCooldownUntilMs { return currentMs() < untilMs }
        return false
    }

    // MARK: - Direct degraded serve (fix round 1)

    /// Push the fallback edge's route target from the live config (start +
    /// hot-reload). nil = the user removed the edge vendor — degraded
    /// admission then finds no direct serve and today's terminal answers.
    func configureFallbackEdgeTarget(_ target: RoutingSnapshot.RouteTarget?) {
        fallbackEdgeServeTarget = target
    }

    /// The configured fallback edge target for the DIRECT degraded serve
    /// (class rules carry no rule backup — controller ruling, fix round 1).
    func fallbackEdgeTarget() -> RoutingSnapshot.RouteTarget? {
        fallbackEdgeServeTarget
    }

    private func performMint() async -> String? {
        guard let minter = configuration.minter else { return nil }
        do {
            let minted = try await minter.mint()
            fallbackKeyValue = minted
            mintFailureCooldownUntilMs = nil
            configuration.onKeyMinted?(minted)
            return minted
        } catch {
            AppLog.proxy.error(
                "[RelayHealth] fallback key mint failed: \(String(describing: error))")
            mintFailureCooldownUntilMs = currentMs() + Self.ms(configuration.mintFailureCooldownSeconds)
            return nil
        }
    }

    private func currentMs() -> Int64 {
        Int64(configuration.now().timeIntervalSince1970 * 1000)
    }

    private static func ms(_ seconds: Double) -> Int64 {
        Int64(seconds * 1000)
    }
}

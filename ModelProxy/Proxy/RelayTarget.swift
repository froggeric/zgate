import CryptoKit
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOHTTP1
import AsyncHTTPClient
import OSLog

/// The zcode signed relay as a forward target (`vendorKind == .relay`).
///
/// Mirrors the zcode CLI request face: the identity header set (order + UA
/// per the official CLI 0.17.1, pinned by `v3-relay-request.json`) is built
/// from scratch — client headers never leak
/// upstream — the top-level `model` value is rewritten to the GLM-canonical
/// rule target with a byte-preserving splice, and every request carries the
/// per-request V4 signing quartet (`x-client-ts`/`-nonce`/`-pow`/`-sig`)
/// over the SigningClient's minted project token and handshake-unsealed
/// Ed25519 key. Streaming back to the client stays ResponseRelay's job —
/// this type only produces the upstream exchange.
///
/// Failure policy (live-verified: the relay 401-rejects valid tokens without
/// signing headers, so there is NO unsigned cold path):
/// - Signing runs first; a cold start waits for the handshake, and a failed
///   handshake is a 502 — the request never goes out unsigned.
/// - A relay 401 is noted (`noteRelayRejection`); two consecutive rejects
///   force one chain rebuild + one signed retry. A still-failing rebuild
///   falls back to ONE unsigned attempt, and only if a signed chain had been
///   established earlier in this process. A terminal 401 path surfaces
///   `CredentialEvent.expired` for the re-login alert.
/// - Non-2xx bodies and JSON 200s are classified by business code
///   (`RelayErrorTaxonomy`, parsed JSON only): quota (1005/1113/1310, 402)
///   never retries and ticks the quota poll; rate limits (1302/1303, or a
///   bare 429) retry once after a backoff; concurrency (3008/3009/3010)
///   retries twice in place; risk control (3012, 405) never retries; captcha
///   (3007), model (3006), and parameter (1210/3001) errors surface as-is.
enum RelayTarget {

    // Identity constants pinned from the official zcode CLI 0.17.1 face
    // (Task 1 capture, corrected to the CLI wire order/UA in Task 2).
    // `clientVersion` is the BUNDLED DEFAULT of the configured pin
    // (`AppConfig.relayClientVersion`, server-driven via VersionPinService,
    // Task 4); the runtime face derives from the configured value through
    // `Context.clientVersion`.
    static let clientVersion = "0.17.1"
    /// Official CLI UA — built from the version, never a frozen literal
    /// (the relay face is `ai-sdk/anthropic/3.0.81`, not provider-utils).
    static func userAgent(for version: String) -> String {
        "ZCode/\(version) ai-sdk/anthropic/3.0.81"
    }
    static let appId = "zcode"
    static let anthropicBeta = "mid-conversation-system-2026-04-07"
    static let anthropicVersion = "2023-06-01"
    static let httpReferer = "https://zcode.z.ai"
    static let title = "Z Code@cli"
    static let zcodeAgent = "glm"
    static let querySource = "main_turn"
    static let clientLanguage = "en-US"
    /// Relay 429: one retry after this backoff before fallback / 529.
    static let defaultRateLimitBackoff: TimeInterval = 1

    /// zbridge `GLM_FAMILY` — canonical wire names of the GLM family.
    static let glmFamily: [String] = [
        "GLM-5.3", "GLM-5.3-Flash", "GLM-5V-Turbo", "GLM-5.2", "GLM-5.1", "GLM-5.1-Highspeed",
        "GLM-5", "GLM-5-Turbo", "GLM-4.7", "GLM-4.7-FlashX", "GLM-4.7-Flash", "GLM-4.6", "GLM-4.5-Air",
        "GLM-4.5", "GLM-4.6V", "GLM-4.6V-Flash", "GLM-4.6V-FlashX", "GLM-4.1V-Thinking-FlashX",
        "GLM-4.1V-Thinking-Flash", "GLM-4-FlashX-250414", "GLM-4-Flash-250414", "GLM-4V-Flash",
    ]
    /// Retired GLM names the relay no longer serves (upstream 400 code 3006).
    /// Documented routing-compatibility transform: they are canonicalized to
    /// the current main model before send. Flash-suffixed variants map to
    /// flash — the flash-substring rule in `canonicalModel` already runs
    /// first, so those entries are belt-and-braces.
    private static let retiredModelAliases: [String: String] = [
        "glm-5.2": "GLM-5.3",
        "glm-5.1": "GLM-5.3",
        "glm-5.1-highspeed": "GLM-5.3",
        "glm-5-turbo": "GLM-5.3",
        "glm-4.7": "GLM-5.3",
        "glm-turbo": "GLM-5.3",
        "glm-5.2-flash": "GLM-5.3-Flash",
        "glm-5.1-flash": "GLM-5.3-Flash",
        "glm-5.1-highspeed-flash": "GLM-5.3-Flash",
        "glm-5-turbo-flash": "GLM-5.3-Flash",
        "glm-4.7-flash": "GLM-5.3-Flash",
        "glm-turbo-flash": "GLM-5.3-Flash",
    ]

    /// zbridge `GLM_FAMILY` self-map, with retired names (upstream 400 code
    /// 3006) overridden onto the current main/flash model — a documented
    /// routing-compatibility transform.
    private static let glmCanon: [String: String] = Dictionary(
        uniqueKeysWithValues: glmFamily.map { ($0.lowercased(), $0) })
        .merging(retiredModelAliases) { _, retired in retired }

    enum RelayTargetError: Error {
        /// The signing quartet could not be produced (PoW search exhausted,
        /// signature failure). Never retried unsigned on a cold start.
        case signingMaterialUnavailable(String)
    }

    /// Outcome of one relay exchange after the failure policy ran.
    enum Outcome {
        /// A response to stream back as-is: success, a passed-through first
        /// 401 (rewrapped with its drained body), or any other upstream status.
        case responded(HTTPClientResponse)
        /// Relay answered 429 (or a classified rate limit) again after the
        /// backoff retry — the caller tries the rule's backup target, or
        /// answers 529.
        case rateLimitedAfterRetry
        /// Plan quota exhausted (codes 1005/1113/1310 or HTTP 402): no retry
        /// ran, the quota poll was ticked, and the caller answers a
        /// 429-shaped error (Task 7's degraded machine branches on this).
        case quotaExhausted(String)
        /// Risk control (code 3012 or HTTP 405): no retry, the risk event
        /// fired, and the caller answers a clear 502 (Task 7 enters its
        /// riskCooldown from the same event).
        case riskControl(String)
        /// Concurrency-limited (codes 3008/3009/3010) after both in-place
        /// retries — the caller's fallback decision (backup rule or 529),
        /// like rate-limited.
        case concurrencyLimitedAfterRetries
        /// Signing chain unavailable and nothing was sent (cold start).
        case signingUnavailable(String)
        /// Reject ladder exhausted on 401s — re-login required. The expired
        /// event has already been emitted to the credential channel.
        case credentialsExpired(String)
        /// Relay transport failure before a status arrived.
        case transportFailed(String)
    }

    /// A proxy-authored terminal response for outcomes that produced no
    /// streamable upstream response (written by ProxyForwarder).
    struct UpstreamTerminal: Sendable, Equatable {
        let status: Int
        let anthropicType: String
        let message: String
    }

    /// Per-process wiring handed down through ProxyForwarder (built by the
    /// server layer). One per app run: `sessionID` is the FALLBACK relay
    /// session id, used when a request carries no usable Claude Code session
    /// header — the per-conversation identity itself is derived per request
    /// (`SessionIdentity.derive`).
    final class Context {
        let signingClient: SigningClient
        let credentialEvents: CredentialEventChannel?
        /// Quota poll request-counter (Task 8): notified once per relayed
        /// request so QuotaService refreshes after every 25th one. nil in
        /// tests and when no quota service is configured.
        let quota: (any QuotaRelayCounting)?
        /// Server-driven endpoint routing (`agent/configs`, relay fidelity
        /// Task 1): consulted per request in `sendOnce`. nil = fail-open —
        /// the pinned target URL serves as-is (tests, isolated test host).
        let endpointConfig: (any EndpointResolving)?
        /// Per-process fallback relay session id (`x-session-id` when the
        /// inbound CC session header is absent or garbage).
        let sessionID = UUID().uuidString.lowercased()
        /// The impersonated CLI version — the single source of the four
        /// version surfaces (UA input, `x-zcode-app-version`,
        /// `x-client-version`, sig-message version). Loaded from config at
        /// build time (bundled constant as the default) and bumped in place
        /// by VersionPinService's sink when the server minimum rises.
        var clientVersion: String
        /// Relay 429 backoff before the single retry (tests shorten it).
        var rateLimitBackoff: TimeInterval = RelayTarget.defaultRateLimitBackoff
        /// Task 6: risk-control observation (business code 3012 / HTTP 405).
        /// No retry runs and a clear 502 surfaces; Task 7's RelayHealth
        /// consumes this to enter its 900 s riskCooldown. nil when nobody
        /// observes.
        let onRiskControl: (@Sendable (String) -> Void)?
        /// Task 7's relay health machine — the degraded-signing/risk-cooldown
        /// admission gate and the fallback edge's key lifecycle, consulted by
        /// ProxyForwarder.executeRelay. nil = fail-open (tests, legacy
        /// contexts): every request attempts the signed ladder, exactly like
        /// the pre-Task-7 behavior.
        let relayHealth: RelayHealth?
        /// Concurrency-limited retries (codes 3008/3009/3010) sleep 3 s then
        /// 6 s, each ±1 s jitter, through this seam — injectable like
        /// `rateLimitBackoff` (tests record the requested delays).
        var concurrencySleeper: @Sendable (TimeInterval) async -> Void = { delay in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
        }
        /// True once a signing chain has been established in this process —
        /// the only state from which the unsigned fail-open attempt may run.
        private(set) var establishedSignedSession = false

        init(
            signingClient: SigningClient,
            credentialEvents: CredentialEventChannel? = nil,
            quota: (any QuotaRelayCounting)? = nil,
            endpointConfig: (any EndpointResolving)? = nil,
            clientVersion: String = RelayTarget.clientVersion,
            onRiskControl: (@Sendable (String) -> Void)? = nil,
            relayHealth: RelayHealth? = nil
        ) {
            self.signingClient = signingClient
            self.credentialEvents = credentialEvents
            self.quota = quota
            self.endpointConfig = endpointConfig
            self.clientVersion = clientVersion
            self.onRiskControl = onRiskControl
            self.relayHealth = relayHealth
        }

        func noteSignedSessionEstablished() {
            establishedSignedSession = true
        }
    }

    /// Per-conversation relay session identity, derived once per exchange at
    /// `execute()` entry from the inbound Claude Code headers (mirroring the
    /// CLI's per-conversation `sess_` semantics; the CC headers are only
    /// read, never forwarded). ONE identity feeds everything the server sees:
    /// the `x-session-id` header, the PoW challenge input, and the Ed25519
    /// sig message — self-consistent by construction.
    struct SessionIdentity: Equatable, Sendable {
        static let mainType = "main"
        static let subagentType = "subagent"

        /// `x-session-id` — also the PoW + sig-message session id.
        let id: String
        /// `x-zcode-session-type` — `main` or `subagent`.
        let type: String

        /// A sanitized inbound conversation id wins; absent/garbage falls
        /// back to the per-process id. A present agent id marks a subagent
        /// turn with its own per-agent derived id (CLI `subagent_agent_`
        /// sessions parity).
        static func derive(from head: HTTPRequestHead, fallback: String) -> SessionIdentity {
            let base = sanitize(head.headers.first(name: ProxyForwarder.claudeCodeSessionHeader))
                ?? fallback
            guard let agentID = head.headers.first(name: ProxyForwarder.claudeCodeAgentHeader),
                !agentID.isEmpty
            else {
                return SessionIdentity(id: base, type: mainType)
            }
            return SessionIdentity(id: "\(base)-\(shortHash(agentID))", type: subagentType)
        }

        /// Lowercases and keeps only ASCII hex characters and `-`; ids under
        /// 8 chars (before or after cleaning) or over 64 are rejected —
        /// garbage falls back to the per-process id.
        static func sanitize(_ raw: String?) -> String? {
            guard let raw, raw.count >= 8, raw.count <= 64 else { return nil }
            let cleaned = raw.lowercased().filter { ($0.isASCII && $0.isHexDigit) || $0 == "-" }
            return cleaned.count >= 8 ? cleaned : nil
        }

        /// First 8 hex chars of SHA-256 — the per-agent session suffix.
        static func shortHash(_ s: String) -> String {
            SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8).description
        }
    }

    // MARK: - Exchange

    /// One relay exchange with the full failure policy applied.
    static func execute(
        head: HTTPRequestHead,
        bodyData: Data,
        target: RoutingSnapshot.RouteTarget,
        httpClient: HTTPClient,
        context: Context,
        requestID: String
    ) async -> Outcome {
        // One counter tick per relay EXCHANGE (execute entry) for the quota
        // poll cadence: the 429 backoff retry runs inside this call (one
        // tick), but a rate-limit failover re-enters execute for the backup
        // relay and ticks again — an exchange is real relay work, and the
        // 25-request trigger counts exchanges, not client requests.
        context.quota?.noteRelayedRequest()

        // Session identity is derived ONCE per exchange from the inbound CC
        // headers (fallback: the per-process id) — the header, PoW, and sig
        // use this one id for every send in the ladder, retries included.
        let identity = SessionIdentity.derive(from: head, fallback: context.sessionID)

        // Signing first: a cold start waits for the handshake here, and a
        // handshake failure NEVER falls back to an unsigned request.
        let session: SigningSession
        do {
            session = try await context.signingClient.ensureSession()
        } catch {
            let reason = signingFailureReason(error)
            AppLog.proxy.error("[Proxy] [\(requestID)] Relay signing unavailable: \(reason)")
            if case SigningClientError.reloginRequired = error {
                context.credentialEvents?.emit(.expired(reason: reason))
                return .credentialsExpired(reason)
            }
            return .signingUnavailable(reason)
        }
        context.noteSignedSessionEstablished()
        return await sendSigned(
            head: head, identity: identity, bodyData: bodyData, target: target, httpClient: httpClient,
            session: session, context: context, requestID: requestID)
    }

    private static func sendSigned(
        head: HTTPRequestHead,
        identity: SessionIdentity,
        bodyData: Data,
        target: RoutingSnapshot.RouteTarget,
        httpClient: HTTPClient,
        session: SigningSession,
        context: Context,
        requestID: String
    ) async -> Outcome {
        let wireBody = Self.wireBody(bodyData: bodyData, target: target)
        do {
            let response = try await sendOnce(
                head: head, identity: identity, wireBody: wireBody, target: target, httpClient: httpClient,
                session: session, signed: true, context: context, requestID: requestID)
            return await route(
                response: response, session: session, signed: true, head: head, identity: identity,
                wireBody: wireBody, target: target, httpClient: httpClient,
                context: context, requestID: requestID)
        } catch let error as RelayTargetError {
            let reason = String(describing: error)
            AppLog.proxy.error("[Proxy] [\(requestID)] Relay signing material unavailable: \(reason)")
            return .signingUnavailable(reason)
        } catch {
            AppLog.proxy.error("[Proxy] [\(requestID)] Relay upstream error: \(error)")
            return .transportFailed(String(describing: error))
        }
    }

    // MARK: - Response routing (Task 6 taxonomy)

    /// Routes one upstream response: the 401 ladder is untouched; the 429
    /// and other-status paths classify the drained body first so business
    /// codes drive remediation; 2xx responses run the 200-carried-envelope
    /// check before counting as success.
    private static func route(
        response: HTTPClientResponse,
        session: SigningSession,
        signed: Bool,
        head: HTTPRequestHead,
        identity: SessionIdentity,
        wireBody: Data,
        target: RoutingSnapshot.RouteTarget,
        httpClient: HTTPClient,
        context: Context,
        requestID: String
    ) async -> Outcome {
        switch Int(response.status.code) {
        case 200..<300:
            return await handleSuccess(
                response: response, session: session, signed: signed, head: head, identity: identity,
                wireBody: wireBody, target: target, httpClient: httpClient,
                context: context, requestID: requestID)
        case 401:
            return await handleReject(
                response: response, session: session, head: head, identity: identity,
                wireBody: wireBody, target: target,
                httpClient: httpClient, context: context, requestID: requestID)
        case 429:
            return await handleFourTwentyNine(
                response: response, session: session, signed: signed, head: head, identity: identity,
                wireBody: wireBody, target: target, httpClient: httpClient,
                context: context, requestID: requestID)
        default:
            return await handleOtherStatus(
                response: response, session: session, signed: signed, head: head, identity: identity,
                wireBody: wireBody, target: target, httpClient: httpClient,
                context: context, requestID: requestID)
        }
    }

    /// What a 2xx response turned out to be after the 200-envelope peek.
    private enum SuccessCheck {
        /// A real success — the original response (unread) or a rewrapped
        /// one carrying the same bytes (read and ruled NOT an envelope).
        case plain(HTTPClientResponse)
        /// A 200 whose body is a business envelope — classify, do not relay.
        case envelope(RelayUpstreamError, HTTPClientResponse)
    }

    /// The 200-carried-envelope check: a JSON (never SSE) 2xx whose body is
    /// envelope-sized is drained whole and parsed. Anything else — SSE,
    /// missing content-type, a content-length beyond envelope size — is
    /// left untouched on the wire.
    private static func checkSuccess(_ response: HTTPClientResponse) async -> SuccessCheck {
        guard isJSONResponse(response), isEnvelopeSized(response) else { return .plain(response) }
        let (data, rewrapped) = await drainWholeBody(response)
        if let envelope = RelayErrorTaxonomy.businessEnvelope(
            status: Int(response.status.code), body: data)
        {
            return .envelope(envelope, rewrapped)
        }
        return .plain(rewrapped)
    }

    /// 2xx handling: a 200 carrying a business envelope (`code != 0`, no
    /// `type:"message"`) is classified and remediated instead of relayed as
    /// success; every other 2xx — streaming or not — relays byte-identical.
    private static func handleSuccess(
        response: HTTPClientResponse,
        session: SigningSession,
        signed: Bool,
        head: HTTPRequestHead,
        identity: SessionIdentity,
        wireBody: Data,
        target: RoutingSnapshot.RouteTarget,
        httpClient: HTTPClient,
        context: Context,
        requestID: String
    ) async -> Outcome {
        switch await checkSuccess(response) {
        case .plain(let relayable):
            await context.signingClient.noteRelaySuccess(signed: signed)
            return .responded(relayable)
        case .envelope(let error, let rewrapped):
            AppLog.proxy.error(
                "[Proxy] [\(requestID)] Relay 200 carries business envelope (code \(error.code.map(String.init) ?? "nil")): \(error.displayReason)")
            return await handleClassifiedFailure(
                kind: RelayErrorTaxonomy.classify(error), error: error, rewrapped: rewrapped,
                session: session, signed: signed, head: head, identity: identity,
                wireBody: wireBody, target: target, httpClient: httpClient,
                context: context, requestID: requestID, retriesAllowed: true)
        }
    }

    /// A relay 429 entry: the drained body is classified first — quota,
    /// concurrency, and risk codes override the default rate-limit policy;
    /// a true rate-limit code (1302/1303) or an unclassifiable 429 rides
    /// the existing single-backoff-retry policy unchanged.
    private static func handleFourTwentyNine(
        response: HTTPClientResponse,
        session: SigningSession,
        signed: Bool,
        head: HTTPRequestHead,
        identity: SessionIdentity,
        wireBody: Data,
        target: RoutingSnapshot.RouteTarget,
        httpClient: HTTPClient,
        context: Context,
        requestID: String
    ) async -> Outcome {
        let (error, rewrapped) = await drainErrorBody(response)
        let kind = RelayErrorTaxonomy.classify(error)
        switch kind {
        case .rateLimited, .unclassified:
            return await handleRateLimited(
                response: rewrapped, head: head, identity: identity, wireBody: wireBody, target: target,
                httpClient: httpClient, session: session, signed: signed,
                context: context, requestID: requestID)
        case .quotaExhausted, .riskControl, .concurrencyLimited,
            .captchaChallenge, .modelNotAllowed, .invalidParameter:
            return await handleClassifiedFailure(
                kind: kind, error: error, rewrapped: rewrapped,
                session: session, signed: signed, head: head, identity: identity,
                wireBody: wireBody, target: target, httpClient: httpClient,
                context: context, requestID: requestID, retriesAllowed: true)
        }
    }

    /// Any other upstream status: drain + classify, then remediate by
    /// class (quota codes on 4xx bodies, 402/405 status fallbacks, or
    /// passthrough for everything unclassified).
    private static func handleOtherStatus(
        response: HTTPClientResponse,
        session: SigningSession,
        signed: Bool,
        head: HTTPRequestHead,
        identity: SessionIdentity,
        wireBody: Data,
        target: RoutingSnapshot.RouteTarget,
        httpClient: HTTPClient,
        context: Context,
        requestID: String
    ) async -> Outcome {
        let (error, rewrapped) = await drainErrorBody(response)
        return await handleClassifiedFailure(
            kind: RelayErrorTaxonomy.classify(error), error: error, rewrapped: rewrapped,
            session: session, signed: signed, head: head, identity: identity,
            wireBody: wireBody, target: target, httpClient: httpClient,
            context: context, requestID: requestID, retriesAllowed: true)
    }

    /// Remediation by failure class — the taxonomy's whole point. ENTRY
    /// positions (`retriesAllowed == true`: the first classification of a
    /// fresh send) may start the rate-limit or concurrency ladder; INSIDE a
    /// retry ladder (`false`) those two classes resolve terminally instead —
    /// a carrier flipping between shapes (400+1302, then 429+3009, ...) must
    /// never buy fresh retry ladders, so the exchange stays bounded no
    /// matter what the upstream answers.
    private static func handleClassifiedFailure(
        kind: RelayFailureKind,
        error: RelayUpstreamError,
        rewrapped: HTTPClientResponse,
        session: SigningSession,
        signed: Bool,
        head: HTTPRequestHead,
        identity: SessionIdentity,
        wireBody: Data,
        target: RoutingSnapshot.RouteTarget,
        httpClient: HTTPClient,
        context: Context,
        requestID: String,
        retriesAllowed: Bool
    ) async -> Outcome {
        switch kind {
        case .quotaExhausted:
            // No retry: tick the quota poll immediately so the true fraction
            // is known now, then answer 429-shaped (Task 7 routes degraded
            // fallback from this class).
            let reason = error.displayReason
            AppLog.proxy.error("[Proxy] [\(requestID)] Relay quota exhausted: \(reason)")
            await context.quota?.pollNow()
            return .quotaExhausted(reason)
        case .rateLimited:
            // Entry: a classified rate limit (1302/1303) rides the existing
            // policy unchanged — one backoff retry, then the caller's
            // fallback. Inside a retry ladder: terminal, no re-entry.
            guard retriesAllowed else { return .rateLimitedAfterRetry }
            return await handleRateLimited(
                response: rewrapped, head: head, identity: identity, wireBody: wireBody, target: target,
                httpClient: httpClient, session: session, signed: signed,
                context: context, requestID: requestID)
        case .concurrencyLimited:
            // Entry: up to 2 in-place retries. Inside a retry ladder:
            // terminal, no re-entry (a fresh ladder per cycle would loop).
            guard retriesAllowed else { return .concurrencyLimitedAfterRetries }
            return await handleConcurrencyLimited(
                session: session, signed: signed, head: head, identity: identity,
                wireBody: wireBody, target: target, httpClient: httpClient,
                context: context, requestID: requestID)
        case .riskControl:
            // No retry: expose the event (Task 7's RelayHealth enters its
            // cooldown from here) and surface a clear 502.
            let reason = error.displayReason
            AppLog.proxy.error("[Proxy] [\(requestID)] Relay risk control engaged: \(reason)")
            context.onRiskControl?(reason)
            return .riskControl(reason)
        case .captchaChallenge, .modelNotAllowed, .invalidParameter, .unclassified:
            // Surfaced as-is: captcha is never solved; 3006/1210/3001 are
            // request errors the client sees verbatim (Task 5 prevents the
            // common ones before send); anything unclassified passes
            // through exactly like the pre-taxonomy default branch.
            return .responded(rewrapped)
        }
    }

    /// Concurrency-limited (codes 3008/3009/3010): up to 2 in-place retries
    /// on the same target — 3 s then 6 s, each ±1 s jitter through the
    /// injectable sleeper — then the caller's fallback decision (backup
    /// rule or 529). Mid-ladder answers that are NOT still
    /// concurrency-limited resolve terminally through the taxonomy (no
    /// re-entry into this ladder or the rate-limit ladder — a 200 carrying
    /// a concurrency code burns the attempt, and a non-200 carrier with a
    /// concurrency/rate-limit code cannot spawn fresh ladders per cycle —
    /// so a looping upstream cannot drive unbounded nesting).
    private static func handleConcurrencyLimited(
        session: SigningSession,
        signed: Bool,
        head: HTTPRequestHead,
        identity: SessionIdentity,
        wireBody: Data,
        target: RoutingSnapshot.RouteTarget,
        httpClient: HTTPClient,
        context: Context,
        requestID: String
    ) async -> Outcome {
        for base in [TimeInterval(3), TimeInterval(6)] {
            await context.concurrencySleeper(max(0, base + Double.random(in: -1...1)))
            do {
                let retry = try await sendOnce(
                    head: head, identity: identity, wireBody: wireBody, target: target,
                    httpClient: httpClient, session: session, signed: signed,
                    context: context, requestID: requestID)
                switch Int(retry.status.code) {
                case 200..<300:
                    switch await checkSuccess(retry) {
                    case .plain(let relayable):
                        await context.signingClient.noteRelaySuccess(signed: signed)
                        return .responded(relayable)
                    case .envelope(let envelopeError, let envelopeRewrapped):
                        guard RelayErrorTaxonomy.classify(envelopeError) != .concurrencyLimited else {
                            continue  // 200 still carrying a concurrency code: burn the attempt
                        }
                        return await handleClassifiedFailure(
                            kind: RelayErrorTaxonomy.classify(envelopeError), error: envelopeError,
                            rewrapped: envelopeRewrapped, session: session, signed: signed, head: head,
                            identity: identity, wireBody: wireBody, target: target,
                            httpClient: httpClient, context: context, requestID: requestID,
                            retriesAllowed: false)
                    }
                case 401:
                    return await handleReject(
                        response: retry, session: session, head: head, identity: identity,
                        wireBody: wireBody, target: target,
                        httpClient: httpClient, context: context, requestID: requestID)
                case 429:
                    let (retryError, retryRewrapped) = await drainErrorBody(retry)
                    switch RelayErrorTaxonomy.classify(retryError) {
                    case .concurrencyLimited:
                        continue  // next backoff
                    case .rateLimited, .unclassified:
                        // No re-entry into the rate-limit ladder from inside
                        // this one: a rate-limit answer mid-ladder is
                        // terminal (the caller's fallback).
                        return .rateLimitedAfterRetry
                    case .quotaExhausted, .riskControl,
                        .captchaChallenge, .modelNotAllowed, .invalidParameter:
                        return await handleClassifiedFailure(
                            kind: RelayErrorTaxonomy.classify(retryError), error: retryError,
                            rewrapped: retryRewrapped, session: session, signed: signed, head: head,
                            identity: identity, wireBody: wireBody, target: target,
                            httpClient: httpClient, context: context, requestID: requestID,
                            retriesAllowed: false)
                    }
                default:
                    // No ladder re-entry: a non-200 carrier with a
                    // concurrency code (e.g. HTTP 400 + {"code":3008})
                    // resolves terminally here — it must not spawn a fresh
                    // 2-attempt ladder per cycle.
                    let (error, rewrapped) = await drainErrorBody(retry)
                    return await handleClassifiedFailure(
                        kind: RelayErrorTaxonomy.classify(error), error: error, rewrapped: rewrapped,
                        session: session, signed: signed, head: head,
                        identity: identity, wireBody: wireBody, target: target,
                        httpClient: httpClient, context: context, requestID: requestID,
                        retriesAllowed: false)
                }
            } catch {
                return .transportFailed(String(describing: error))
            }
        }
        return .concurrencyLimitedAfterRetries
    }

    /// A relay 401: note it, and on the second consecutive reject rebuild the
    /// chain once and retry once. A failing rebuild falls back to a single
    /// unsigned attempt — but only after a previously established signed
    /// session (never on a cold start).
    private static func handleReject(
        response: HTTPClientResponse,
        session: SigningSession,
        head: HTTPRequestHead,
        identity: SessionIdentity,
        wireBody: Data,
        target: RoutingSnapshot.RouteTarget,
        httpClient: HTTPClient,
        context: Context,
        requestID: String
    ) async -> Outcome {
        await context.signingClient.noteRelayRejection()
        let phase = await context.signingClient.currentPhase()
        let (drained, rewrapped) = await drainErrorBody(response)
        let message = drained.message

        guard phase == .needsRehandshake else {
            // First reject: tolerated (controller ruling — two consecutive
            // rejects trigger the rebuild). Pass through, surfacing an
            // explicit expiry signal if the relay named one (the envelope
            // message field, never a raw-body substring).
            if let message, message.localizedCaseInsensitiveContains("expired") {
                context.credentialEvents?.emit(.expired(reason: message))
            }
            return .responded(rewrapped)
        }

        do {
            let fresh = try await context.signingClient.ensureSession(force: true)
            AppLog.proxy.info("[Proxy] [\(requestID)] Relay 401 x2 — chain rebuilt, retrying once")
            let retry = try await sendOnce(
                head: head, identity: identity, wireBody: wireBody, target: target, httpClient: httpClient,
                session: fresh, signed: true, context: context, requestID: requestID)
            switch Int(retry.status.code) {
            case 200..<300:
                return await handleSuccess(
                    response: retry, session: fresh, signed: true, head: head, identity: identity,
                    wireBody: wireBody, target: target, httpClient: httpClient,
                    context: context, requestID: requestID)
            case 401:
                await context.signingClient.noteRelayRejection()
                let (retryDrained, retryRewrapped) = await drainErrorBody(retry)
                let reason = retryDrained.message ?? message ?? "relay 401 after chain rebuild"
                context.credentialEvents?.emit(.expired(reason: reason))
                _ = retryRewrapped  // terminal: the 502 body is proxy-authored
                return .credentialsExpired(reason)
            case 429:
                return await handleFourTwentyNine(
                    response: retry, session: fresh, signed: true, head: head, identity: identity,
                    wireBody: wireBody, target: target, httpClient: httpClient,
                    context: context, requestID: requestID)
            default:
                return await handleOtherStatus(
                    response: retry, session: fresh, signed: true, head: head, identity: identity,
                    wireBody: wireBody, target: target, httpClient: httpClient,
                    context: context, requestID: requestID)
            }
        } catch {
            let reason = signingFailureReason(error)
            if context.establishedSignedSession {
                // Fail-open, bounded to one attempt and reachable only after
                // a previously established signed session. Live wire says the
                // relay rejects unsigned tokens — this is the last resort
                // before surfacing expiry. The twice-rejected project token
                // still rides along (unsigned = no signing quartet, not no auth).
                AppLog.proxy.warning(
                    "[Proxy] [\(requestID)] Relay rebuild failed (\(reason)) — one unsigned fail-open attempt")
                return await sendFailOpen(
                    head: head, identity: identity, wireBody: wireBody, target: target, httpClient: httpClient,
                    session: session, context: context, requestID: requestID, previousMessage: message)
            }
            AppLog.proxy.error("[Proxy] [\(requestID)] Relay rebuild failed cold: \(reason)")
            if case SigningClientError.reloginRequired = error {
                context.credentialEvents?.emit(.expired(reason: reason))
                return .credentialsExpired(reason)
            }
            return .signingUnavailable(reason)
        }
    }

    /// A relay rate-limit entry (a 429 status, or a classified 1302/1303 on
    /// any status): one backoff retry on the same target; a second
    /// rate-limit answer moves the decision to the caller (next-rule
    /// fallback or 529). The policy itself is unchanged from the
    /// pre-taxonomy ladder — classification only decides who enters it, and
    /// nothing inside this ladder (retry envelopes, non-200 carriers) may
    /// re-enter it or the concurrency ladder: classified failures inside a
    /// retry are terminal.
    private static func handleRateLimited(
        response: HTTPClientResponse,
        head: HTTPRequestHead,
        identity: SessionIdentity,
        wireBody: Data,
        target: RoutingSnapshot.RouteTarget,
        httpClient: HTTPClient,
        session: SigningSession,
        signed: Bool,
        context: Context,
        requestID: String
    ) async -> Outcome {
        _ = response  // terminal for the ladder: the caller answers 529/fallback
        AppLog.proxy.info("[Proxy] [\(requestID)] Relay rate limited — one retry after backoff")
        let backoffNanos = UInt64(max(0, context.rateLimitBackoff) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: backoffNanos)
        do {
            let retry = try await sendOnce(
                head: head, identity: identity, wireBody: wireBody, target: target, httpClient: httpClient,
                session: session, signed: signed, context: context, requestID: requestID)
            switch Int(retry.status.code) {
            case 200..<300:
                // The 200-envelope check applies to the retry too, but its
                // classified failures resolve terminally (retriesAllowed:
                // false) — a rate-limit/concurrency carrier under a 200 must
                // not spawn fresh ladders from inside this one.
                switch await checkSuccess(retry) {
                case .plain(let relayable):
                    await context.signingClient.noteRelaySuccess(signed: signed)
                    return .responded(relayable)
                case .envelope(let error, let rewrapped):
                    return await handleClassifiedFailure(
                        kind: RelayErrorTaxonomy.classify(error), error: error, rewrapped: rewrapped,
                        session: session, signed: signed, head: head, identity: identity,
                        wireBody: wireBody, target: target, httpClient: httpClient,
                        context: context, requestID: requestID, retriesAllowed: false)
                }
            case 401:
                return await handleReject(
                    response: retry, session: session, head: head, identity: identity,
                    wireBody: wireBody, target: target,
                    httpClient: httpClient, context: context, requestID: requestID)
            case 429:
                return .rateLimitedAfterRetry
            default:
                // No ladder re-entry: a non-429/non-200 carrier (e.g. HTTP
                // 400 + {"code":1302} forever) classifies here and resolves
                // terminally — handleOtherStatus is entry-only.
                let (error, rewrapped) = await drainErrorBody(retry)
                return await handleClassifiedFailure(
                    kind: RelayErrorTaxonomy.classify(error), error: error, rewrapped: rewrapped,
                    session: session, signed: signed, head: head, identity: identity,
                    wireBody: wireBody, target: target, httpClient: httpClient,
                    context: context, requestID: requestID, retriesAllowed: false)
            }
        } catch {
            return .transportFailed(String(describing: error))
        }
    }

    private static func sendFailOpen(
        head: HTTPRequestHead,
        identity: SessionIdentity,
        wireBody: Data,
        target: RoutingSnapshot.RouteTarget,
        httpClient: HTTPClient,
        session: SigningSession,
        context: Context,
        requestID: String,
        previousMessage: String?
    ) async -> Outcome {
        do {
            let response = try await sendOnce(
                head: head, identity: identity, wireBody: wireBody, target: target, httpClient: httpClient,
                session: session, signed: false, context: context, requestID: requestID)
            switch Int(response.status.code) {
            case 200..<300:
                // handleSuccess marks the success UNSIGNED (UI item 5) after
                // the same 200-envelope check the signed path runs.
                return await handleSuccess(
                    response: response, session: session, signed: false, head: head,
                    identity: identity, wireBody: wireBody, target: target,
                    httpClient: httpClient, context: context, requestID: requestID)
            case 401:
                await context.signingClient.noteRelayRejection()
                let (drained, _) = await drainErrorBody(response)
                let reason = drained.message ?? previousMessage ?? "relay 401 (unsigned fail-open)"
                context.credentialEvents?.emit(.expired(reason: reason))
                return .credentialsExpired(reason)
            case 429:
                // Same rate-limit policy as the signed path: one backoff
                // retry (also unsigned), then the caller's decision.
                return await handleFourTwentyNine(
                    response: response, session: session, signed: false, head: head,
                    identity: identity, wireBody: wireBody, target: target,
                    httpClient: httpClient, context: context, requestID: requestID)
            default:
                return await handleOtherStatus(
                    response: response, session: session, signed: false, head: head,
                    identity: identity, wireBody: wireBody, target: target,
                    httpClient: httpClient, context: context, requestID: requestID)
            }
        } catch {
            return .transportFailed(String(describing: error))
        }
    }

    /// One HTTP exchange. `signed == false` is the fail-open unsigned attempt:
    /// identity + auth headers, no signing quartet. The URL is resolved
    /// through the endpoint-routing service first (fail-open: routing
    /// failures or no match leave the pinned URL untouched).
    private static func sendOnce(
        head: HTTPRequestHead,
        identity: SessionIdentity,
        wireBody: Data,
        target: RoutingSnapshot.RouteTarget,
        httpClient: HTTPClient,
        session: SigningSession,
        signed: Bool,
        context: Context,
        requestID: String
    ) async throws -> HTTPClientResponse {
        let rawURL = target.baseURL.trimmingCharacters(in: .init(charactersIn: "/")) + head.uri
        var urlString = rawURL
        var zcodeAuthorization: String?
        if let endpointConfig = context.endpointConfig {
            let resolved = await endpointConfig.resolve(rawURL)
            urlString = resolved.url
            if resolved.addZcodeAuthorization {
                // Fail-open on the token too: absent store → header omitted.
                zcodeAuthorization = await endpointConfig.zcodeAuthorizationToken()
            }
        }
        var request = HTTPClientRequest(url: urlString)
        request.method = head.method
        request.headers = try relayHeaders(
            session: session, signed: signed, identity: identity,
            zcodeAuthorization: zcodeAuthorization, clientVersion: context.clientVersion)
        request.body = .bytes(wireBody)
        return try await httpClient.execute(
            request, timeout: .seconds(Int64(target.readTimeoutSeconds)))
    }

    // MARK: - Headers

    /// The complete relay header set, built from scratch (client headers are
    /// never forwarded) in the official CLI 0.17.1 wire order (undici/HTTP 1.1
    /// is order-preserving). Auth always rides along; `signed == false` (the
    /// fail-open attempt) omits the signer's whole static block (`x-client-ts`
    /// /`-version`/`-sig`/`-nonce`, `x-app-id`, `x-client-pow`). A non-nil
    /// `zcodeAuthorization` (endpoint routing flagged this request) adds the
    /// `x-zcode-authorization` Bearer header right after `authorization` —
    /// that one is ZGate's routing header, not part of the CLI static face.
    /// The session identity (per-conversation, `SessionIdentity.derive`)
    /// supplies `x-session-id`, `x-zcode-session-type`, AND the PoW/sig
    /// session id — one id everywhere the server looks.
    /// `clientVersion` is the configured pin (Task 4) driving the four
    /// version surfaces — UA input, `x-zcode-app-version`, `x-client-version`,
    /// and the sig message below; the default keeps the bundled constant.
    static func relayHeaders(
        session: SigningSession,
        signed: Bool,
        identity: SessionIdentity,
        zcodeAuthorization: String? = nil,
        clientVersion: String = RelayTarget.clientVersion
    ) throws -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "application/json")
        headers.add(name: "anthropic-version", value: anthropicVersion)
        headers.add(name: "authorization", value: "Bearer \(session.projectToken)")
        if let zcodeAuthorization {
            // Task-1 routing header — rides immediately after `authorization`.
            headers.add(name: "x-zcode-authorization", value: "Bearer \(zcodeAuthorization)")
        }
        headers.add(name: "http-referer", value: httpReferer)
        headers.add(name: "user-agent", value: userAgent(for: clientVersion))
        headers.add(name: "x-zcode-app-version", value: clientVersion)
        headers.add(name: "x-title", value: title)
        headers.add(name: "x-client-language", value: clientLanguage)
        headers.add(name: "x-client-timezone", value: TimeZone.current.identifier)
        headers.add(name: "x-zcode-agent", value: zcodeAgent)
        headers.add(name: "x-platform", value: platform)
        headers.add(name: "x-os-category", value: osCategory)
        headers.add(name: "x-os-version", value: osVersion)
        headers.add(name: "x-request-id", value: UUID().uuidString.lowercased())
        headers.add(name: "x-zcode-session-type", value: identity.type)
        headers.add(name: "x-zcode-trace-id", value: UUID().uuidString.lowercased())
        headers.add(name: "x-query-id", value: UUID().uuidString.lowercased())
        headers.add(name: "x-zcode-query-source", value: querySource)
        headers.add(name: "x-session-id", value: identity.id)
        // The CLI sends its beta flag only when set (ours always is).
        if !anthropicBeta.isEmpty {
            headers.add(name: "anthropic-beta", value: anthropicBeta)
        }
        if signed {
            let ts = String(currentMs())
            let nonce = randomHex32()
            guard let pow = CryptoCore.pow(
                apiKeyId: session.apiKeyId, appId: appId, sessionId: identity.id, ts: ts)
            else {
                throw RelayTargetError.signingMaterialUnavailable("proof-of-work search exhausted")
            }
            let message = CryptoCore.requestSigMessage(
                apiKeyId: session.apiKeyId, ts: ts, version: clientVersion,
                sessionId: identity.id, nonce: nonce)
            let sig: String
            do {
                sig = try CryptoCore.sign(message: Data(message.utf8), privateKey: session.privateKey)
            } catch {
                throw RelayTargetError.signingMaterialUnavailable("ed25519 signature failed")
            }
            headers.add(name: "x-client-ts", value: ts)
            headers.add(name: "x-client-version", value: clientVersion)
            headers.add(name: "x-client-sig", value: sig)
            headers.add(name: "x-client-nonce", value: nonce)
            headers.add(name: "x-app-id", value: appId)
            headers.add(name: "x-client-pow", value: pow.value)
        }
        headers.add(name: "x-api-key", value: session.projectToken)
        return headers
    }

    // MARK: - Body

    /// The wire body: only the top-level `model` value is replaced (canonical
    /// GLM name, byte-preserving splice) and a top-level out-of-range
    /// `max_tokens` clamped into `[1, 131072]` — everything else stays
    /// byte-unchanged.
    static func wireBody(bodyData: Data, target: RoutingSnapshot.RouteTarget) -> Data {
        let canonBody: Data
        if let sourceModel = target.targetModel ?? bodyModelField(bodyData) {
            canonBody = ProxyForwarder.replaceModelField(
                in: bodyData, with: canonicalModel(sourceModel)).data
        } else {
            canonBody = bodyData  // no model field: forward as-is (zbridge parity)
        }
        // Documented routing-compatibility transform: the relay rejects
        // out-of-range max_tokens with 400 code 1210, so clamp before send.
        // Byte-identical no-op when the field is absent or already in range.
        return ProxyForwarder.clampMaxTokensField(canonBody)
    }

    /// Top-level `"model"` field of a request body (nil when unparseable).
    static func bodyModelField(_ bodyData: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
            let model = json["model"] as? String, !model.isEmpty
        else { return nil }
        return model
    }

    /// zbridge `mapModel`: the GLM-canonical wire name for a rule target.
    /// Provider prefixes stripped first, flash check next (matches
    /// `GLM-5.3-Flash` ahead of the 5.3 rule), retired names remapped,
    /// unknown glm-family names map to the main model, unknown names to flash.
    static func canonicalModel(_ model: String) -> String {
        var lowered = model.trimmingCharacters(in: .whitespaces).lowercased()
        // Documented routing-compatibility transform: provider-qualified
        // names ("zai/GLM-5.3", "bigmodel/glm-5.3") drop the qualifier
        // before the lookup.
        for prefix in ["zai/", "bigmodel/"] where lowered.hasPrefix(prefix) {
            lowered = String(lowered.dropFirst(prefix.count))
        }
        if lowered.contains("flash") { return "GLM-5.3-Flash" }
        if lowered.contains("glm-5.3") { return "GLM-5.3" }  // glm-5.3 and glm-5.3[1m]
        if let canon = glmCanon[lowered] { return canon }
        if lowered.hasPrefix("glm-") { return "GLM-5.3" }
        return "GLM-5.3-Flash"  // unknown names → flash (cheap default)
    }

    // MARK: - Error bodies

    /// Reads an error response body (bounded to 8 KiB), parses it into a
    /// `RelayUpstreamError` (business `code` + message, parsed JSON only —
    /// never substrings over the raw bytes), and returns a re-wrapped
    /// response carrying the same bytes so a passthrough can still stream
    /// it (an AsyncHTTPClient body admits a single iterator).
    static func drainErrorBody(_ response: HTTPClientResponse) async
        -> (error: RelayUpstreamError, rewrapped: HTTPClientResponse)
    {
        let data = await readBodyCapped(response, cap: 8192)
        let error = RelayUpstreamError.parse(status: Int(response.status.code), body: data)
            ?? RelayUpstreamError(status: Int(response.status.code))
        return (error, rewrap(response, data))
    }

    /// Reads a response body IN FULL (no cap) and re-wraps the same bytes —
    /// the 200-envelope peek: a legit non-streaming JSON success must come
    /// back byte-identical whatever its size, so truncation is never an
    /// option on this path.
    static func drainWholeBody(_ response: HTTPClientResponse) async
        -> (data: Data, rewrapped: HTTPClientResponse)
    {
        var data = Data()
        do {
            for try await chunk in response.body {
                if let bytes = chunk.getData(at: chunk.readerIndex, length: chunk.readableBytes) {
                    data.append(bytes)
                }
            }
        } catch {
            // Body read failure mid-peek: forward what we have.
        }
        return (data, rewrap(response, data))
    }

    /// The bounded read behind `drainErrorBody` (stops past `cap` bytes).
    private static func readBodyCapped(_ response: HTTPClientResponse, cap: Int) async -> Data {
        var data = Data()
        do {
            for try await chunk in response.body {
                if let bytes = chunk.getData(at: chunk.readerIndex, length: chunk.readableBytes) {
                    data.append(bytes)
                }
                if data.count > cap { break }
            }
        } catch {
            // Body read failure on an error path: forward what we have.
        }
        return data
    }

    /// The single rewrap primitive: same version/status/headers, same bytes.
    private static func rewrap(_ response: HTTPClientResponse, _ data: Data) -> HTTPClientResponse {
        var rewrapped = HTTPClientResponse(
            version: response.version, status: response.status, headers: response.headers)
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        rewrapped.body = .bytes(buffer)
        return rewrapped
    }

    /// JSON content-type (SSE never qualifies) — the 200-envelope check and
    /// only it; every other response body is relayed untouched.
    static func isJSONResponse(_ response: HTTPClientResponse) -> Bool {
        guard let value = response.headers.first(name: "content-type")?.lowercased()
        else { return false }
        return value.contains("json") && !value.contains("event-stream")
    }

    /// Envelope-sized: business envelopes are tiny, so a content-length
    /// beyond the cap cannot be one — skipping the read leaves the stream
    /// untouched for live relay (large non-streaming successes never pay
    /// the buffer). Absent content-length (chunked) still peeks, reading
    /// the whole body so a rewrap is never truncated.
    static func isEnvelopeSized(_ response: HTTPClientResponse) -> Bool {
        guard let raw = response.headers.first(name: "content-length"),
            let length = Int(raw)
        else { return true }
        return length <= 8192
    }

    /// Display reason for a signing-chain failure — typed errors only, never
    /// a credential value.
    static func signingFailureReason(_ error: Error) -> String {
        if let signingError = error as? SigningClientError {
            return signingError.errorDescription ?? String(describing: signingError)
        }
        return String(describing: error)
    }

    // MARK: - Environment identity

    static var osCategory: String { "macos" }

    static var platform: String {
        #if arch(arm64)
            return "darwin-arm64"
        #elseif arch(x86_64)
            return "darwin-x64"
        #else
            return "darwin-unknown"
        #endif
    }

    /// `x-os-version`: the Darwin kernel release — genuine zcode sends
    /// node's `os.release()`, which is `uname(2)`'s `release` ("27.2.0" on
    /// this machine), NOT the macOS product version.
    static var osVersion: String {
        guard let release = darwinKernelRelease else {
            // uname does not fail on Darwin; keep the header's shape anyway.
            let version = ProcessInfo.processInfo.operatingSystemVersion
            return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        }
        return release
    }

    /// `uname(2)` `release` field (fixed 256-byte C array → bytes to NUL).
    private static var darwinKernelRelease: String? {
        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else { return nil }
        return withUnsafeBytes(of: systemInfo.release) { raw in
            let bytes = raw.prefix(while: { $0 != 0 })
            return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
        }
    }

    private static func currentMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private static func randomHex32() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }
}

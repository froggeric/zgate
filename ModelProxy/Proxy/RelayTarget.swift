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
/// - A relay 429 retries once after a backoff; a second 429 is handed to the
///   caller for next-rule fallback / 529.
enum RelayTarget {

    // Identity constants pinned from the official zcode CLI 0.17.1 face
    // (Task 1 capture, corrected to the CLI wire order/UA in Task 2).
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
    private static let glmCanon: [String: String] = Dictionary(
        uniqueKeysWithValues: glmFamily.map { ($0.lowercased(), $0) })

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
        /// Relay answered 429 again after the backoff retry — the caller
        /// tries the rule's backup target, or answers 529.
        case rateLimitedAfterRetry
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
        /// Relay 429 backoff before the single retry (tests shorten it).
        var rateLimitBackoff: TimeInterval = RelayTarget.defaultRateLimitBackoff
        /// True once a signing chain has been established in this process —
        /// the only state from which the unsigned fail-open attempt may run.
        private(set) var establishedSignedSession = false

        init(
            signingClient: SigningClient,
            credentialEvents: CredentialEventChannel? = nil,
            quota: (any QuotaRelayCounting)? = nil,
            endpointConfig: (any EndpointResolving)? = nil
        ) {
            self.signingClient = signingClient
            self.credentialEvents = credentialEvents
            self.quota = quota
            self.endpointConfig = endpointConfig
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
            switch Int(response.status.code) {
            case 200..<300:
                await context.signingClient.noteRelaySuccess()
                return .responded(response)
            case 401:
                return await handleReject(
                    response: response, session: session, head: head, identity: identity,
                    wireBody: wireBody, target: target,
                    httpClient: httpClient, context: context, requestID: requestID)
            case 429:
                return await handleRateLimited(
                    response: response, head: head, identity: identity, wireBody: wireBody, target: target,
                    httpClient: httpClient, session: session, signed: true,
                    context: context, requestID: requestID)
            default:
                return .responded(response)
            }
        } catch let error as RelayTargetError {
            let reason = String(describing: error)
            AppLog.proxy.error("[Proxy] [\(requestID)] Relay signing material unavailable: \(reason)")
            return .signingUnavailable(reason)
        } catch {
            AppLog.proxy.error("[Proxy] [\(requestID)] Relay upstream error: \(error)")
            return .transportFailed(String(describing: error))
        }
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
        let (message, rewrapped) = await drainErrorBody(response)

        guard phase == .needsRehandshake else {
            // First reject: tolerated (controller ruling — two consecutive
            // rejects trigger the rebuild). Pass through, surfacing an
            // explicit expiry signal if the relay named one.
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
                await context.signingClient.noteRelaySuccess()
                return .responded(retry)
            case 401:
                await context.signingClient.noteRelayRejection()
                let (retryMessage, retryRewrapped) = await drainErrorBody(retry)
                let reason = retryMessage ?? message ?? "relay 401 after chain rebuild"
                context.credentialEvents?.emit(.expired(reason: reason))
                _ = retryRewrapped  // terminal: the 502 body is proxy-authored
                return .credentialsExpired(reason)
            case 429:
                return await handleRateLimited(
                    response: retry, head: head, identity: identity, wireBody: wireBody, target: target,
                    httpClient: httpClient, session: fresh, signed: true,
                    context: context, requestID: requestID)
            default:
                return .responded(retry)
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

    /// A relay 429: one backoff retry on the same target; a second 429 moves
    /// the decision to the caller (next-rule fallback or 529).
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
        AppLog.proxy.info("[Proxy] [\(requestID)] Relay 429 — one retry after backoff")
        let backoffNanos = UInt64(max(0, context.rateLimitBackoff) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: backoffNanos)
        do {
            let retry = try await sendOnce(
                head: head, identity: identity, wireBody: wireBody, target: target, httpClient: httpClient,
                session: session, signed: signed, context: context, requestID: requestID)
            switch Int(retry.status.code) {
            case 200..<300:
                await context.signingClient.noteRelaySuccess(signed: signed)
                return .responded(retry)
            case 401:
                return await handleReject(
                    response: retry, session: session, head: head, identity: identity,
                    wireBody: wireBody, target: target,
                    httpClient: httpClient, context: context, requestID: requestID)
            case 429:
                return .rateLimitedAfterRetry
            default:
                return .responded(retry)
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
                // Served, but UNSIGNED — mark the degraded face (UI item 5).
                await context.signingClient.noteRelaySuccess(signed: false)
                return .responded(response)
            case 401:
                await context.signingClient.noteRelayRejection()
                let (message, _) = await drainErrorBody(response)
                let reason = message ?? previousMessage ?? "relay 401 (unsigned fail-open)"
                context.credentialEvents?.emit(.expired(reason: reason))
                return .credentialsExpired(reason)
            case 429:
                // Same rate-limit policy as the signed path: one backoff
                // retry (also unsigned), then the caller's decision.
                return await handleRateLimited(
                    response: response, head: head, identity: identity, wireBody: wireBody, target: target,
                    httpClient: httpClient, session: session, signed: false,
                    context: context, requestID: requestID)
            default:
                return .responded(response)
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
            zcodeAuthorization: zcodeAuthorization)
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
    static func relayHeaders(
        session: SigningSession,
        signed: Bool,
        identity: SessionIdentity,
        zcodeAuthorization: String? = nil
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
    /// GLM name, byte-preserving splice) — everything else stays byte-unchanged.
    static func wireBody(bodyData: Data, target: RoutingSnapshot.RouteTarget) -> Data {
        guard let sourceModel = target.targetModel ?? bodyModelField(bodyData) else {
            return bodyData  // no model field: forward as-is (zbridge parity)
        }
        return ProxyForwarder.replaceModelField(
            in: bodyData, with: canonicalModel(sourceModel)).data
    }

    /// Top-level `"model"` field of a request body (nil when unparseable).
    static func bodyModelField(_ bodyData: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
            let model = json["model"] as? String, !model.isEmpty
        else { return nil }
        return model
    }

    /// zbridge `mapModel`: the GLM-canonical wire name for a rule target.
    /// Flash check first (matches `GLM-5.3-Flash` ahead of the 5.3 rule),
    /// unknown glm-family names map to the main model, unknown names to flash.
    static func canonicalModel(_ model: String) -> String {
        let lowered = model.trimmingCharacters(in: .whitespaces).lowercased()
        if lowered.contains("flash") { return "GLM-5.3-Flash" }
        if lowered.contains("glm-5.3") { return "GLM-5.3" }  // glm-5.3 and glm-5.3[1m]
        if let canon = glmCanon[lowered] { return canon }
        if lowered.hasPrefix("glm-") { return "GLM-5.3" }
        return "GLM-5.3-Flash"  // unknown names → flash (cheap default)
    }

    // MARK: - Error bodies

    /// Reads an error response body (bounded to 8 KiB), extracts the relay's
    /// error message (`error.message` / `message`), and returns a re-wrapped
    /// response carrying the same bytes so a passthrough can still stream it.
    static func drainErrorBody(_ response: HTTPClientResponse) async
        -> (message: String?, rewrapped: HTTPClientResponse)
    {
        var data = Data()
        do {
            for try await chunk in response.body {
                if let bytes = chunk.getData(at: chunk.readerIndex, length: chunk.readableBytes) {
                    data.append(bytes)
                }
                if data.count > 8192 { break }
            }
        } catch {
            // Body read failure on an error path: forward what we have.
        }
        var message: String?
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            message = (json["error"] as? [String: Any])?["message"] as? String
                ?? json["message"] as? String
        }
        var rewrapped = HTTPClientResponse(
            version: response.version, status: response.status, headers: response.headers)
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        rewrapped.body = .bytes(buffer)
        return (message, rewrapped)
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

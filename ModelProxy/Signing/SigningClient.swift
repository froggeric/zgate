import CryptoKit
import Foundation

/// Typed failures of the signing auth chain. Carries status codes, business
/// codes, and structural reasons only — never a token, JWT, or key byte.
enum SigningClientError: Error, Equatable, LocalizedError {
    /// The chain cannot proceed without a human re-login; Task 5 surfaces
    /// this as the re-login alert (the `CredentialError.expired`-style case).
    case reloginRequired(ReloginReason)
    /// No usable org/project/apiKeyId location (cache empty, none injected,
    /// store yielded none) — checked before any network call.
    case noLocation
    /// `z/login` transport-level failure (non-200 HTTP status).
    case loginFailed(status: Int, code: Int?)
    /// Mint failure other than an auth reject of a cached biz session.
    case mintFailed(status: Int, code: Int?)
    /// Handshake transport or business failure (`code != 200` / no cipher).
    case handshakeFailed(status: Int, code: Int?)
    /// A response decoded but lacked the fields the protocol requires.
    case malformedResponse(stage: Stage, reason: String)
    /// `privateCipher` failed to unseal (wrong key, AAD, or layout).
    case unsealFailed(reason: String)

    enum ReloginReason: Equatable {
        /// No credential store was configured.
        case storeUnavailable
        /// The store's `oauth:zai:access_token` `exp` has passed (checked
        /// before any network call).
        case storeAccessTokenExpired
        /// `z/login` answered HTTP 200 with a business rejection — the
        /// observed live behavior for a dead store token.
        case zLoginRejected
    }

    enum Stage: String { case login, mint, handshake }

    var errorDescription: String? {
        switch self {
        case .reloginRequired:
            "zcode credentials need an interactive re-login."
        case .noLocation:
            "No org/project/apiKeyId location available for the mint call."
        case let .loginFailed(status, code):
            "z/login failed (HTTP \(status), code \(code.map(String.init) ?? "none"))."
        case let .mintFailed(status, code):
            "Project-token mint failed (HTTP \(status), code \(code.map(String.init) ?? "none"))."
        case let .handshakeFailed(status, code):
            "Signing handshake failed (HTTP \(status), code \(code.map(String.init) ?? "none"))."
        case let .malformedResponse(stage, reason):
            "\(stage.rawValue) response malformed: \(reason)."
        case let .unsealFailed(reason):
            "Handshake signing key could not be unsealed: \(reason)."
        }
    }
}

/// One complete signed-chain result: the minted project token (relay
/// `authorization`/`x-api-key` source), its apiKeyId, and the handshake-
/// unsealed Ed25519 key Task 5 signs relay requests with.
struct SigningSession {
    let projectToken: String
    let apiKeyId: String
    let privateKey: Curve25519.Signing.PrivateKey
    /// Server-anchored expiry (`expiresIn`/`expiresAt`/JWT `exp`, earliest).
    let expiresAtMs: Int64
    /// True when the mint landed in a window shorter than the refresh margin
    /// (server-anchored windows can return the same expiry second twice) —
    /// this session is then used until its true expiry instead of thrashing
    /// per-request re-mints.
    let marginRelaxed: Bool
}

/// Builds and refreshes the zcode signing chain (V4):
/// store → `z/login` → biz JWT → mint → project token → handshake → Ed25519 key.
///
/// Refresh ladder (live-verified 2026-11-15, per zbridge):
/// 1. proactive re-mint ~120 s before project-token expiry — on the **cached
///    biz session**, no `z/login`;
/// 2. a mint auth-reject of a cached session falls back to a transparent
///    `z/login` (store token) once, then retries the mint;
/// 3. an expired store token surfaces `reloginRequired(.storeAccessTokenExpired)`
///    for Task 5's re-login alert.
///
/// The biz session (JWT + acquiredAt + location) is persisted (0600) and
/// survives restarts. Never logs: credential bytes never become strings.
actor SigningClient {

    enum Phase: Equatable, Sendable {
        case unsigned
        case handshaking
        case signed
        /// Two consecutive relay 401 rejects — the next `ensureSession` rebuilds.
        case needsRehandshake
    }

    /// One chain step's externally observable telemetry (lengths, never values).
    struct ChainEvent: Equatable, Sendable {
        let stage: SigningClientError.Stage
        let status: Int
        let ms: Int64
        let outcomeTokenLength: Int?
    }

    struct Configuration {
        var origin = "https://api.z.ai"
        var session: URLSession = .shared
        /// Store-as-loader (item 3, report §C.3): consulted per attempt, so
        /// a fresh external login (GUI/CLI re-login rewriting the shared
        /// store) is picked up by a RUNNING process on the next chain
        /// rebuild — no relaunch. The default re-runs the default load;
        /// a failed load reads as "no store" for that attempt.
        var storeLoader: @Sendable () throws -> CredentialStore? = {
            try CredentialStore.loadDefault()
        }
        /// Mint location until a cached biz session or the store's
        /// project-key-location entry supplies one. The mint cannot run
        /// without a location.
        var initialLocation: MintLocation?
        var cacheURL = BizSessionCache.defaultFileURL()
        /// Proactive refresh this far before project-token expiry.
        var refreshMargin: TimeInterval = 120
        /// After any mint, the next unforced mint waits until the window ends
        /// plus this delay — bounds re-mints when server-anchored windows
        /// return expiries no later than the previous one.
        var mintThrottle: TimeInterval = 5
        /// Mint body `clientVersion` — the bundle's pinned default, not the
        /// app version (docs/signing-notes.md).
        var mintClientVersion = "0.0.0-dev"
        var requestTimeout: TimeInterval = 15
        var now: @Sendable () -> Date = { Date() }

        init() {}
    }

    private var configuration: Configuration
    private let cache: BizSessionCache

    private var session: SigningSession?
    private var phase: Phase = .unsigned
    private var consecutiveRelayRejects = 0
    /// True while the most recent served relay exchange was the UNSIGNED
    /// fail-open attempt — read by `statusSnapshot()` for the status
    /// model's `degraded` face (login-flow UI item 5).
    private var servedUnsigned = false
    private var throttleUntilMs: Int64 = 0
    private var inFlight: Task<SigningSession, Error>?
    private var chainEvents: [ChainEvent] = []

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.cache = BizSessionCache(fileURL: configuration.cacheURL)
    }

    // MARK: - Public surface

    func currentPhase() -> Phase { phase }

    /// The current signing session's apiKeyId (nil while no session is
    /// established) — feeds the `x-api-key-id` header of the
    /// `agent/configs` endpoint fetch ("when available").
    func currentApiKeyId() -> String? { session?.apiKeyId }

    /// The events of the most recent chain build (lengths only, no values).
    func lastChainEvents() -> [ChainEvent] { chainEvents }

    /// Read-only ladder snapshot for status UI (item 6): phases,
    /// timestamps, and booleans only — no token material anywhere in the
    /// type.
    struct StatusSnapshot: Equatable, Sendable {
        let phase: Phase
        let nowMs: Int64
        /// Held project-token expiry, when a session exists.
        let sessionExpiresAtMs: Int64?
        /// True when the held session rides a short server-anchored window
        /// to its true expiry (renewal scheduling differs).
        let sessionMarginRelaxed: Bool
        /// `exp` of the store access token when a store loads, else nil.
        let storeAccessTokenExpiresAtMs: Int64?
        /// True when a store loads but carries no `project-key-location`
        /// entry — the ladder can never mint until a GUI/CLI login
        /// populates it (the fresh-install setup gap). False when no
        /// store loads at all (viability is a separate field).
        let storeLacksProjectLocation: Bool
        /// acquiredAt of the on-disk biz-session cache when present.
        let cacheAcquiredAtMs: Int64?
        /// True when the most recent served relay exchange went out
        /// UNSIGNED (RelayTarget's fail-open attempt) — the status model's
        /// `degraded` face (login-flow UI item 5). Clears on the next
        /// signed success.
        let servedUnsigned: Bool
    }

    /// Ladder state for the status row (item 6): phase, session expiry,
    /// store-token exp when a store loads, cache acquiredAt — enough for
    /// the UI task to render faces without touching token material.
    func statusSnapshot() -> StatusSnapshot {
        let store = loadStore()
        let storeTokenExpiryMs: Int64? = store
            .flatMap { try? $0.accessTokenExpiry() }
            .map { Int64($0.timeIntervalSince1970 * 1000) }
        return StatusSnapshot(
            phase: phase,
            nowMs: currentMs(),
            sessionExpiresAtMs: session?.expiresAtMs,
            sessionMarginRelaxed: session?.marginRelaxed ?? false,
            storeAccessTokenExpiresAtMs: storeTokenExpiryMs,
            storeLacksProjectLocation: store
                .map { (try? $0.projectKeyLocation()) == nil } ?? false,
            cacheAcquiredAtMs: cache.load()?.acquiredAtMs,
            servedUnsigned: servedUnsigned)
    }

    /// The biz JWT for the unsigned `api/biz` family — relay fidelity
    /// Task 7's fallback-edge mint chain (`ApiKeyMinter`). Served from the
    /// on-disk biz-session cache when usable (zero network); otherwise one
    /// chain build runs the full existing ladder (cache → store z/login →
    /// mint-validated) and the refreshed cache is re-read. The JWT value
    /// never appears in logs or errors.
    func currentBizJWT() async throws -> String {
        let nowMs = currentMs()
        if let cached = cache.load(), cached.isUsable(nowMs: nowMs) {
            return cached.bizJwt
        }
        _ = try await ensureSession()
        if let refreshed = cache.load(), refreshed.isUsable(nowMs: currentMs()) {
            return refreshed.bizJwt
        }
        throw SigningClientError.malformedResponse(
            stage: .mint, reason: "biz session unavailable after chain build")
    }

    /// Returns a valid signing session, building or refreshing as needed.
    ///
    /// - Valid session → returned directly (until `refreshMargin` before
    ///   expiry; a margin-relaxed session until its true expiry).
    /// - `force` (relay-401 rebuild) bypasses validity and throttle checks.
    /// - Concurrent callers share one in-flight build.
    func ensureSession(force: Bool = false) async throws -> SigningSession {
        let nowMs = currentMs()
        if !force, phase != .needsRehandshake, let session {
            let marginMs = Int64(configuration.refreshMargin * 1000)
            if session.marginRelaxed {
                // Short server-anchored window: ride it to its true expiry
                // (a refresh at expiry-margin would fire immediately).
                if nowMs < session.expiresAtMs { return session }
            } else if nowMs < session.expiresAtMs - marginMs {
                return session  // healthy — proactive refresh happens inside the margin
            }
            // Past expiry but the mint is throttled (bounded backoff after a
            // short window): hand back the best available token; Task 5's
            // reject ladder force-rebuilds on relay 401s.
            if nowMs >= session.expiresAtMs, nowMs < throttleUntilMs { return session }
        }
        if let inFlight { return try await inFlight.value }

        let build = Task { try await self.buildChain() }
        inFlight = build
        defer { inFlight = nil }
        return try await build.value
    }

    /// Relay headers carrying the minted project token — both from the same
    /// source (Task 1: `authorization` = "Bearer " + token, `x-api-key` = raw).
    func relayAuthHeaders() async throws -> [String: String] {
        let session = try await ensureSession()
        return [
            "authorization": "Bearer \(session.projectToken)",
            "x-api-key": session.projectToken,
        ]
    }

    /// Task 5 calls this on a relay 401. Two consecutive rejects move the
    /// client to `needsRehandshake` (the next `ensureSession` rebuilds).
    func noteRelayRejection() {
        consecutiveRelayRejects += 1
        if consecutiveRelayRejects >= 2 { phase = .needsRehandshake }
    }

    /// Task 5 calls this on a relay success — resets the consecutive count.
    /// `signed: false` marks the success as the UNSIGNED fail-open attempt
    /// (RelayTarget): the status model then shows `degraded` until the
    /// next signed success resets the flag.
    func noteRelaySuccess(signed: Bool = true) {
        consecutiveRelayRejects = 0
        servedUnsigned = !signed
    }

    /// Hot pickup (item 3, report §C.3): forget the held session so the
    /// next `ensureSession` rebuilds the chain, consulting the store
    /// loader fresh. No relayContext/SigningClient re-creation and the
    /// per-process sessionID is untouched. The biz-session cache
    /// survives — a still-valid 180 d JWT is reused, a dead one is
    /// invalidated by the mint auth-reject path below.
    func dropSession() {
        session = nil
        phase = .unsigned
        consecutiveRelayRejects = 0
    }

    // MARK: - Chain build

    private func buildChain() async throws -> SigningSession {
        phase = .handshaking
        chainEvents = []
        defer {
            if phase == .handshaking { phase = .unsigned }
        }

        let nowMs = currentMs()
        let cache = self.cache

        // 1. Biz credentials: cached session first — no z/login. Fallback to
        //    the store → z/login only when the cache is unusable.
        var bizJwt: String
        var acquiredAtMs = nowMs
        var location = configuration.initialLocation
        var cameFromCache = false

        if let cached = cache.load(), cached.isUsable(nowMs: nowMs) {
            bizJwt = cached.bizJwt
            acquiredAtMs = cached.acquiredAtMs
            location = cached.location ?? location
            cameFromCache = true
        } else {
            // Cold start: the store's project-key-location entry is the last
            // location source. Resolve it BEFORE z/login — without a location
            // the chain can only end in noLocation, so the login would be
            // wasted network. A malformed store value falls through to nil
            // (mirrors zbridge's readLocation).
            if location == nil, let store = loadStore(),
                let stored = try? await store.projectKeyLocation()
            {
                location = MintLocation(
                    organizationId: stored.organizationId,
                    projectId: stored.projectId,
                    apiKeyId: stored.apiKeyId)
            }
            guard let location else { throw SigningClientError.noLocation }
            bizJwt = try await loginViaStore()
        }
        // Cache path: a usable cached session may still carry no location
        // (zbridge-era or hand-edited cache). The store's project-key-location
        // entry fills the gap — without this lookup a location-less cache
        // would 502 every relay request for the cache's remaining lifetime
        // even though the store could supply the triple.
        if location == nil, let store = loadStore(),
            let stored = try? await store.projectKeyLocation()
        {
            location = MintLocation(
                organizationId: stored.organizationId,
                projectId: stored.projectId,
                apiKeyId: stored.apiKeyId)
        }
        guard let location else { throw SigningClientError.noLocation }

        // 2. Mint the project token. A cached session's auth-reject triggers
        //    the transparent z/login fallback once; a freshly-logged-in JWT
        //    that is rejected is a plain mint failure.
        var minted: (token: String, expiresAtMs: Int64)
        do {
            minted = try await mintProjectToken(bizJwt: bizJwt, location: location)
        } catch let error as SigningClientError {
            guard cameFromCache, case let .mintFailed(status, code) = error,
                Self.isAuthReject(status: status, code: code), loadStore() != nil
            else { throw error }
            // The cached biz JWT is dead server-side even though it is
            // client-"usable": remove the cache so later builds start at
            // z/login instead of retrying the dead JWT first (§A.5 loop).
            cache.invalidate()
            bizJwt = try await loginViaStore()
            acquiredAtMs = currentMs()
            minted = try await mintProjectToken(bizJwt: bizJwt, location: location)
        }

        // 3. The signer's apiKeyId is the minted token's own `api_key` claim;
        //    the location's id is the fallback.
        let apiKeyId = Self.jwtStringClaim(minted.token, claim: "api_key") ?? location.apiKeyId

        // 4. Handshake → privateCipher → Ed25519 key.
        let cipher = try await handshake(projectToken: minted.token, apiKeyId: apiKeyId)
        let privateKey = try Self.unsealPrivateKey(
            cipherB64: cipher, projectToken: minted.token, apiKeyId: apiKeyId)

        // 5. Persist the biz session (best-effort; keep the cache's acquiredAt
        //    when it is still the live session). 0600, never logged.
        let result = SigningSession(
            projectToken: minted.token,
            apiKeyId: apiKeyId,
            privateKey: privateKey,
            expiresAtMs: minted.expiresAtMs,
            marginRelaxed: minted.expiresAtMs - nowMs < Int64(configuration.refreshMargin * 1000))
        try? cache.save(BizSession(bizJwt: bizJwt, acquiredAtMs: acquiredAtMs, location: location))

        session = result
        phase = .signed
        consecutiveRelayRejects = 0
        throttleUntilMs = max(currentMs(), minted.expiresAtMs) + Int64(configuration.mintThrottle * 1000)
        return result
    }

    /// Store access token → `POST /api/auth/z/login` → biz JWT. Checks the
    /// store token's `exp` first (expired → re-login alert, zero network).
    /// The store comes from the configured loader — a fresh external login
    /// on disk is seen here on the very next attempt (hot pickup).
    private func loginViaStore() async throws -> String {
        guard let store = loadStore() else {
            throw SigningClientError.reloginRequired(.storeUnavailable)
        }
        let accessToken = try await store.accessToken()
        if let expiry = try await store.accessTokenExpiry(), expiry <= configuration.now() {
            throw SigningClientError.reloginRequired(.storeAccessTokenExpired)
        }

        let startMs = currentMs()
        let body = try JSONSerialization.data(withJSONObject: ["token": accessToken])
        let (status, json, code) = try await post(
            path: "/api/auth/z/login", authorization: nil, body: body, stage: .login)
        let data = (json?["data"] as? [String: Any]) ?? [:]
        let bizJwt = ((data["access_token"] as? String) ?? (data["accessToken"] as? String))?
            .trimmingCharacters(in: .whitespaces) ?? ""
        chainEvents.append(.init(
            stage: .login, status: status, ms: currentMs() - startMs,
            outcomeTokenLength: bizJwt.isEmpty ? nil : bizJwt.count))

        // HTTP 200 + business rejection is the live-observed shape of a dead
        // store token (Task 1: code 500, `project_token_login_failed`).
        guard status == 200, Self.isBusinessSuccess(code), bizJwt.count > 100 else {
            if status == 200 {
                throw SigningClientError.reloginRequired(.zLoginRejected)
            }
            throw SigningClientError.loginFailed(status: status, code: code)
        }
        return bizJwt
    }

    /// `POST /api/biz/v1/organization/<org>/projects/<proj>/api_keys/<id>/access_tokens`
    /// (Bearer biz JWT, body pinned to the bundle's 50-byte form).
    private func mintProjectToken(bizJwt: String, location: MintLocation) async throws
        -> (token: String, expiresAtMs: Int64)
    {
        let startMs = currentMs()
        let path = "/api/biz/v1/organization/\(location.organizationId)"
            + "/projects/\(location.projectId)"
            + "/api_keys/\(location.apiKeyId)/access_tokens"
        let body = Data("{\"clientType\":\"zcode\",\"clientVersion\":\"\(configuration.mintClientVersion)\"}".utf8)
        let (status, json, code) = try await post(
            path: path, authorization: "Bearer \(bizJwt)", body: body, stage: .mint)
        let data = (json?["data"] as? [String: Any]) ?? [:]
        let token = ((data["accessToken"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        chainEvents.append(.init(
            stage: .mint, status: status, ms: currentMs() - startMs,
            outcomeTokenLength: token.isEmpty ? nil : token.count))

        let enabled = (data["enable"] as? Bool) ?? true
        guard status == 200, enabled, !token.isEmpty else {
            throw SigningClientError.mintFailed(status: status, code: code)
        }

        // Server-anchored window: earliest of expiresIn/expiresAt (seconds)
        // and the token's own JWT exp; fall back to a 5-minute assumption.
        var candidates: [Int64] = []
        if let expiresIn = data["expiresIn"] as? Double { candidates.append(startMs + Int64(expiresIn * 1000)) }
        if let expiresAt = data["expiresAt"] as? Double {
            candidates.append(Int64((expiresAt > 1e12 ? expiresAt / 1000 : expiresAt) * 1000))
        }
        if let exp = Self.jwtNumberClaim(token, claim: "exp") {
            candidates.append(Int64((exp > 1e12 ? exp / 1000 : exp) * 1000))
        }
        let expiresAtMs = candidates.min() ?? startMs + 300_000
        return (token, expiresAtMs)
    }

    /// `POST /api/paas/c1f3a7e2/v2/client` — raw token auth (no Bearer),
    /// HMAC sig over `CryptoCore.handshakeSigMessage`. Returns `privateCipher`.
    private func handshake(projectToken: String, apiKeyId: String) async throws -> String {
        let startMs = currentMs()
        let nonce = Self.randomHex(byteCount: 16)
        let ts = String(currentMs())
        let sigKey = CryptoCore.hkdf(
            ikm: Data(projectToken.utf8),
            salt: Data(CryptoCore.kdfSalt.utf8),
            info: Data(CryptoCore.hmacInfo.utf8),
            length: 32)
        let sig = CryptoCore.hmacBase64(
            message: CryptoCore.handshakeSigMessage(apiKeyId: apiKeyId, ts: ts, nonce: nonce),
            key: sigKey)
        let body = try JSONSerialization.data(
            withJSONObject: ["accessToken": projectToken, "nonce": nonce, "sig": sig, "ts": ts])
        let (status, json, code) = try await post(
            path: "/api/paas/c1f3a7e2/v2/client", authorization: projectToken, body: body, stage: .handshake)
        let cipher = ((json?["data"] as? [String: Any])?["privateCipher"] as? String) ?? ""
        chainEvents.append(.init(
            stage: .handshake, status: status, ms: currentMs() - startMs,
            outcomeTokenLength: cipher.isEmpty ? nil : cipher.count))

        guard status == 200, code == 200, !cipher.isEmpty else {
            throw SigningClientError.handshakeFailed(status: status, code: code)
        }
        return cipher
    }

    // MARK: - Unseal

    /// `privateCipher` = b64std(iv12‖ct‖tag16), AES-256-GCM, AAD = apiKeyId,
    /// key = HKDF(project token, info "ed25519_priv"); the plaintext is a
    /// base64 string of DER-PKCS8 Ed25519 (double-encoded).
    static func unsealPrivateKey(
        cipherB64: String, projectToken: String, apiKeyId: String
    ) throws -> Curve25519.Signing.PrivateKey {
        guard let blob = Data(base64Encoded: cipherB64), blob.count > 12 + 16 else {
            throw SigningClientError.unsealFailed(reason: "cipher is not standard base64 of iv‖ct‖tag")
        }
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: blob.prefix(12)),
                ciphertext: blob.dropFirst(12).dropLast(16),
                tag: blob.suffix(16))
        } catch {
            throw SigningClientError.unsealFailed(reason: "cipher split into iv/ct/tag failed")
        }
        let key = SymmetricKey(data: CryptoCore.hkdf(
            ikm: Data(projectToken.utf8),
            salt: Data(CryptoCore.kdfSalt.utf8),
            info: Data(CryptoCore.ed25519Info.utf8),
            length: 32))
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(sealedBox, using: key, authenticating: Data(apiKeyId.utf8))
        } catch {
            throw SigningClientError.unsealFailed(reason: "AES-GCM open failed (key/AAD mismatch or tamper)")
        }
        guard let plaintextString = String(data: plaintext, encoding: .utf8),
            let pkcs8 = Data(base64Encoded: plaintextString)
        else {
            throw SigningClientError.unsealFailed(reason: "plaintext is not base64 of DER-PKCS8")
        }
        // DER-PKCS8 Ed25519: 302e020100300506032b657004220420 ‖ 32-byte seed.
        let pkcs8Ed25519Prefix: [UInt8] = [
            0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b,
            0x65, 0x70, 0x04, 0x22, 0x04, 0x20]
        guard pkcs8.count == 48, Array(pkcs8.prefix(16)) == pkcs8Ed25519Prefix else {
            throw SigningClientError.unsealFailed(reason: "decrypted DER is not a 48-byte PKCS8 Ed25519 key")
        }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: pkcs8.suffix(32))
    }

    // MARK: - HTTP

    private func post(path: String, authorization: String?, body: Data, stage: SigningClientError.Stage) async throws
        -> (status: Int, json: [String: Any]?, code: Int?)
    {
        guard let url = URL(string: configuration.origin + path) else {
            throw SigningClientError.malformedResponse(stage: stage, reason: "path does not form a URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        request.httpBody = body
        let (data, response) = try await configuration.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = Self.numberField(json?["code"]).map(Int.init)
        return (status, json, code)
    }

    // MARK: - Private helpers

    /// Consults the configured store loader. A load failure (absent,
    /// unreadable, fingerprint mismatch) reads as "no store" for this
    /// attempt; the next attempt re-runs the loader.
    private func loadStore() -> CredentialStore? {
        do { return try configuration.storeLoader() } catch { return nil }
    }

    private func currentMs() -> Int64 {
        Int64(configuration.now().timeIntervalSince1970 * 1000)
    }

    private static func isAuthReject(status: Int, code: Int?) -> Bool {
        status == 401 || code == 401
    }

    private static func isBusinessSuccess(_ code: Int?) -> Bool {
        code == nil || code == 0 || code == 200
    }

    private static func numberField(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func randomHex(byteCount: Int) -> String {
        (0..<byteCount).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }

    /// String claim from a compact JWT payload segment, or nil (missing,
    /// not a 3-part token, payload not JSON — all tolerated).
    private static func jwtStringClaim(_ token: String, claim: String) -> String? {
        jwtPayloadClaim(token)?[claim] as? String
    }

    private static func jwtNumberClaim(_ token: String, claim: String) -> Double? {
        numberField(jwtPayloadClaim(token)?[claim])
    }

    private static func jwtPayloadClaim(_ token: String) -> [String: Any]? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard segments.count == 3, let payload = Base64URL.decode(segments[1]) else { return nil }
        return (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
    }
}

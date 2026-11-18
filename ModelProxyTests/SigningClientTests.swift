import CryptoKit
import Foundation
import Testing
@testable import ZGate

/// Offline tests for `SigningClient` — the auth chain and refresh ladder,
/// driven entirely through a `URLProtocol` mock with synthetic fixtures
/// (synthetic JWTs, a synthetic Ed25519 seed, and a sealed key produced by
/// the same HKDF/AES-GCM scheme in-test). No real credential ever loads.
@Suite(.serialized)
struct SigningClientTests {

    // MARK: - Fixtures

    /// Base clock instant: exactly 3600 s before the synthetic store's
    /// access-token `exp` (1763003600), mirroring the real 1 h TTL.
    private static let baseDate = Date(timeIntervalSince1970: 1_763_000_000)
    private static var baseMs: Int64 { 1_763_000_000_000 }

    private enum ChainFixtures {
        static let apiKeyId = "b5f4e6998889200000000000000088920"
        static let location = MintLocation(
            organizationId: "11111111-1111-1111-1111-111111111111",
            projectId: "22222222-2222-2222-2222-222222222222",
            apiKeyId: apiKeyId)
        /// Fixed 32-byte seed so unseal results are comparable byte-for-byte.
        static let ed25519Seed = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })

        static func fakeJWT(payload: [String: Any]) -> String {
            let header = Base64URL.encode(Data(#"{"alg":"HS256","typ":"JWT"}"#.utf8))
            let body = Base64URL.encode(try! JSONSerialization.data(withJSONObject: payload))
            return [header, body, "c2lnbmF0dXJl"].joined(separator: ".")
        }

        /// 1402-char-scale synthetic biz JWT (> 100 chars, like the real one).
        static func bizJwt(tag: String = "biz") -> String {
            fakeJWT(payload: ["sub": String(repeating: tag, count: 40), "role": "session"])
        }

        /// Minted project token; `api_keyClaim` nil models a token without one.
        static func projectToken(apiKeyClaim: String?) -> String {
            var payload: [String: Any] = ["token_use": "project_access"]
            if let apiKeyClaim { payload["api_key"] = apiKeyClaim }
            return fakeJWT(payload: payload)
        }

        /// Seals the fixed Ed25519 seed exactly like the server does:
        /// AES-256-GCM (AAD = apiKeyId, key = HKDF(token, "ed25519_priv"))
        /// over the base64 string of DER-PKCS8, returned as b64std(iv‖ct‖tag).
        static func sealPrivateKey(projectToken: String, apiKeyId: String) throws -> String {
            let key = SymmetricKey(data: CryptoCore.hkdf(
                ikm: Data(projectToken.utf8),
                salt: Data(CryptoCore.kdfSalt.utf8),
                info: Data(CryptoCore.ed25519Info.utf8),
                length: 32))
            let pkcs8Prefix: [UInt8] = [
                0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b,
                0x65, 0x70, 0x04, 0x22, 0x04, 0x20]
            let plaintext = Data((Data(pkcs8Prefix) + ed25519Seed).base64EncodedString().utf8)
            let sealed = try AES.GCM.seal(
                plaintext, using: key,
                nonce: AES.GCM.Nonce(data: Data((0..<12).map { UInt8($0) })),
                authenticating: Data(apiKeyId.utf8))
            guard let combined = sealed.combined else {
                throw SigningClientError.unsealFailed(reason: "fixture seal produced no combined box")
            }
            return combined.base64EncodedString()
        }
    }

    // MARK: - Mock plumbing

    /// Lock-guarded mutable clock injected as `Configuration.now`.
    private final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant: Date

        init(_ date: Date) { instant = date }

        var now: Date {
            lock.lock(); defer { lock.unlock() }
            return instant
        }

        var ms: Int64 { Int64(now.timeIntervalSince1970 * 1000) }

        func advance(_ seconds: TimeInterval) {
            lock.lock(); instant = instant.addingTimeInterval(seconds); lock.unlock()
        }
    }

    /// Records requests and serves the three chain endpoints with synthetic
    /// responses. Scenario knobs are plain vars (the suite is serialized).
    private final class SigningMock: @unchecked Sendable {
        struct RecordedRequest {
            let url: URL
            let method: String
            let headers: [String: String]
            let body: Data?

            var jsonBody: [String: Any]? {
                body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            }
        }

        private let lock = NSRecursiveLock()
        private var recorded: [RecordedRequest] = []
        private var mintedTokens: [String] = []

        var clock = ManualClock(SigningClientTests.baseDate)
        var location = ChainFixtures.location
        var bizJwtForLogin = ChainFixtures.bizJwt()
        /// Overrides the default z/login success (status, body object).
        var loginResponse: ((RecordedRequest) throws -> (Int, [String: Any]))?
        /// Overrides the default mint success (status, body object).
        var mintResponse: ((RecordedRequest, Int64) throws -> (Int, [String: Any]))?
        /// Overrides the default handshake success (status, body object).
        var handshakeResponse: ((RecordedRequest) throws -> (Int, [String: Any]))?
        /// `api_key` claim inside minted tokens (nil = no claim).
        var mintedTokenAPIKeyClaim: String? = ChainFixtures.apiKeyId
        /// Default mint window length when no `windowEndForRequest` is set.
        var mintExpiresInMs: Int64 = 10_800_000
        /// Server-anchored window: maps request-time ms → absolute expiry ms.
        var windowEndForRequest: ((Int64) -> Int64)?

        var mintedTokenList: [String] {
            lock.lock(); defer { lock.unlock() }
            return mintedTokens
        }

        /// For overrides that mint manually: keep the token visible to the
        /// default handshake seal.
        func recordMintedToken(_ token: String) {
            lock.lock(); mintedTokens.append(token); lock.unlock()
        }

        func requests(matching marker: String) -> [RecordedRequest] {
            lock.lock(); defer { lock.unlock() }
            return recorded.filter { $0.url.path.contains(marker) }
        }

        func count(matching marker: String) -> Int {
            requests(matching: marker).count
        }

        /// Entry point from the URLProtocol: route, record, respond.
        func respond(to request: URLRequest) throws -> (Int, Data) {
            let body = SigningURLProtocol.body(of: request)
            let recordedRequest = RecordedRequest(
                url: request.url ?? URL(fileURLWithPath: "/unknown"),
                method: request.httpMethod ?? "",
                headers: request.allHTTPHeaderFields ?? [:],
                body: body)
            lock.lock()
            recorded.append(recordedRequest)
            lock.unlock()

            let path = recordedRequest.url.path
            if path.contains("/api/auth/z/login") {
                if let loginResponse {
                    let (status, object) = try loginResponse(recordedRequest)
                    return (status, try JSONSerialization.data(withJSONObject: object))
                }
                return (200, try JSONSerialization.data(withJSONObject: [
                    "code": 200,
                    "data": ["access_token": bizJwtForLogin, "expires_in": 15_552_000],
                ]))
            }
            if path.contains("/access_tokens") {
                let nowMs = clock.ms
                if let mintResponse {
                    let (status, object) = try mintResponse(recordedRequest, nowMs)
                    return (status, try JSONSerialization.data(withJSONObject: object))
                }
                let token = ChainFixtures.projectToken(apiKeyClaim: mintedTokenAPIKeyClaim)
                lock.lock()
                mintedTokens.append(token)
                lock.unlock()
                let expiresInMillis = windowEndForRequest.map { $0(nowMs) - nowMs } ?? mintExpiresInMs
                return (200, try JSONSerialization.data(withJSONObject: [
                    "code": 200,
                    "data": [
                        "accessToken": token,
                        "tokenType": "Bearer",
                        "expiresIn": Double(expiresInMillis) / 1000,
                    ],
                ]))
            }
            if path.contains("/api/paas/c1f3a7e2/v2/client") {
                if let handshakeResponse {
                    let (status, object) = try handshakeResponse(recordedRequest)
                    return (status, try JSONSerialization.data(withJSONObject: object))
                }
                let token = mintedTokenList.last
                guard let token else { throw NSError(domain: "SigningMock", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "handshake before any mint"]) }
                let apiKeyId = mintedTokenAPIKeyClaim ?? location.apiKeyId
                let cipher = try ChainFixtures.sealPrivateKey(projectToken: token, apiKeyId: apiKeyId)
                return (200, try JSONSerialization.data(withJSONObject: [
                    "code": 200,
                    "msg": "get sign key",
                    "data": ["privateCipher": cipher],
                    "success": true,
                ]))
            }
            throw NSError(domain: "SigningMock", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "unexpected path \(path)"])
        }
    }

    /// `URLSession`-visible face of `SigningMock`.
    private final class SigningURLProtocol: URLProtocol {
        nonisolated(unsafe) static var mock: SigningMock?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let mock = Self.mock else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            do {
                let (status, body) = try mock.respond(to: request)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}

        /// `URLSession` moves `httpBody` into a stream — drain it for asserts.
        static func body(of request: URLRequest) -> Data? {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 4096
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: bufferSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        }
    }

    // MARK: - Helpers

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zgate-signingclient-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeConfiguration(
        clock: ManualClock,
        store: CredentialStore? = nil,
        location: MintLocation? = ChainFixtures.location,
        cacheDirectory: URL,
        refreshMargin: TimeInterval = 120,
        mintThrottle: TimeInterval = 5
    ) -> SigningClient.Configuration {
        var configuration = SigningClient.Configuration()
        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [SigningURLProtocol.self]
        configuration.session = URLSession(configuration: urlSessionConfiguration)
        configuration.store = store
        configuration.initialLocation = location
        configuration.cacheURL = cacheDirectory.appendingPathComponent("biz-session.cache")
        configuration.refreshMargin = refreshMargin
        configuration.mintThrottle = mintThrottle
        let capturedClock = clock
        configuration.now = { capturedClock.now }
        return configuration
    }

    private func installMock(_ mock: SigningMock) {
        SigningURLProtocol.mock = mock
    }

    private func seedCache(
        directory: URL,
        bizJwt: String = ChainFixtures.bizJwt(),
        acquiredAtMs: Int64 = SigningClientTests.baseMs - 1_000,
        location: MintLocation? = ChainFixtures.location
    ) throws {
        try BizSessionCache(fileURL: directory.appendingPathComponent("biz-session.cache"))
            .save(BizSession(bizJwt: bizJwt, acquiredAtMs: acquiredAtMs, location: location))
    }

    private func syntheticStore() throws -> CredentialStore {
        try CredentialStore(fixture: .synthetic)
    }

    /// The full synthetic chain: valid store → z/login → mint → handshake.
    private func makeBuiltClient(cacheDirectory: URL, mock: SigningMock) async throws -> SigningClient {
        let client = SigningClient(configuration: makeConfiguration(
            clock: mock.clock, store: try syntheticStore(), cacheDirectory: cacheDirectory))
        _ = try await client.ensureSession()
        return client
    }

    // MARK: - Handshake request shape (AC: wire form)

    @Test func handshakeRequestBodyMatchesLiveWireForm() async throws {
        let mock = SigningMock()
        installMock(mock)
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let client = try await makeBuiltClient(cacheDirectory: directory, mock: mock)
        let session = try await client.ensureSession()
        #expect(await client.currentPhase() == .signed)

        let handshakeRequest = try #require(mock.requests(matching: "/api/paas/c1f3a7e2/v2/client").first)
        let body = try #require(handshakeRequest.jsonBody)
        let nonce = try #require(body["nonce"] as? String)
        let ts = try #require(body["ts"] as? String)
        let sig = try #require(body["sig"] as? String)
        let accessToken = try #require(body["accessToken"] as? String)

        // nonce: 16 bytes hex; ts: 13-char ms epoch matching the injected clock.
        #expect(nonce.count == 32)
        #expect(nonce.allSatisfy { $0.isHexDigit })
        #expect(ts == String(mock.clock.ms))
        // accessToken: the minted project token; Authorization: raw token, no Bearer.
        #expect(accessToken == session.projectToken)
        #expect(handshakeRequest.headers["Authorization"] == session.projectToken)
        // sig: 44-char base64 HMAC over the CryptoCore message, same key schedule.
        #expect(sig.count == 44)
        let key = CryptoCore.hkdf(
            ikm: Data(session.projectToken.utf8),
            salt: Data(CryptoCore.kdfSalt.utf8),
            info: Data(CryptoCore.hmacInfo.utf8),
            length: 32)
        let expected = CryptoCore.hmacBase64(
            message: CryptoCore.handshakeSigMessage(apiKeyId: session.apiKeyId, ts: ts, nonce: nonce),
            key: key)
        #expect(sig == expected)
    }

    @Test func loginRequestCarriesStoreTokenWithoutAuthHeader() async throws {
        let mock = SigningMock()
        installMock(mock)
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try await makeBuiltClient(cacheDirectory: directory, mock: mock)

        let loginRequest = try #require(mock.requests(matching: "/api/auth/z/login").first)
        #expect(loginRequest.headers["Authorization"] == nil)
        let body = try #require(loginRequest.jsonBody)
        // Synthetic store value — safe to compare directly.
        let expectedToken = try syntheticStore().accessToken()
        #expect(body["token"] as? String == expectedToken)
    }

    // MARK: - Unseal (AC: HKDF ed25519_priv → Curve25519 key)

    @Test func unsealedKeyMatchesFixtureSeedAndSigns() async throws {
        let mock = SigningMock()
        installMock(mock)
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = try await SigningClient(configuration: makeConfiguration(
            clock: mock.clock, store: try syntheticStore(), cacheDirectory: directory))
            .ensureSession()

        #expect(Data(session.privateKey.rawRepresentation) == ChainFixtures.ed25519Seed)
        let message = Data("zgate-signingclient-test".utf8)
        let signature = try session.privateKey.signature(for: message)
        #expect(session.privateKey.publicKey.isValidSignature(signature, for: message))
    }

    @Test func unsealPrivateKeyRejectsWrongAADAndCipher() throws {
        let token = ChainFixtures.projectToken(apiKeyClaim: ChainFixtures.apiKeyId)
        let cipher = try ChainFixtures.sealPrivateKey(projectToken: token, apiKeyId: ChainFixtures.apiKeyId)

        func expectUnsealFailure(_ label: String, projectToken: String, apiKeyId: String, cipherB64: String) {
            do {
                _ = try SigningClient.unsealPrivateKey(
                    cipherB64: cipherB64, projectToken: projectToken, apiKeyId: apiKeyId)
                Issue.record("expected unsealFailed for \(label)")
            } catch let error as SigningClientError {
                guard case SigningClientError.unsealFailed = error else {
                    Issue.record("expected unsealFailed for \(label), got \(error)")
                    return
                }
            } catch {
                Issue.record("expected SigningClientError for \(label), got \(error)")
            }
        }

        expectUnsealFailure("AAD mismatch", projectToken: token, apiKeyId: "other-api-key-id", cipherB64: cipher)
        expectUnsealFailure("wrong key schedule", projectToken: "different-token", apiKeyId: ChainFixtures.apiKeyId, cipherB64: cipher)
        expectUnsealFailure("not base64", projectToken: token, apiKeyId: ChainFixtures.apiKeyId, cipherB64: "!!!!")
    }

    // MARK: - Relay auth headers (AC: source-of-value mapping)

    @Test func relayAuthHeadersMapProjectTokenToBothHeaders() async throws {
        let mock = SigningMock()
        installMock(mock)
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let client = try await makeBuiltClient(cacheDirectory: directory, mock: mock)
        let session = try await client.ensureSession()
        let headers = try await client.relayAuthHeaders()

        #expect(headers["authorization"] == "Bearer \(session.projectToken)")
        #expect(headers["x-api-key"] == session.projectToken)
        #expect(headers.count == 2)
    }

    // MARK: - Reject ladder (AC: two consecutive 401s → needsRehandshake)

    @Test func twoConsecutiveRejectsNeedRehandshakeThenRecover() async throws {
        let mock = SigningMock()
        installMock(mock)
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let client = try await makeBuiltClient(cacheDirectory: directory, mock: mock)
        #expect(await client.currentPhase() == .signed)

        await client.noteRelayRejection()
        #expect(await client.currentPhase() == .signed)  // first reject: tolerated
        await client.noteRelayRejection()
        #expect(await client.currentPhase() == .needsRehandshake)

        // needsRehandshake forces a rebuild even though the session is valid.
        _ = try await client.ensureSession()
        #expect(await client.currentPhase() == .signed)
        #expect(mock.count(matching: "/access_tokens") == 2)

        // An interleaved success resets the consecutive count.
        await client.noteRelaySuccess()
        await client.noteRelayRejection()
        #expect(await client.currentPhase() == .signed)
    }

    // MARK: - Refresh ladder: cached-biz renewal (AC: no z/login)

    @Test func cachedBizSessionRebuildSkipsLoginAndKeepsAcquiredAt() async throws {
        let mock = SigningMock()
        installMock(mock)
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // A usable persisted session older than the token window.
        try seedCache(directory: directory, acquiredAtMs: SigningClientTests.baseMs - 3_600_000)
        // A valid store is configured, so a z/login WOULD be possible — the
        // test pins that it does not happen.
        let client = SigningClient(configuration: makeConfiguration(
            clock: mock.clock, store: try syntheticStore(), cacheDirectory: directory))
        let session = try await client.ensureSession()

        #expect(await client.currentPhase() == .signed)
        #expect(mock.count(matching: "/api/auth/z/login") == 0)
        #expect(mock.count(matching: "/access_tokens") == 1)
        #expect(mock.count(matching: "/api/paas/c1f3a7e2/v2/client") == 1)
        // The chain succeeded against the cached biz JWT.
        #expect(session.projectToken == mock.mintedTokenList.first)
        // acquiredAt is preserved (the cached JWT is still the live session).
        let reloaded = try #require(BizSessionCache(
            fileURL: directory.appendingPathComponent("biz-session.cache")).load())
        #expect(reloaded.acquiredAtMs == SigningClientTests.baseMs - 3_600_000)
    }

    // MARK: - Refresh ladder: transparent z/login fallback (AC: it fires)

    @Test func mintAuthRejectWithCachedSessionFallsBackToLogin() async throws {
        let mock = SigningMock()
        installMock(mock)
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cachedJWT = ChainFixtures.bizJwt(tag: "cached")
        try seedCache(directory: directory, bizJwt: cachedJWT, acquiredAtMs: SigningClientTests.baseMs - 1_000)

        let freshJWT = ChainFixtures.bizJwt(tag: "fresh")
        var mintCallCount = 0
        mock.bizJwtForLogin = freshJWT
        let mockForHandlers = mock
        mock.mintResponse = { request, _ in
            mintCallCount += 1
            if mintCallCount == 1 {
                // The cached biz session is rejected by the server.
                return (401, ["code": 401])
            }
            // The retry must carry the freshly-logged-in biz JWT.
            guard request.headers["Authorization"] == "Bearer \(freshJWT)" else {
                throw NSError(domain: "SigningMock", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "retry mint did not use the fresh biz JWT"])
            }
            let token = ChainFixtures.projectToken(apiKeyClaim: ChainFixtures.apiKeyId)
            mockForHandlers.recordMintedToken(token)
            return (200, ["code": 200, "data": ["accessToken": token, "expiresIn": 10_800]])
        }

        let client = SigningClient(configuration: makeConfiguration(
            clock: mock.clock, store: try syntheticStore(), cacheDirectory: directory))
        let session = try await client.ensureSession()

        #expect(await client.currentPhase() == .signed)
        #expect(mock.count(matching: "/api/auth/z/login") == 1)  // the fallback fired
        #expect(mock.count(matching: "/access_tokens") == 2)
        #expect(mock.count(matching: "/api/paas/c1f3a7e2/v2/client") == 1)
        #expect(session.projectToken == mock.mintedTokenList.first)
        // The fallback's fresh biz JWT is persisted with a new acquiredAt.
        let reloaded = try #require(BizSessionCache(
            fileURL: directory.appendingPathComponent("biz-session.cache")).load())
        #expect(reloaded.bizJwt == freshJWT)
        #expect(reloaded.acquiredAtMs == SigningClientTests.baseMs)
    }

    // MARK: - Refresh ladder: expired store → re-login surface (AC: alert)

    @Test func expiredStoreTokenSurfacesReloginBeforeAnyNetwork() async throws {
        let mock = SigningMock()
        installMock(mock)
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        mock.clock.advance(3_700)  // synthetic exp is base + 3600 s
        let client = SigningClient(configuration: makeConfiguration(
            clock: mock.clock, store: try syntheticStore(), cacheDirectory: directory))

        await #expect(throws: SigningClientError.reloginRequired(.storeAccessTokenExpired)) {
            _ = try await client.ensureSession()
        }
        #expect(await client.currentPhase() == .unsigned)
        // The expiry is caught locally: zero requests leave the process.
        #expect(mock.count(matching: "/api/auth/z/login") == 0)
        #expect(mock.count(matching: "/access_tokens") == 0)
    }

    @Test func zLoginBusinessRejectionDemandsRelogin() async throws {
        let mock = SigningMock()
        installMock(mock)
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Live-observed shape of a dead store token: HTTP 200 + code 500.
        mock.loginResponse = { _ in (200, ["code": 500, "msg": "project_token_login_failed"]) }
        let client = SigningClient(configuration: makeConfiguration(
            clock: mock.clock, store: try syntheticStore(), cacheDirectory: directory))

        await #expect(throws: SigningClientError.reloginRequired(.zLoginRejected)) {
            _ = try await client.ensureSession()
        }
    }

    // MARK: - Refresh ladder: server-anchored windows (AC: bounded re-mint)

    @Test func shortServerWindowBacksOffThenRemintsOnce() async throws {
        let mock = SigningMock()
        installMock(mock)
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Server-anchored windows: everything minted before base+60 s expires at
        // base+60 s (the same expiry second, however often you mint); the next
        // mint lands in a full fresh window.
        let windowBoundaryMs = SigningClientTests.baseMs + 60_000
        mock.windowEndForRequest = { nowMs in
            nowMs < windowBoundaryMs ? windowBoundaryMs : windowBoundaryMs + 3_600_000
        }
        try seedCache(directory: directory)  // cached biz session: no z/login involved
        let client = SigningClient(configuration: makeConfiguration(
            clock: mock.clock, cacheDirectory: directory, mintThrottle: 5))
        func mintCount() -> Int { mock.count(matching: "/access_tokens") }

        // t0: mint #1. Remaining window (60 s) < margin (120 s) → relaxed.
        let first = try await client.ensureSession()
        #expect(mintCount() == 1)
        #expect(first.expiresAtMs == windowBoundaryMs)

        // t+30s: still inside the window — no re-mint.
        mock.clock.advance(30)
        _ = try await client.ensureSession()
        #expect(mintCount() == 1)

        // t+62s: past the old window, still inside the bounded backoff — no thrash.
        mock.clock.advance(32)
        _ = try await client.ensureSession()
        #expect(mintCount() == 1)

        // t+66s: backoff over → exactly ONE re-mint, landing in the fresh window.
        mock.clock.advance(4)
        let second = try await client.ensureSession()
        #expect(mintCount() == 2)
        #expect(second.expiresAtMs == windowBoundaryMs + 3_600_000)

        // Further calls (well inside the new window minus margin): no re-mint.
        mock.clock.advance(40)
        _ = try await client.ensureSession()
        _ = try await client.ensureSession()
        #expect(mintCount() == 2)
    }

    // MARK: - Biz session persistence (AC: Application Support, 0600, restart)

    @Test func bizSessionPersistsAt0600AndSurvivesClientRestart() async throws {
        let mock = SigningMock()
        installMock(mock)
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = SigningClient(configuration: makeConfiguration(
            clock: mock.clock, store: try syntheticStore(), cacheDirectory: directory))
        _ = try await first.ensureSession()

        let cacheURL = directory.appendingPathComponent("biz-session.cache")
        let attributes = try FileManager.default.attributesOfItem(atPath: cacheURL.path)
        #expect(((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777 == 0o600)

        // File shape: the three fields, location with the mint triple —
        // structure only, values are synthetic.
        let fileJSON = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: cacheURL)) as? [String: Any])
        #expect(Set(fileJSON.keys) == ["bizJwt", "acquiredAtMs", "location"])
        #expect(fileJSON["acquiredAtMs"] as? Int64 == SigningClientTests.baseMs)
        let locationJSON = try #require(fileJSON["location"] as? [String: Any])
        #expect(Set(locationJSON.keys) == ["organizationId", "projectId", "apiKeyId"])

        // Restart with NO store: the persisted session alone must rebuild the
        // chain (a z/login would be impossible — pins that none fires).
        let second = SigningClient(configuration: makeConfiguration(
            clock: mock.clock, store: nil, cacheDirectory: directory))
        _ = try await second.ensureSession()
        #expect(await second.currentPhase() == .signed)
        #expect(mock.count(matching: "/api/auth/z/login") == 1)  // only the first build's
        #expect(mock.count(matching: "/access_tokens") == 2)
    }

    @Test func cacheSaveReplacesExistingFileAt0600() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = BizSessionCache(fileURL: directory.appendingPathComponent("biz-session.cache"))

        // Second save renames over the existing file — an implementation
        // using moveItem (which refuses existing destinations) would throw.
        try cache.save(BizSession(
            bizJwt: ChainFixtures.bizJwt(tag: "first"),
            acquiredAtMs: SigningClientTests.baseMs - 1_000,
            location: nil))
        try cache.save(BizSession(
            bizJwt: ChainFixtures.bizJwt(tag: "second"),
            acquiredAtMs: SigningClientTests.baseMs,
            location: ChainFixtures.location))

        let reloaded = try #require(cache.load())
        #expect(reloaded.acquiredAtMs == SigningClientTests.baseMs)
        #expect(reloaded.location == ChainFixtures.location)
        // The replacement keeps owner-only permissions.
        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("biz-session.cache").path)
        #expect(((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777 == 0o600)
        // No temporary files are left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(leftovers == ["biz-session.cache"])
    }

    @Test func unusableCacheFallsBackToStoreLogin() async throws {
        let mock = SigningMock()
        installMock(mock)
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Cached session far past its 180 d TTL − margin.
        try seedCache(directory: directory, acquiredAtMs: SigningClientTests.baseMs - 200 * 86_400_000)
        let client = SigningClient(configuration: makeConfiguration(
            clock: mock.clock, store: try syntheticStore(), cacheDirectory: directory))
        _ = try await client.ensureSession()

        #expect(mock.count(matching: "/api/auth/z/login") == 1)
    }

    // MARK: - Concurrency (AC: single in-flight handshake)

    @Test func concurrentEnsureSessionCallsShareOneBuild() async throws {
        let mock = SigningMock()
        installMock(mock)
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let client = SigningClient(configuration: makeConfiguration(
            clock: mock.clock, store: try syntheticStore(), cacheDirectory: directory))

        async let first = client.ensureSession()
        async let second = client.ensureSession()
        let (sessionA, sessionB) = try await (first, second)

        #expect(mock.count(matching: "/api/auth/z/login") == 1)
        #expect(mock.count(matching: "/access_tokens") == 1)
        #expect(mock.count(matching: "/api/paas/c1f3a7e2/v2/client") == 1)
        #expect(sessionA.projectToken == sessionB.projectToken)
    }

    // MARK: - Proactive margin refresh

    @Test func proactiveRefreshRemintsWithinMarginUsingCache() async throws {
        let mock = SigningMock()
        installMock(mock)
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let client = try await makeBuiltClient(cacheDirectory: directory, mock: mock)
        #expect(mock.count(matching: "/access_tokens") == 1)

        // Token lives 10_800 s; margin is 120 s. At +10_680 s the remaining
        // window (120 s) is at the margin edge — inside it, refresh fires.
        mock.clock.advance(10_681)
        _ = try await client.ensureSession()
        #expect(mock.count(matching: "/access_tokens") == 2)
        // The rebuild used the cached biz session, not another z/login.
        #expect(mock.count(matching: "/api/auth/z/login") == 1)
    }

    // MARK: - Failure surfaces

    @Test func noLocationWhenNothingProvidesOne() async throws {
        let mock = SigningMock()
        installMock(mock)
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Usable cached session whose location is null, no injected location.
        try seedCache(directory: directory, location: nil)
        let client = SigningClient(configuration: makeConfiguration(
            clock: mock.clock, store: nil, location: nil, cacheDirectory: directory))

        await #expect(throws: SigningClientError.noLocation) {
            _ = try await client.ensureSession()
        }
        #expect(mock.count(matching: "/access_tokens") == 0)
    }

    @Test func cachedSessionWithoutLocationFillsItFromStoreWithoutLogin() async throws {
        // zbridge-era cache shape: usable biz session, null location, none
        // injected. The store's project-key-location entry fills the gap —
        // the chain builds (no .noLocation 502 for the cache's remaining
        // lifetime) with zero z/login calls.
        let mock = SigningMock()
        installMock(mock)
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try seedCache(directory: directory, location: nil)
        let store = try syntheticStore()
        let client = SigningClient(configuration: makeConfiguration(
            clock: mock.clock, store: store, location: nil, cacheDirectory: directory))
        _ = try await client.ensureSession()

        #expect(await client.currentPhase() == .signed)
        #expect(mock.count(matching: "/api/auth/z/login") == 0)
        #expect(mock.count(matching: "/access_tokens") == 1)
        // The mint targeted the store's location triple.
        let storedLocation = try #require(try store.projectKeyLocation())
        let mintRequest = try #require(mock.requests(matching: "/access_tokens").first)
        #expect(mintRequest.url.path.contains("/organization/\(storedLocation.organizationId)/"))
        #expect(mintRequest.url.path.contains("/api_keys/\(storedLocation.apiKeyId)/"))
        // The resolved location is persisted back — the cache is repaired.
        let reloaded = try #require(BizSessionCache(
            fileURL: directory.appendingPathComponent("biz-session.cache")).load())
        #expect(reloaded.location == MintLocation(
            organizationId: storedLocation.organizationId,
            projectId: storedLocation.projectId,
            apiKeyId: storedLocation.apiKeyId))
    }

    // MARK: - Cold-start location from the store (real store value shape)

    /// A store with no location entry, loaded successfully — plaintext
    /// passthrough values need no secret agreement.
    private func storeWithoutLocation() throws -> CredentialStore {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try JSONEncoder()
            .encode([CredentialStore.accessTokenField: "synthetic-token"])
            .write(to: dir.appendingPathComponent("credentials.json"))
        try Data("any-secret".utf8).write(to: dir.appendingPathComponent("secret.txt"))
        return try CredentialStore(
            storeURL: dir.appendingPathComponent("credentials.json"),
            secretURL: dir.appendingPathComponent("secret.txt"))
    }

    @Test func coldStartResolvesLocationFromStore() async throws {
        let mock = SigningMock()
        installMock(mock)
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // No cache, no injected location — only the synthetic store's
        // {organizationId, projectId, apiKeyId} value object can supply one.
        let store = try syntheticStore()
        let storedLocation = try #require(try store.projectKeyLocation())
        let client = SigningClient(configuration: makeConfiguration(
            clock: mock.clock, store: store, location: nil, cacheDirectory: directory))
        _ = try await client.ensureSession()
        #expect(await client.currentPhase() == .signed)

        // The mint targeted the store's location triple (synthetic UUIDs —
        // exact values are pinned in CredentialStoreTests).
        let mintRequest = try #require(mock.requests(matching: "/access_tokens").first)
        #expect(mintRequest.url.path.contains("/organization/\(storedLocation.organizationId)/"))
        #expect(mintRequest.url.path.contains("/projects/\(storedLocation.projectId)/"))
        #expect(mintRequest.url.path.contains("/api_keys/\(storedLocation.apiKeyId)/"))
    }

    @Test func noLocationOnColdStartFailsFastBeforeAnyNetwork() async throws {
        let mock = SigningMock()
        installMock(mock)
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // No cache, no injected location, and a store with no location entry:
        // noLocation must surface BEFORE z/login leaves the process.
        let client = SigningClient(configuration: makeConfiguration(
            clock: mock.clock, store: try storeWithoutLocation(),
            location: nil, cacheDirectory: directory))

        await #expect(throws: SigningClientError.noLocation) {
            _ = try await client.ensureSession()
        }
        #expect(mock.count(matching: "/api/auth/z/login") == 0)
        #expect(mock.count(matching: "/access_tokens") == 0)
        #expect(mock.count(matching: "/api/paas/c1f3a7e2") == 0)
    }

    @Test func handshakeBusinessFailureLeavesClientUnsigned() async throws {
        let mock = SigningMock()
        installMock(mock)
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try seedCache(directory: directory)
        // Handshake answers HTTP 200 with business code 401 (signature reject).
        mock.handshakeResponse = { _ in (200, ["code": 401, "msg": "signature mismatch"]) }
        let client = SigningClient(configuration: makeConfiguration(
            clock: mock.clock, cacheDirectory: directory))

        await #expect(throws: SigningClientError.handshakeFailed(status: 200, code: 401)) {
            _ = try await client.ensureSession()
        }
        #expect(await client.currentPhase() == .unsigned)
    }

    @Test func apiKeyIdResolvesFromTokenClaimThenLocationFallback() async throws {
        let mock = SigningMock()
        installMock(mock)
        let claimId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        mock.mintedTokenAPIKeyClaim = claimId
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // The claim wins (and the mock seals the key with it — a location-id
        // AAD would fail the unseal).
        let client = SigningClient(configuration: makeConfiguration(
            clock: mock.clock, store: try syntheticStore(), cacheDirectory: directory))
        let session = try await client.ensureSession()
        #expect(session.apiKeyId == claimId)

        // Without a claim, the location's apiKeyId is used.
        let mock2 = SigningMock()
        mock2.mintedTokenAPIKeyClaim = nil
        installMock(mock2)
        let directory2 = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory2) }
        let client2 = SigningClient(configuration: makeConfiguration(
            clock: mock2.clock, store: try syntheticStore(), cacheDirectory: directory2))
        let session2 = try await client2.ensureSession()
        #expect(session2.apiKeyId == ChainFixtures.location.apiKeyId)
    }
}

/// Live smoke (executor-run, never CI): one real chain build against api.z.ai
/// plus a cached-session rebuild with z/login skipped. Enabled only when
/// `ZGATE_LIVE_SMOKE=1` is exported into the test environment. Prints status,
/// ms, and lengths only — no credential value ever reaches stdout.
@Suite(.serialized)
struct SigningClientLiveSmokeTests {

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZGATE_LIVE_SMOKE"] == "1"))
    func liveChainBuildAndCachedRebuild() async throws {
        let fileManager = FileManager.default
        let scratchHome = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".zcode-scratch-v3", isDirectory: true)
        // The zbridge stopgap's cache holds a live-verified location triple
        // (read programmatically; never printed).
        let bridgeCacheData = try Data(contentsOf: scratchHome.appendingPathComponent("biz-session.cache"))
        let bridgeCache = try #require(
            try JSONSerialization.jsonObject(with: bridgeCacheData) as? [String: Any])
        let locationObject = try #require(bridgeCache["location"] as? [String: Any])
        let location = MintLocation(
            organizationId: try #require(locationObject["organizationId"] as? String),
            projectId: try #require(locationObject["projectId"] as? String),
            apiKeyId: try #require(locationObject["apiKeyId"] as? String))

        let smokeDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("zgate-live-smoke-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: smokeDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: smokeDirectory) }
        let cacheURL = smokeDirectory.appendingPathComponent("biz-session.cache")

        func evidence(_ prefix: String, _ events: [SigningClient.ChainEvent]) {
            for event in events {
                print("[zgate-smoke] \(prefix) \(event.stage.rawValue)"
                    + " status=\(event.status) ms=\(event.ms)"
                    + " len=\(event.outcomeTokenLength.map(String.init) ?? "-")")
            }
        }
        func assertKeyWorks(_ session: SigningSession, _ label: String) throws {
            let message = Data("zgate-live-smoke".utf8)
            let signature = try session.privateKey.signature(for: message)
            #expect(session.privateKey.publicKey.isValidSignature(signature, for: message))
            print("[zgate-smoke] \(label) key OK (sign/verify round trip, projectTokenLen=\(session.projectToken.count))")
        }

        // Build 1 — full path: store → z/login → mint → handshake.
        let store = try? CredentialStore(base: scratchHome)
        var fullConfiguration = SigningClient.Configuration()
        fullConfiguration.store = store
        fullConfiguration.initialLocation = location
        fullConfiguration.cacheURL = cacheURL
        let fullClient = SigningClient(configuration: fullConfiguration)

        var fullPathRan = false
        var pendingReason: String?
        if store == nil {
            pendingReason = "credential store unreadable"
        } else {
            do {
                let session = try await fullClient.ensureSession()
                fullPathRan = true
                #expect(await fullClient.currentPhase() == .signed)
                evidence("build1", await fullClient.lastChainEvents())
                try assertKeyWorks(session, "build1")
            } catch let error as SigningClientError {
                guard case SigningClientError.reloginRequired = error else { throw error }
                pendingReason = "store token needs a fresh browser login"
            }
        }
        if let pendingReason {
            print("[zgate-smoke] build1 PENDING FRESH LOGIN (\(pendingReason)) — running cache path")
        }

        if !fullPathRan {
            // Store unavailable: seed the injected cache from the zbridge
            // session file verbatim (bizJwt + acquiredAtMs + location).
            try fileManager.copyItem(
                at: scratchHome.appendingPathComponent("biz-session.cache"), to: cacheURL)
        } else {
            let attributes = try fileManager.attributesOfItem(atPath: cacheURL.path)
            #expect(((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777 == 0o600)
            print("[zgate-smoke] build1 persisted biz session (0600)")
        }

        // Build 2 — restart on the persisted session; z/login is impossible
        // (no store configured), so success proves it was skipped.
        var cacheConfiguration = SigningClient.Configuration()
        cacheConfiguration.store = nil
        cacheConfiguration.initialLocation = location
        cacheConfiguration.cacheURL = cacheURL
        let cacheClient = SigningClient(configuration: cacheConfiguration)
        let session2 = try await cacheClient.ensureSession()
        #expect(await cacheClient.currentPhase() == .signed)
        let events2 = await cacheClient.lastChainEvents()
        evidence("build2", events2)
        #expect(!events2.contains { $0.stage == .login })
        try assertKeyWorks(session2, "build2")
        print("[zgate-smoke] build2 z/login requests: 0 (cached biz session)")
    }
}

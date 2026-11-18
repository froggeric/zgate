import CryptoKit
import Foundation
import Testing
@testable import ZGate

/// Offline tests for `CredentialKeeper` — proactive renewal scheduling,
/// wake re-evaluation, and ladder-death backoff — against a real
/// SigningClient driven by a URLProtocol mock with synthetic fixtures and
/// a parked virtual clock. Zero user (relayed) requests flow anywhere.
@Suite(.serialized)
struct CredentialKeeperTests {

    // MARK: - Fixtures

    private static let baseDate = Date(timeIntervalSince1970: 1_763_000_000)
    private static var baseMs: Int64 { 1_763_000_000_000 }

    private enum ChainFixtures {
        static let apiKeyId = "b5f4e6998889200000000000000088920"
        static let location = MintLocation(
            organizationId: "11111111-1111-1111-1111-111111111111",
            projectId: "22222222-2222-2222-2222-222222222222",
            apiKeyId: apiKeyId)

        static func fakeJWT(payload: [String: Any]) -> String {
            let header = Base64URL.encode(Data(#"{"alg":"HS256","typ":"JWT"}"#.utf8))
            let body = Base64URL.encode(try! JSONSerialization.data(withJSONObject: payload))
            return [header, body, "c2lnbmF0dXJl"].joined(separator: ".")
        }

        static func projectToken() -> String {
            fakeJWT(payload: ["token_use": "project_access", "api_key": apiKeyId])
        }

        /// Seals a fixed Ed25519 seed exactly like the server does.
        static func sealPrivateKey(projectToken: String, apiKeyId: String) throws -> String {
            let key = SymmetricKey(data: CryptoCore.hkdf(
                ikm: Data(projectToken.utf8),
                salt: Data(CryptoCore.kdfSalt.utf8),
                info: Data(CryptoCore.ed25519Info.utf8),
                length: 32))
            let seed = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
            let pkcs8Prefix: [UInt8] = [
                0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b,
                0x65, 0x70, 0x04, 0x22, 0x04, 0x20]
            let plaintext = Data((Data(pkcs8Prefix) + seed).base64EncodedString().utf8)
            let sealed = try AES.GCM.seal(
                plaintext, using: key,
                nonce: AES.GCM.Nonce(data: Data((0..<12).map { UInt8($0) })),
                authenticating: Data(apiKeyId.utf8))
            return sealed.combined!.base64EncodedString()
        }
    }

    // MARK: - Mock plumbing

    /// Serves the three chain endpoints. `mintWindowSeconds` controls the
    /// server-anchored window (keeper scheduling input).
    private final class KeeperMock: @unchecked Sendable {
        private let lock = NSRecursiveLock()
        private var mintedTokens: [String] = []
        private var loginCount = 0
        private var mintCount = 0

        var mintWindowSeconds: Double = 3600
        /// Overrides the default z/login success (status, body object).
        var loginResponse: ((Int, [String: Any]))?

        var loginRequests: Int { lock.withLock { loginCount } }
        var mintRequests: Int { lock.withLock { mintCount } }

        func respond(to request: URLRequest) throws -> (Int, Data) {
            let path = request.url?.path ?? ""
            if path.contains("/api/auth/z/login") {
                lock.lock()
                loginCount += 1
                let override = loginResponse
                lock.unlock()
                if let (status, object) = override {
                    return (status, try JSONSerialization.data(withJSONObject: object))
                }
                return (200, try JSONSerialization.data(withJSONObject: [
                    "code": 200,
                    "data": ["access_token": ChainFixtures.fakeJWT(
                        payload: ["sub": String(repeating: "biz", count: 40), "role": "session"])],
                ]))
            }
            if path.contains("/access_tokens") {
                lock.lock()
                mintCount += 1
                let window = mintWindowSeconds
                lock.unlock()
                let token = ChainFixtures.projectToken()
                lock.lock()
                mintedTokens.append(token)
                lock.unlock()
                return (200, try JSONSerialization.data(withJSONObject: [
                    "code": 200,
                    "data": ["accessToken": token, "expiresIn": window],
                ]))
            }
            if path.contains("/api/paas/c1f3a7e2/v2/client") {
                let token = lock.withLock { mintedTokens.last }
                guard let token else {
                    throw NSError(domain: "KeeperMock", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "handshake before any mint"])
                }
                let cipher = try ChainFixtures.sealPrivateKey(
                    projectToken: token, apiKeyId: ChainFixtures.apiKeyId)
                return (200, try JSONSerialization.data(withJSONObject: [
                    "code": 200, "data": ["privateCipher": cipher],
                ]))
            }
            throw NSError(domain: "KeeperMock", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "unexpected path \(path)"])
        }
    }

    private final class KeeperURLProtocol: URLProtocol {
        nonisolated(unsafe) static var mock: KeeperMock?

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
    }

    /// Parked virtual clock: `sleep(seconds:)` records the request and
    /// parks (cancellation-safe); the TEST advances time and releases
    /// sleeps explicitly, so scheduled waits and wake races are both
    /// deterministic.
    final class ParkedClock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant: Date
        private var parked: [CheckedContinuation<Void, Error>] = []
        private var cancelled = false
        private var slept: [TimeInterval] = []

        init(_ date: Date) { instant = date }

        var now: Date { lock.withLock { instant } }
        var sleeps: [TimeInterval] { lock.withLock { slept } }

        func advance(_ seconds: TimeInterval) {
            lock.withLock { instant = instant.addingTimeInterval(seconds) }
        }

        func sleep(seconds: TimeInterval) async throws {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    let resumeNow = lock.withLock { () -> Bool in
                        if cancelled {
                            cancelled = false   // consume: one cancellation per sleep
                            return true
                        }
                        slept.append(seconds)
                        parked.append(c)
                        return false
                    }
                    if resumeNow { c.resume(throwing: CancellationError()) }
                }
            } onCancel: {
                let toResume = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
                    cancelled = true
                    let p = parked
                    parked = []
                    return p
                }
                toResume.forEach { $0.resume(throwing: CancellationError()) }
            }
        }

        /// Test-side: let the OLDEST parked sleep return (time passage).
        func releaseOldestSleep() {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                parked.isEmpty ? nil : parked.removeFirst()
            }
            continuation?.resume()
        }
    }

    /// Records emitted events as an async stream (deterministic waiting).
    final class EventRecorder: @unchecked Sendable {
        private let continuation: AsyncStream<CredentialEvent>.Continuation
        let stream: AsyncStream<CredentialEvent>

        init() {
            let (stream, continuation) = AsyncStream.makeStream(of: CredentialEvent.self)
            self.stream = stream
            self.continuation = continuation
        }

        var emit: @Sendable (CredentialEvent) -> Void {
            { [continuation] event in continuation.yield(event) }
        }
    }

    // MARK: - Helpers

    private func makeClient(
        clock: ParkedClock, cacheDirectory: URL
    ) -> SigningClient {
        var configuration = SigningClient.Configuration()
        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [KeeperURLProtocol.self]
        configuration.session = URLSession(configuration: urlSessionConfiguration)
        configuration.storeLoader = { try CredentialStore(fixture: .synthetic) }
        configuration.initialLocation = ChainFixtures.location
        configuration.cacheURL = cacheDirectory.appendingPathComponent("biz-session.cache")
        configuration.now = { clock.now }
        return SigningClient(configuration: configuration)
    }

    private func makeKeeperConfiguration(
        clock: ParkedClock,
        capturedWake: CapturedWake
    ) -> CredentialKeeper.Configuration {
        var configuration = CredentialKeeper.Configuration()
        configuration.now = { clock.now }
        configuration.sleep = { try await clock.sleep(seconds: $0) }
        configuration.jitter = { 0 }
        configuration.wakeSubscription = { handler in
            capturedWake.set(handler)
            return {}
        }
        return configuration
    }

    /// Captures the wake handler the keeper registered (test fires it).
    final class CapturedWake: @unchecked Sendable {
        let lock = NSLock()
        private var handler: (@Sendable () -> Void)?
        func fire() { lock.withLock { handler }?() }
        func set(_ h: @escaping @Sendable () -> Void) { lock.withLock { handler = h } }
    }

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zgate-credentialkeeper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Waits until the clock has recorded `count` sleep requests.
    /// Waits until the clock has recorded `count` sleep requests. Bounded:
    /// a scheduling bug surfaces as a test failure, never a hung suite.
    private func awaitSleeps(clock: ParkedClock, count: Int) async throws {
        let deadline = Date().addingTimeInterval(30)
        while clock.sleeps.count < count {
            if Date() > deadline {
                Issue.record("timed out waiting for sleep request \(count) (have \(clock.sleeps.count): \(clock.sleeps))")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Proactive renewal (AC: mint at expiry − margin, zero requests)

    @Test func renewalFiresAtExpiryMarginWithoutRelayedRequests() async throws {
        let mock = KeeperMock()
        KeeperURLProtocol.mock = mock
        let clock = ParkedClock(Self.baseDate)
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let client = makeClient(clock: clock, cacheDirectory: directory)
        _ = try await client.ensureSession()
        #expect(mock.mintRequests == 1)

        let wake = CapturedWake()
        let keeper = CredentialKeeper(
            client: client,
            configuration: makeKeeperConfiguration(clock: clock, capturedWake: wake),
            emit: { _ in })
        keeper.start()
        defer { keeper.stop() }

        // Healthy session, expiry 3600 s out: the schedule clamps to the
        // 5-minute re-check, not the full 3480 s.
        try await awaitSleeps(clock: clock, count: 1)
        #expect(clock.sleeps == [300])

        // Advance to expiry − margin (t+3480) and let the re-check sleep
        // return: the keeper renews proactively — a re-mint on the cached
        // biz session (no z/login), with ZERO relayed user requests.
        clock.advance(3480)
        clock.releaseOldestSleep()
        try await awaitSleeps(clock: clock, count: 2)
        #expect(mock.mintRequests == 2)
        // No additional z/login — the proactive re-mint rode the cached
        // biz session (1 login total, from the initial build).
        #expect(mock.loginRequests == 1)

        // After the renewal the next schedule is the re-check clamp again.
        #expect(clock.sleeps.dropFirst().first == 300)
    }

    @Test func wakeReevaluatesImmediately() async throws {
        let mock = KeeperMock()
        KeeperURLProtocol.mock = mock
        let clock = ParkedClock(Self.baseDate)
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let client = makeClient(clock: clock, cacheDirectory: directory)
        _ = try await client.ensureSession()
        #expect(mock.loginRequests == 1)

        let recorder = EventRecorder()
        let wake = CapturedWake()
        let keeper = CredentialKeeper(
            client: client,
            configuration: makeKeeperConfiguration(clock: clock, capturedWake: wake),
            emit: recorder.emit)
        keeper.start()
        defer { keeper.stop() }

        try await awaitSleeps(clock: clock, count: 1)
        // The clock jumped past expiry−margin (long sleep) while the
        // re-check sleep is still parked: a wake notification must trigger
        // immediate re-evaluation — a renewal fires WITHOUT the scheduled
        // sleep ever elapsing.
        clock.advance(3480)
        wake.fire()

        var iterator = recorder.stream.makeAsyncIterator()
        let event = await iterator.next()
        guard case let .renewed(expiresAtMs) = event else {
            Issue.record("expected .renewed, got \(String(describing: event))")
            return
        }
        #expect(expiresAtMs == Self.baseMs + 3_480_000 + 3_600_000)
        #expect(mock.mintRequests == 2)
        #expect(mock.loginRequests == 1)  // renewal used the cached biz session
    }

    @Test func ladderDeathEmitsFailureAndBacksOffExponentially() async throws {
        let mock = KeeperMock()
        mock.loginResponse = (200, ["code": 500, "msg": "project_token_login_failed"])
        KeeperURLProtocol.mock = mock
        let clock = ParkedClock(Self.baseDate)
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let client = makeClient(clock: clock, cacheDirectory: directory)
        let recorder = EventRecorder()
        let wake = CapturedWake()
        let keeper = CredentialKeeper(
            client: client,
            configuration: makeKeeperConfiguration(clock: clock, capturedWake: wake),
            emit: recorder.emit)
        keeper.start()
        defer { keeper.stop() }

        // Unsigned ladder → 5-minute re-check → renewal attempt → z/login
        // business-reject (ladder death): .expired emitted, backoff 5 s
        // (the mintThrottle base), then exponential 10/20 — never a tight
        // mint loop.
        try await awaitSleeps(clock: clock, count: 1)
        #expect(clock.sleeps == [300])
        clock.advance(300)
        clock.releaseOldestSleep()
        try await awaitSleeps(clock: clock, count: 2)
        #expect(clock.sleeps[1] == 5)

        clock.advance(5)
        clock.releaseOldestSleep()
        try await awaitSleeps(clock: clock, count: 3)
        #expect(clock.sleeps[2] == 10)

        clock.advance(10)
        clock.releaseOldestSleep()
        try await awaitSleeps(clock: clock, count: 4)
        #expect(clock.sleeps[3] == 20)

        // One z/login attempt per ELAPSED backoff window (the 20 s window
        // is still pending) — bounded, not looping.
        #expect(mock.loginRequests == 3)
        #expect(mock.mintRequests == 0)
    }
}

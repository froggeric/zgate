import Foundation
import Testing
@testable import ZGate

/// Offline tests for `ZaiLoginClient` — the native in-app CLI OAuth flow
/// (init → authorize URL → poll), driven entirely through a URLProtocol
/// mock with a virtual clock. All tokens are synthetic; no token value is
/// ever asserted into a logged string.
@Suite(.serialized)
struct ZaiLoginClientTests {

    // MARK: - Fixtures

    private static let baseDate = Date(timeIntervalSince1970: 1_763_000_000)
    /// Synthetic 32-byte hex poll token (injected, not generated).
    private static let pollToken = String(repeating: "ab", count: 32)

    private enum Wire {
        static let flowID = "synthetic-flow-id"
        static let authorizeURL = "https://auth.z.ai/oauth/synthetic-authorize"
        static let accessToken = "synthetic-access-jwt.404chars-ish"
        static let identityToken = "synthetic-identity-jwt"
        static let userJSON = #"{"id":"synthetic-user","name":"Synthetic"}"#
    }

    // MARK: - Mock plumbing

    private final class LoginMock: @unchecked Sendable {
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
        /// Popped in order per poll request; empty → HTTP 500.
        var pollResponses: [(Int, [String: Any])] = []
        /// Overrides the default init success (status, body object).
        var initResponse: ((RecordedRequest) throws -> (Int, [String: Any]))?

        func requests(matching marker: String) -> [RecordedRequest] {
            lock.lock(); defer { lock.unlock() }
            return recorded.filter { $0.url.path.contains(marker) }
        }

        func respond(to request: URLRequest) throws -> (Int, Data) {
            let body = ZaiLoginURLProtocol.body(of: request)
            let recordedRequest = RecordedRequest(
                url: request.url ?? URL(fileURLWithPath: "/unknown"),
                method: request.httpMethod ?? "",
                headers: request.allHTTPHeaderFields ?? [:],
                body: body)
            lock.lock()
            recorded.append(recordedRequest)
            lock.unlock()

            let path = recordedRequest.url.path
            if path.contains("/oauth/cli/init") {
                if let initResponse {
                    let (status, object) = try initResponse(recordedRequest)
                    return (status, try JSONSerialization.data(withJSONObject: object))
                }
                return (200, try JSONSerialization.data(withJSONObject: [
                    "flow_id": Wire.flowID,
                    "authorize_url": Wire.authorizeURL,
                    "expires_at": 1_763_003_600,
                    "poll_interval_sec": 150,
                ]))
            }
            if path.contains("/oauth/cli/poll/") {
                lock.lock()
                let next = pollResponses.isEmpty ? nil : pollResponses.removeFirst()
                lock.unlock()
                let (status, object) = next ?? (500, [:])
                return (status, try JSONSerialization.data(withJSONObject: object))
            }
            throw NSError(domain: "LoginMock", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "unexpected path \(path)"])
        }
    }

    private final class ZaiLoginURLProtocol: URLProtocol {
        nonisolated(unsafe) static var mock: LoginMock?

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

    /// Virtual clock: `sleep(seconds:)` advances time instantly and records
    /// the requested durations (the GatedSplashClock/ManualClock pattern).
    private final class VirtualClock: @unchecked Sendable {
        let lock = NSLock()
        private var instant: Date
        private var slept: [TimeInterval] = []
        private var advanced: TimeInterval = 0

        init(_ date: Date) { instant = date }

        var now: Date { lock.withLock { instant } }
        var sleeps: [TimeInterval] { lock.withLock { slept } }
        var totalAdvanced: TimeInterval { lock.withLock { advanced } }

        func advance(_ seconds: TimeInterval) {
            lock.withLock {
                instant = instant.addingTimeInterval(seconds)
                advanced += seconds
            }
        }

        func sleep(seconds: TimeInterval) async throws {
            lock.withLock {
                slept.append(seconds)
                instant = instant.addingTimeInterval(seconds)
            }
        }
    }

    // MARK: - Helpers

    private func makeConfiguration(
        clock: VirtualClock,
        pollToken: String = ZaiLoginClientTests.pollToken,
        storeBase: URL? = nil,
        overallTimeout: TimeInterval = 300,
        onEvent: (@Sendable (CredentialEvent) -> Void)? = nil
    ) -> ZaiLoginClient.Configuration {
        var configuration = ZaiLoginClient.Configuration()
        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [ZaiLoginURLProtocol.self]
        configuration.session = URLSession(configuration: urlSessionConfiguration)
        configuration.pollToken = pollToken
        configuration.now = { clock.now }
        configuration.sleep = { try await clock.sleep(seconds: $0) }
        configuration.storeBase = storeBase
        configuration.overallTimeout = overallTimeout
        configuration.onEvent = onEvent
        return configuration
    }

    private func readyBody() -> [String: Any] {
        [
            "status": "ready",
            "accessToken": Wire.accessToken,
            "token": Wire.identityToken,
            "user": ["id": "synthetic-user", "name": "Synthetic"],
        ]
    }

    // MARK: - Poll token generation

    @Test func pollTokenIsRandom64HexChars() {
        let first = ZaiLoginClient.generatePollToken()
        let second = ZaiLoginClient.generatePollToken()
        #expect(first.count == 64)
        #expect(first.allSatisfy { $0.isHexDigit })
        #expect(first != second)
    }

    // MARK: - Init wire form (AC: POST /oauth/cli/init, provider body, bearer)

    @Test func beginPostsProviderBodyWithPollTokenBearer() async throws {
        let mock = LoginMock()
        ZaiLoginURLProtocol.mock = mock
        let clock = VirtualClock(Self.baseDate)

        let client = ZaiLoginClient(configuration: makeConfiguration(clock: clock))
        try await client.begin()

        let request = try #require(mock.requests(matching: "/oauth/cli/init").first)
        #expect(request.method == "POST")
        let jsonBody = try #require(request.jsonBody)
        #expect(jsonBody["provider"] as? String == "zai")
        #expect(jsonBody.count == 1)
        #expect(request.headers["Authorization"] == "Bearer \(Self.pollToken)")
        let url = try await client.authorizeURL()
        #expect(url?.absoluteString == Wire.authorizeURL)
    }

    // MARK: - Poll ladder (AC: pending → ready at the advertised interval)

    @Test func pollPendingThenReadyYieldsCredentials() async throws {
        let mock = LoginMock()
        mock.pollResponses = [
            (200, ["data": ["status": "pending"]]),
            (200, ["data": readyBody()]),
        ]
        ZaiLoginURLProtocol.mock = mock
        let clock = VirtualClock(Self.baseDate)

        let client = ZaiLoginClient(configuration: makeConfiguration(clock: clock))
        try await client.begin()
        let outcome = try await client.pollUntilTerminal()

        guard case let .ready(credentials) = outcome else {
            Issue.record("expected ready, got \(outcome)")
            return
        }
        #expect(credentials.accessToken == Wire.accessToken)
        #expect(credentials.zcodeJwtToken == Wire.identityToken)
        #expect(credentials.userInfoJSON.contains("synthetic-user"))
        // One sleep, at the server-advertised interval (150 s).
        #expect(clock.sleeps == [150])
        // Every poll carried the same poll-token bearer.
        let polls = mock.requests(matching: "/oauth/cli/poll/")
        #expect(polls.count == 2)
        #expect(polls.allSatisfy { $0.headers["Authorization"] == "Bearer \(Self.pollToken)" })
        // No store base configured → nothing persisted (caller-owned).
        #expect(mock.requests(matching: "/oauth/cli/poll/").count == 2)
    }

    @Test func pollTolerates408429And5xx() async throws {
        let mock = LoginMock()
        // Short advertised interval so the tolerated errors fit inside the
        // 300 s cap with room to spare.
        mock.initResponse = { _ in
            (200, [
                "flow_id": Wire.flowID,
                "authorize_url": Wire.authorizeURL,
                "expires_at": 1_763_003_600,
                "poll_interval_sec": 5,
            ])
        }
        mock.pollResponses = [
            (408, [:]),
            (429, [:]),
            (500, [:]),
            (200, ["data": readyBody()]),
        ]
        ZaiLoginURLProtocol.mock = mock
        let clock = VirtualClock(Self.baseDate)

        let client = ZaiLoginClient(configuration: makeConfiguration(clock: clock))
        try await client.begin()
        let outcome = try await client.pollUntilTerminal()

        guard case .ready = outcome else {
            Issue.record("expected ready after tolerated errors, got \(outcome)")
            return
        }
        #expect(mock.requests(matching: "/oauth/cli/poll/").count == 4)
        #expect(clock.sleeps.count == 3)
    }

    @Test func pollFailedIsTerminalWithoutSleeping() async throws {
        let mock = LoginMock()
        mock.pollResponses = [(200, ["data": ["status": "auth_failed"]])]
        ZaiLoginURLProtocol.mock = mock
        let clock = VirtualClock(Self.baseDate)

        let client = ZaiLoginClient(configuration: makeConfiguration(clock: clock))
        try await client.begin()
        let outcome = try await client.pollUntilTerminal()

        #expect(outcome == .failed(status: "auth_failed"))
        #expect(clock.sleeps.isEmpty)
    }

    @Test func overallCapTimesOutAt300Seconds() async throws {
        let mock = LoginMock()
        mock.pollResponses = [
            (200, ["data": ["status": "pending"]]),
            (200, ["data": ["status": "pending"]]),
            (200, ["data": ["status": "pending"]]),
        ]
        // Exhausted script answers 500 forever — tolerated but capped.
        ZaiLoginURLProtocol.mock = mock
        let clock = VirtualClock(Self.baseDate)

        let client = ZaiLoginClient(configuration: makeConfiguration(clock: clock))
        try await client.begin()
        let outcome = try await client.pollUntilTerminal()

        // 150 s interval: polls at t=0/150/300; the 300 s cap ends the flow.
        #expect(outcome == .timedOut(afterMs: 300_000))
        #expect(mock.requests(matching: "/oauth/cli/poll/").count == 3)
        #expect(clock.sleeps.count == 2)
    }

    // MARK: - Ready → envelope write path (AC: store readable by CredentialStore)

    @Test func readyPersistsThroughEnvelopeWritePath() async throws {
        let mock = LoginMock()
        mock.pollResponses = [(200, ["data": readyBody()])]
        ZaiLoginURLProtocol.mock = mock
        let clock = VirtualClock(Self.baseDate)
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("zgate-loginclient-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let client = ZaiLoginClient(configuration: makeConfiguration(
            clock: clock, storeBase: base))
        try await client.begin()
        let outcome = try await client.pollUntilTerminal()
        guard case .ready = outcome else {
            Issue.record("expected ready, got \(outcome)")
            return
        }

        // The written store decrypts through the REAL read path.
        let store = try CredentialStore(base: base)
        #expect(try store.accessToken() == Wire.accessToken)
        #expect(try store.zcodeJwtToken() == Wire.identityToken)
        #expect(try store.value(for: CredentialStore.userInfoField).contains("synthetic-user"))
        #expect(try store.value(for: CredentialStore.activeProviderField) == "zai")
    }

    // MARK: - Ready → missing-location warning (fast-follow F3)

    /// Fresh temp base for a client-driven store write, with cleanup.
    private func makeStoreBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("zgate-loginclient-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @Test func readyWithoutStoreLocationWarnsAfterComplete() async throws {
        let mock = LoginMock()
        mock.pollResponses = [(200, ["data": readyBody()])]
        ZaiLoginURLProtocol.mock = mock
        let clock = VirtualClock(Self.baseDate)
        let base = try makeStoreBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let lock = NSLock()
        var events: [CredentialEvent] = []
        let client = ZaiLoginClient(configuration: makeConfiguration(
            clock: clock, storeBase: base,
            onEvent: { event in lock.withLock { events.append(event) } }))
        try await client.begin()
        let outcome = try await client.pollUntilTerminal()
        guard case .ready = outcome else {
            Issue.record("expected ready, got \(outcome)")
            return
        }

        // The warning trails .authorizationComplete so it is the channel's
        // LAST event (the standing face reads events.last); its payload is
        // fixed typed copy, never token material.
        #expect(lock.withLock { events } == [
            .awaitingAuthorization,
            .authorizationComplete,
            .refreshFailed(
                stage: "location", reason: ZaiLoginClient.missingLocationReason),
        ])
    }

    @Test func readyWithPreservedLocationEmitsNoLocationWarning() async throws {
        let mock = LoginMock()
        mock.pollResponses = [(200, ["data": readyBody()])]
        ZaiLoginURLProtocol.mock = mock
        let clock = VirtualClock(Self.baseDate)
        // Seed the base with the committed synthetic store + secret so the
        // ready persist preserves a `project-key-location:v1:*` entry —
        // then the login IS fully working and must not warn.
        let base = try makeStoreBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let v2 = base.appendingPathComponent(".zcode/v2", isDirectory: true)
        try FileManager.default.createDirectory(at: v2, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: CredentialStoreTests.fixtureDirectory.appendingPathComponent("credentials.json"),
            to: v2.appendingPathComponent("credentials.json"))
        try FileManager.default.copyItem(
            at: CredentialStoreTests.fixtureDirectory.appendingPathComponent("secret.txt"),
            to: base.appendingPathComponent("secret.txt"))

        let lock = NSLock()
        var events: [CredentialEvent] = []
        let client = ZaiLoginClient(configuration: makeConfiguration(
            clock: clock, storeBase: base,
            onEvent: { event in lock.withLock { events.append(event) } }))
        try await client.begin()
        let outcome = try await client.pollUntilTerminal()
        guard case .ready = outcome else {
            Issue.record("expected ready, got \(outcome)")
            return
        }

        #expect(lock.withLock { events } == [
            .awaitingAuthorization,
            .authorizationComplete,
        ])
        // The preserved location survived the write.
        let store = try CredentialStore(base: base)
        #expect(try store.projectKeyLocation() != nil)
        #expect(try store.accessToken() == Wire.accessToken)
    }

    // MARK: - Lifecycle guards

    @Test func pollingBeforeBeginThrowsNotStarted() async throws {
        let mock = LoginMock()
        ZaiLoginURLProtocol.mock = mock
        let clock = VirtualClock(Self.baseDate)

        let client = ZaiLoginClient(configuration: makeConfiguration(clock: clock))
        await #expect(throws: ZaiLoginError.notStarted) {
            _ = try await client.pollUntilTerminal()
        }
        #expect(mock.requests(matching: "/oauth/cli").isEmpty)
    }

    @Test func malformedInitAnswerThrows() async throws {
        let mock = LoginMock()
        mock.initResponse = { _ in (200, ["unrelated": true]) }
        ZaiLoginURLProtocol.mock = mock
        let clock = VirtualClock(Self.baseDate)

        let client = ZaiLoginClient(configuration: makeConfiguration(clock: clock))
        await #expect(throws: ZaiLoginError.self) {
            try await client.begin()
        }
        let url = try await client.authorizeURL()
        #expect(url == nil)
    }
}

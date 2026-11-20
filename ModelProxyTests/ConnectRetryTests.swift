import AsyncHTTPClient
import CryptoKit
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOHTTP1
import NIOPosix
import Network
import Testing
@testable import ZGate

/// Task 8: the connect-retry ladder inside `RelayTarget.sendOnce`.
///
/// The relay is a local SwiftNIO "gate" server (127.0.0.1, ephemeral port):
/// its first N accepted connections are DRAINED and closed without any
/// response (a real pre-head connect-phase failure — AsyncHTTPClient
/// surfaces `HTTPClientError.remoteConnectionClosed`), later connections
/// serve a fixed 200; a hold mode parks the first connection and never
/// responds (a pre-head failure that is NOT connect-class). The
/// SigningClient chain runs against a URLProtocol mock with the same
/// synthetic fixtures as RelayTargetTests (duplicated here because that
/// suite's helpers are file-private). No real credential loads, and the one
/// non-localhost target is an RFC 6761 `.invalid` name that the resolver
/// rejects without touching the network.
@MainActor
@Suite(.serialized)
struct ConnectRetryTests {

    // MARK: - Fixtures (synthetic signing material, RelayTargetTests parity)

    private enum Fixtures {
        static let apiKeyId = "b5f4e6998889200000000000000088920"
        static let location = MintLocation(
            organizationId: "11111111-1111-1111-1111-111111111111",
            projectId: "22222222-2222-2222-2222-222222222222",
            apiKeyId: apiKeyId)
        /// Fixed 32-byte seed so signing is deterministic in-test.
        static let ed25519Seed = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })

        static func fakeJWT(payload: [String: Any]) -> String {
            let header = Base64URL.encode(Data(#"{"alg":"HS256","typ":"JWT"}"#.utf8))
            let body = Base64URL.encode(try! JSONSerialization.data(withJSONObject: payload))
            return [header, body, "c2lnbmF0dXJl"].joined(separator: ".")
        }

        static let bizJwt = fakeJWT(payload: ["sub": String(repeating: "biz", count: 40), "role": "session"])
        static let projectToken = fakeJWT(payload: [
            "token_use": "project_access",
            "api_key": apiKeyId,
            "exp": 4_102_444_800,
        ])

        /// Seals the fixed Ed25519 seed exactly like the server does:
        /// AES-256-GCM (AAD = apiKeyId, key = HKDF(token, "ed25519_priv"))
        /// over the base64 string of DER-PKCS8, as b64std(iv‖ct‖tag).
        static func sealPrivateKey(projectToken: String) throws -> String {
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
            guard let combined = sealed.combined else { throw NSError(domain: "Fixtures", code: 1) }
            return combined.base64EncodedString()
        }
    }

    // MARK: - Signing chain mock (URLProtocol)

    /// Serves the mint + handshake endpoints with synthetic responses.
    private final class SigningControl: @unchecked Sendable {
        func respond(to request: URLRequest) throws -> (Int, Data) {
            let path = request.url?.path ?? ""
            if path.contains("/access_tokens") {
                return (200, try Self.json([
                    "code": 200,
                    "data": ["accessToken": Fixtures.projectToken, "tokenType": "Bearer", "expiresIn": 36_000.0],
                ]))
            }
            if path.contains("/api/paas/c1f3a7e2/v2/client") {
                let cipher = try Fixtures.sealPrivateKey(projectToken: Fixtures.projectToken)
                return (200, try Self.json([
                    "code": 200,
                    "msg": "get sign key",
                    "data": ["privateCipher": cipher],
                    "success": true,
                ]))
            }
            throw NSError(domain: "SigningControl", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "unexpected path \(path)"])
        }

        private static func json(_ object: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: object)
        }
    }

    private final class SigningURLProtocolMock: URLProtocol {
        nonisolated(unsafe) static var control: SigningControl?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let control = Self.control else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            do {
                let (status, body) = try control.respond(to: request)
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

    // MARK: - Connect gate server (SwiftNIO, 127.0.0.1)

    /// Local gate server for the connect ladder. Per accepted connection it
    /// picks one behavior: `close` — decode the request, then close WITHOUT
    /// responding (draining first so the close is a clean FIN, not an RST
    /// from unread buffered bytes); `serve` — answer a fixed 200; `hold` —
    /// park the connection and never respond (the client's request deadline
    /// expires: a pre-head failure that is NOT connect-class). Connections
    /// are counted at accept time; served requests are recorded whole.
    private final class ConnectGateServer: @unchecked Sendable {
        enum Behavior { case close, hold, serve }

        struct RecordedRequest {
            let method: String
            let path: String
            let body: Data
        }

        private let lock = NSRecursiveLock()
        private let closeFirst: Int
        private let holdFirst: Bool
        private var _accepted = 0
        private var _served: [RecordedRequest] = []
        private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        private var serverChannel: (any Channel)?
        private var _channels: [any Channel] = []
        /// First candidate listen port (fixed, below the ephemeral range —
        /// see `start()`); instances advance on collision.
        private static let portBase = 24_183

        /// - closeFirst: the first N accepted connections close pre-response.
        /// - holdFirst: connection #1 parks instead (deadline-failure probe).
        init(closeFirst: Int, holdFirst: Bool = false) {
            self.closeFirst = closeFirst
            self.holdFirst = holdFirst
        }

        var acceptedConnections: Int {
            lock.lock(); defer { lock.unlock() }
            return _accepted
        }
        var servedRequests: [RecordedRequest] {
            lock.lock(); defer { lock.unlock() }
            return _served
        }

        /// Atomically counts the connection and picks its behavior.
        private func nextBehavior() -> Behavior {
            lock.lock(); defer { lock.unlock() }
            _accepted += 1
            if holdFirst && _accepted == 1 { return .hold }
            return _accepted <= closeFirst ? .close : .serve
        }

        func start() async throws -> Int {
            let server = self
            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    switch server.nextBehavior() {
                    case .hold:
                        // No pipeline: bytes drain into the void, nothing is
                        // ever answered, the connection stays open.
                        return channel.eventLoop.makeSucceededVoidFuture()
                    case .close:
                        return channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                            channel.pipeline.addHandler(CloseAfterRequestHandler(server: server))
                        }
                    case .serve:
                        return channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                            channel.pipeline.addHandler(ServeHandler(server: server))
                        }
                    }
                }
            // FIXED ports below the ephemeral range, NOT `:0`: macOS hands
            // out ephemeral ports near-sequentially, so a `:0` bind here can
            // steal exactly the takenPort+N a concurrently-running
            // RouterTests port scan expects free (observed: intermittent
            // proxyServerAdvancesToNextFreePortWhenConfiguredPortTaken
            // failures). Out here the gate servers cannot collide with any
            // `:0` allocation; collisions with something else just advance
            // the offset.
            var lastError: Error?
            for offset in 0..<16 {
                do {
                    let channel = try await bootstrap.bind(host: "127.0.0.1", port: Self.portBase + offset).get()
                    lock.lock()
                    serverChannel = channel
                    lock.unlock()
                    return channel.localAddress?.port ?? 0
                } catch {
                    lastError = error
                }
            }
            throw lastError ?? NSError(domain: "ConnectGateServer", code: 1)
        }

        func shutdown() async {
            lock.lock()
            let channels = _channels + [serverChannel].compactMap { $0 }
            serverChannel = nil
            _channels = []
            lock.unlock()
            for channel in channels {
                try? await channel.close().get()
            }
            try? await group.shutdownGracefully()
        }

        fileprivate func trackChannel(_ channel: any Channel) {
            lock.lock(); _channels.append(channel); lock.unlock()
        }
        fileprivate func record(_ request: RecordedRequest) {
            lock.lock(); _served.append(request); lock.unlock()
        }
    }

    /// Reads one request to completion, then closes without responding —
    /// draining first so the peer sees a clean FIN (RemoteConnectionClosed)
    /// rather than an RST from discarded buffered bytes.
    private final class CloseAfterRequestHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private let server: ConnectGateServer
        private var requestHead: HTTPRequestHead?
        private var body = Data()

        init(server: ConnectGateServer) {
            self.server = server
        }

        func handlerAdded(context: ChannelHandlerContext) {
            server.trackChannel(context.channel)
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let head):
                requestHead = head
                body = Data()
            case .body(let buffer):
                if let bytes = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes) {
                    body.append(bytes)
                }
            case .end:
                requestHead = nil
                body = Data()
                context.close(promise: nil)  // pre-response close: no head ever written
            }
        }
    }

    /// Answers any request with a fixed 200 JSON body.
    private final class ServeHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private let server: ConnectGateServer
        private var requestHead: HTTPRequestHead?
        private var body = Data()

        init(server: ConnectGateServer) {
            self.server = server
        }

        func handlerAdded(context: ChannelHandlerContext) {
            server.trackChannel(context.channel)
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let head):
                requestHead = head
                body = Data()
            case .body(let buffer):
                if let bytes = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes) {
                    body.append(bytes)
                }
            case .end:
                guard let head = requestHead else {
                    context.close(promise: nil)
                    return
                }
                server.record(ConnectGateServer.RecordedRequest(
                    method: head.method.rawValue, path: head.uri, body: body))
                requestHead = nil
                body = Data()

                let payload = Data(#"{"id":"msg_connect_ok"}"#.utf8)
                var responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
                responseHead.headers.add(name: "content-type", value: "application/json")
                responseHead.headers.add(name: "content-length", value: String(payload.count))
                let channel = context.channel
                channel.write(NIOAny(HTTPServerResponsePart.head(responseHead)), promise: nil)
                var buffer = channel.allocator.buffer(capacity: payload.count)
                buffer.writeBytes(payload)
                channel.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
                channel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: nil)
            }
        }
    }

    // MARK: - Stubs and helpers

    /// Connect-retry sleeper stub: records requested delays, sleeps nothing.
    private final class SleepRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _delays: [TimeInterval] = []
        var delays: [TimeInterval] {
            lock.lock(); defer { lock.unlock() }
            return _delays
        }
        func record(_ delay: TimeInterval) {
            lock.lock(); _delays.append(delay); lock.unlock()
        }
    }

    private func makeTempDirectory(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zgate-connectretry-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A SigningClient whose chain is mint + handshake against the URLProtocol
    /// mock (a seeded biz-session cache means z/login never runs).
    private func makeSigningClient(directory: URL, control: SigningControl) -> SigningClient {
        SigningURLProtocolMock.control = control
        var configuration = SigningClient.Configuration()
        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [SigningURLProtocolMock.self]
        configuration.session = URLSession(configuration: urlSessionConfiguration)
        configuration.storeLoader = { nil }
        configuration.initialLocation = Fixtures.location
        configuration.cacheURL = directory.appendingPathComponent("biz-session.cache")
        let cache = BizSessionCache(fileURL: configuration.cacheURL)
        try? cache.save(BizSession(
            bizJwt: Fixtures.bizJwt,
            acquiredAtMs: Int64(Date().timeIntervalSince1970 * 1000) - 1_000,
            location: Fixtures.location))
        return SigningClient(configuration: configuration)
    }

    private func makeRelayContext(control: SigningControl, directoryLabel: String) throws -> (
        RelayTarget.Context, URL
    ) {
        let directory = try makeTempDirectory(directoryLabel)
        let client = makeSigningClient(directory: directory, control: control)
        return (RelayTarget.Context(signingClient: client), directory)
    }

    private func routeTarget(
        baseURL: String, connectTimeoutSeconds: Int = 5, readTimeoutSeconds: Int = 10
    ) -> RoutingSnapshot.RouteTarget {
        RoutingSnapshot.RouteTarget(
            baseURL: baseURL,
            apiKey: "",
            vendorName: "ZCode Relay",
            vendorID: UUID(),
            targetModel: "GLM-5.3",
            isPassthrough: false,
            connectTimeoutSeconds: connectTimeoutSeconds,
            readTimeoutSeconds: readTimeoutSeconds,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .transparent,
            vendorKind: .relay)
    }

    private func relayRouteTarget(port: Int) -> RoutingSnapshot.RouteTarget {
        routeTarget(baseURL: "http://127.0.0.1:\(port)/api/v1/ultra-zai/anthropic")
    }

    /// The inbound client request head.
    private func postHead() -> HTTPRequestHead {
        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/messages")
        head.headers.add(name: "x-api-key", value: "client-key")
        head.headers.add(name: "anthropic-version", value: "2023-06-01")
        return head
    }

    private func requestBody() -> Data {
        let json: [String: Any] = [
            "model": "glm-5.3",
            "max_tokens": 128,
            "stream": true,
            "system": "You are helpful.",
            "messages": [["role": "user", "content": "héllo"]],
        ]
        return (try! JSONSerialization.data(withJSONObject: json))
    }

    private func makeHTTPClient() -> HTTPClient {
        HTTPClient(eventLoopGroupProvider: .createNew)
    }

    // MARK: - Classifier (vendored-type table)

    @Test func connectClassifierMatchesConnectPhaseOnly() {
        // Connect-class pre-head surfaces (verified against the vendored
        // AsyncHTTPClient/NIO checkouts AND observed live on the NIOTS
        // transport HTTPClient's default macOS group uses — see
        // isConnectPhaseFailure's doc).
        // AsyncHTTPClient's own connect-phase errors:
        #expect(RelayTarget.isConnectPhaseFailure(HTTPClientError.connectTimeout))
        #expect(RelayTarget.isConnectPhaseFailure(HTTPClientError.remoteConnectionClosed))
        #expect(RelayTarget.isConnectPhaseFailure(HTTPClientError.getConnectionFromPoolTimeout))
        // Raw NIO channel errors (NIO-socket transport spelling):
        #expect(RelayTarget.isConnectPhaseFailure(ChannelError.connectTimeout(.seconds(1))))
        #expect(RelayTarget.isConnectPhaseFailure(ChannelError.ioOnClosedChannel))
        // Network.framework transport (the default group on macOS):
        // DNS resolution failure, and the connect-establishment errno set
        // NWErrorHandler wraps into NWPOSIXError.
        #expect(RelayTarget.isConnectPhaseFailure(NWError.dns(65_554)))
        #expect(RelayTarget.isConnectPhaseFailure(HTTPClient.NWPOSIXError(.ECONNREFUSED, reason: "refused")))
        #expect(RelayTarget.isConnectPhaseFailure(HTTPClient.NWPOSIXError(.ETIMEDOUT, reason: "timeout")))
        #expect(RelayTarget.isConnectPhaseFailure(HTTPClient.NWPOSIXError(.ECONNRESET, reason: "reset")))
        #expect(RelayTarget.isConnectPhaseFailure(HTTPClient.NWPOSIXError(.ENETUNREACH, reason: "net")))
        #expect(RelayTarget.isConnectPhaseFailure(HTTPClient.NWPOSIXError(.EHOSTUNREACH, reason: "host")))
        // Pre-head failures that are NOT connect-class — immediate, no ladder:
        // waiting for a response is not connecting.
        #expect(!RelayTarget.isConnectPhaseFailure(HTTPClientError.readTimeout))
        #expect(!RelayTarget.isConnectPhaseFailure(HTTPClientError.deadlineExceeded))
        #expect(!RelayTarget.isConnectPhaseFailure(HTTPClientError.cancelled))
        // TLS handshake failures and write-phase errno are not connect-class.
        #expect(!RelayTarget.isConnectPhaseFailure(HTTPClient.NWPOSIXError(.EPIPE, reason: "broken pipe")))
        #expect(!RelayTarget.isConnectPhaseFailure(NWError.tls(-9_808)))
        // Raw errno wraps on the NIO-socket path are not connect-class
        // either (the hostname path wraps them in NIOConnectionError, which
        // IS matched; the NIOTS path wraps them in NWPOSIXError, above).
        #expect(!RelayTarget.isConnectPhaseFailure(IOError(errnoCode: 61, reason: "connection refused")))
        #expect(!RelayTarget.isConnectPhaseFailure(RelayTarget.RelayTargetError.signingMaterialUnavailable("x")))
    }

    // MARK: - Ladder behavior (real sockets)

    @Test func closeTwiceThenServeSucceedsOnExactlyThirdAttempt() async throws {
        let relay = ConnectGateServer(closeFirst: 2)
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let (context, directory) = try makeRelayContext(control: control, directoryLabel: "retry3")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sleeper = SleepRecorder()
        context.connectRetrySleeper = { delay in sleeper.record(delay) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }
        let body = requestBody()

        let outcome = await RelayTarget.execute(
            head: postHead(), bodyData: body,
            target: relayRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-connect3")

        guard case .responded(let response) = outcome else {
            Issue.record("expected responded, got \(outcome)")
            return
        }
        #expect(response.status == .ok)
        // Two pre-head closes + the serving connection = exactly 3 attempts.
        #expect(relay.acceptedConnections == 3)
        // Backoff cadence: 500 ms before attempt 2, 1000 ms before attempt 3.
        #expect(sleeper.delays == [0.5, 1.0])
        // The final attempt sent a complete, well-formed request — every
        // attempt builds a fresh one over the reusable Data wire body.
        #expect(relay.servedRequests.count == 1)
        #expect(relay.servedRequests[0].body
            == RelayTarget.wireBody(bodyData: body, target: relayRouteTarget(port: port)))
    }

    @Test func alwaysCloseExhaustsLadderToTransportFailedAfterThreeAttempts() async throws {
        let relay = ConnectGateServer(closeFirst: .max)
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let (context, directory) = try makeRelayContext(control: control, directoryLabel: "closer")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sleeper = SleepRecorder()
        context.connectRetrySleeper = { delay in sleeper.record(delay) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let outcome = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(),
            target: relayRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-closer")

        guard case .transportFailed = outcome else {
            Issue.record("expected transportFailed, got \(outcome)")
            return
        }
        // Bounded: three connect attempts total, then the terminal outcome
        // (Task 7's degraded admission picks up downstream — unchanged).
        #expect(relay.acceptedConnections == 3)
        #expect(sleeper.delays == [0.5, 1.0])
        #expect(relay.servedRequests.isEmpty)
    }

    @Test func nonConnectPreHeadFailureFailsImmediatelyWithoutRetry() async throws {
        // A parked connection never answers: the request deadline expires
        // waiting for the response — pre-head, but NOT connect-class, so the
        // ladder must not run (one connection, no backoff).
        let relay = ConnectGateServer(closeFirst: 0, holdFirst: true)
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let (context, directory) = try makeRelayContext(control: control, directoryLabel: "hold")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sleeper = SleepRecorder()
        context.connectRetrySleeper = { delay in sleeper.record(delay) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let outcome = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(),
            target: routeTarget(
                baseURL: "http://127.0.0.1:\(port)/api/v1/ultra-zai/anthropic",
                connectTimeoutSeconds: 1, readTimeoutSeconds: 1),
            httpClient: httpClient,
            context: context, requestID: "t-hold")

        guard case .transportFailed = outcome else {
            Issue.record("expected transportFailed, got \(outcome)")
            return
        }
        #expect(relay.acceptedConnections == 1)
        #expect(sleeper.delays.isEmpty)
    }

    @Test func unresolvableHostRetriesThroughLadderThenFails() async throws {
        // The production relay target is a HOSTNAME, and on this stack
        // `HTTPClient(eventLoopGroupProvider: .createNew)` runs over
        // Network.framework: DNS failures surface from `execute` as
        // `NWError.dns` (observed: -65554 NoSuchRecord) — connect-class,
        // so the ladder runs. `.invalid` is reserved (RFC 6761): the
        // resolver rejects it without real network I/O. Network.framework
        // retries resolution internally for several seconds; the per-attempt
        // deadline then tears the connect down and the DNS error — not a
        // `deadlineExceeded` — is what surfaces (observed twice).
        let control = SigningControl()
        let (context, directory) = try makeRelayContext(control: control, directoryLabel: "dnsfail")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sleeper = SleepRecorder()
        context.connectRetrySleeper = { delay in sleeper.record(delay) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let outcome = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(),
            target: routeTarget(
                baseURL: "http://zgate-connect-probe.invalid/api/v1/ultra-zai/anthropic",
                connectTimeoutSeconds: 6, readTimeoutSeconds: 6),
            httpClient: httpClient,
            context: context, requestID: "t-dnsfail")

        guard case .transportFailed = outcome else {
            Issue.record("expected transportFailed, got \(outcome)")
            return
        }
        #expect(sleeper.delays == [0.5, 1.0])
    }
}

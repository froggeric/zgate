import AsyncHTTPClient
import CryptoKit
import Foundation
import NIOCore
import NIOEmbedded
import NIOFoundationCompat
import NIOHTTP1
import NIOPosix
import Testing
@testable import ZGate

/// Offline tests for `RelayTarget` — the signed relay forward path.
///
/// The relay is a local SwiftNIO HTTP server (127.0.0.1, ephemeral port)
/// serving scripted responses; the SigningClient chain runs against a
/// `URLProtocol` mock with synthetic fixtures (synthetic JWTs, a synthetic
/// Ed25519 seed sealed with the same HKDF/AES-GCM scheme in-test). No real
/// network and no real credential ever loads. Header values are asserted for
/// shape and binding only — token equality checks compare against the
/// synthetic session token, never a secret.
@MainActor
@Suite(.serialized)
struct RelayTargetTests {

    // MARK: - Fixtures

    private enum Fixtures {
        static let apiKeyId = "b5f4e6998889200000000000000088920"
        static let location = MintLocation(
            organizationId: "11111111-1111-1111-1111-111111111111",
            projectId: "22222222-2222-2222-2222-222222222222",
            apiKeyId: apiKeyId)
        /// Fixed 32-byte seed so X-Client-Sig values are verifiable in-test.
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
    /// `failHandshakeFromCount` makes handshake responses fail (business code
    /// 401) from the Nth call on — 0 fails every handshake.
    private final class SigningControl: @unchecked Sendable {
        private let lock = NSLock()
        private var _mintCount = 0
        private var _handshakeCount = 0
        var failHandshakeFromCount: Int?

        var mintCount: Int {
            lock.lock(); defer { lock.unlock() }
            return _mintCount
        }
        var handshakeCount: Int {
            lock.lock(); defer { lock.unlock() }
            return _handshakeCount
        }

        func respond(to request: URLRequest) throws -> (Int, Data) {
            let path = request.url?.path ?? ""
            if path.contains("/access_tokens") {
                lock.lock(); _mintCount += 1; lock.unlock()
                return (200, try Self.json([
                    "code": 200,
                    "data": ["accessToken": Fixtures.projectToken, "tokenType": "Bearer", "expiresIn": 36_000.0],
                ]))
            }
            if path.contains("/api/paas/c1f3a7e2/v2/client") {
                lock.lock(); _handshakeCount += 1; lock.unlock()
                if let failFrom = failHandshakeFromCount {
                    lock.lock(); let count = _handshakeCount; lock.unlock()
                    if count > failFrom {
                        return (200, try Self.json(["code": 401, "msg": "signature mismatch"]))
                    }
                }
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

    // MARK: - Mock relay server (SwiftNIO, 127.0.0.1)

    /// Local HTTP server playing the relay (and, for fallback tests, any
    /// plain vendor): records requests, serves scripted responses, counts
    /// mid-stream client disconnects.
    private final class MockRelayServer: @unchecked Sendable {
        struct RecordedRequest {
            let method: String
            let path: String
            let headers: [String: String]
            let body: Data
        }

        struct Script {
            var status: Int = 200
            var headers: [String: String] = ["content-type": "application/json"]
            var chunks: [Data] = []
            var chunkDelayMs: Int = 0
            var holdOpen = false

            static func json(_ object: [String: Any], status: Int = 200) -> Script {
                let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
                return Script(status: status, chunks: [data])
            }
        }

        private let lock = NSRecursiveLock()
        private var scripts: [Script]
        private var _requests: [RecordedRequest] = []
        private var _abortedStreams = 0
        private var _openResponses = 0
        private var _channels: [any Channel] = []
        private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        private var serverChannel: (any Channel)?

        init(scripts: [Script] = []) {
            self.scripts = scripts
        }

        var requests: [RecordedRequest] {
            lock.lock(); defer { lock.unlock() }
            return _requests
        }
        var requestCount: Int {
            lock.lock(); defer { lock.unlock() }
            return _requests.count
        }
        var abortedStreams: Int {
            lock.lock(); defer { lock.unlock() }
            return _abortedStreams
        }

        func start() async throws -> Int {
            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                        channel.pipeline.addHandler(MockRelayHandler(server: self))
                    }
                }
            let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
            lock.lock()
            serverChannel = channel
            lock.unlock()
            return channel.localAddress?.port ?? 0
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

        // Called from the event loop / response tasks.
        fileprivate func takeScript() -> Script {
            lock.lock(); defer { lock.unlock() }
            if !scripts.isEmpty { return scripts.removeFirst() }
            return .json(["ok": true])
        }
        fileprivate func record(_ request: RecordedRequest) {
            lock.lock(); _requests.append(request); lock.unlock()
        }
        fileprivate func trackChannel(_ channel: any Channel) {
            lock.lock(); _channels.append(channel); lock.unlock()
        }
        fileprivate func noteResponseOpen() {
            lock.lock(); _openResponses += 1; lock.unlock()
        }
        fileprivate func noteResponseClosed() {
            lock.lock(); _openResponses = max(0, _openResponses - 1); lock.unlock()
        }
        /// A connection dropped while a (held-open) response was streaming.
        fileprivate func noteClientGone() {
            lock.lock()
            if _openResponses > 0 {
                _abortedStreams += 1
                _openResponses -= 1
            }
            lock.unlock()
        }
    }

    private final class MockRelayHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private let server: MockRelayServer
        private var requestHead: HTTPRequestHead?
        private var body = Data()

        init(server: MockRelayServer) {
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
                var headers: [String: String] = [:]
                for (name, value) in head.headers {
                    headers[name.lowercased()] = value
                }
                server.record(MockRelayServer.RecordedRequest(
                    method: head.method.rawValue,
                    path: head.uri,
                    headers: headers,
                    body: body))
                respond(context: context, script: server.takeScript())
                requestHead = nil
                body = Data()
            }
        }

        func channelInactive(context: ChannelHandlerContext) {
            server.noteClientGone()
            context.fireChannelInactive()
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            server.noteClientGone()
            context.close(promise: nil)
        }

        private func respond(context: ChannelHandlerContext, script: MockRelayServer.Script) {
            let channel = context.channel
            if script.holdOpen { server.noteResponseOpen() }
            Task {
                var head = HTTPResponseHead(
                    version: .http1_1,
                    status: HTTPResponseStatus(statusCode: script.status))
                for (name, value) in script.headers {
                    head.headers.add(name: name, value: value)
                }
                // Single-shot bodies get a content-length; chunked streams
                // (multiple chunks / delays) stream without one.
                if !script.holdOpen && script.chunks.count <= 1 {
                    let total = script.chunks.reduce(0) { $0 + $1.count }
                    head.headers.replaceOrAdd(name: "content-length", value: String(total))
                }
                channel.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
                for chunk in script.chunks {
                    var buffer = channel.allocator.buffer(capacity: chunk.count)
                    buffer.writeBytes(chunk)
                    channel.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
                    channel.flush()
                    if script.chunkDelayMs > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(script.chunkDelayMs) * 1_000_000)
                    }
                }
                if script.holdOpen {
                    channel.flush()
                } else {
                    channel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: nil)
                    server.noteResponseClosed()
                }
            }
        }
    }

    /// Collects raw bytes from any number of inbound connections — the far
    /// end of the "proxy client" socket in the disconnect test.
    private final class ByteCollectorServer: @unchecked Sendable {
        private let lock = NSLock()
        private var _received = Data()
        private var _channels: [any Channel] = []
        private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        private var serverChannel: (any Channel)?

        var receivedCount: Int {
            lock.lock(); defer { lock.unlock() }
            return _received.count
        }

        func start() async throws -> Int {
            let bootstrap = ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(ByteCollectorHandler(server: self))
                }
            let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
            lock.lock()
            serverChannel = channel
            lock.unlock()
            return channel.localAddress?.port ?? 0
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

        fileprivate func record(_ data: Data) {
            lock.lock(); _received.append(data); lock.unlock()
        }
        fileprivate func trackChannel(_ channel: any Channel) {
            lock.lock(); _channels.append(channel); lock.unlock()
        }
    }

    private final class ByteCollectorHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer

        private let server: ByteCollectorServer

        init(server: ByteCollectorServer) {
            self.server = server
        }

        func handlerAdded(context: ChannelHandlerContext) {
            server.trackChannel(context.channel)
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            if let bytes = buffer.readData(length: buffer.readableBytes) {
                server.record(bytes)
            }
        }
    }

    // MARK: - Helpers

    private func makeTempDirectory(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zgate-relaytarget-\(label)-\(UUID().uuidString)", isDirectory: true)
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
        let cacheURL = directory.appendingPathComponent("biz-session.cache")
        configuration.cacheURL = cacheURL
        let cache = BizSessionCache(fileURL: cacheURL)
        try? cache.save(BizSession(
            bizJwt: Fixtures.bizJwt,
            acquiredAtMs: Int64(Date().timeIntervalSince1970 * 1000) - 1_000,
            location: Fixtures.location))
        return SigningClient(configuration: configuration)
    }

    private func makeRelayContext(
        control: SigningControl, events: CredentialEventChannel? = nil, directoryLabel: String
    ) throws -> (RelayTarget.Context, URL) {
        let directory = try makeTempDirectory(directoryLabel)
        let client = makeSigningClient(directory: directory, control: control)
        return (RelayTarget.Context(signingClient: client, credentialEvents: events), directory)
    }

    private func relayRouteTarget(port: Int, targetModel: String? = "glm-5.3") -> RoutingSnapshot.RouteTarget {
        RoutingSnapshot.RouteTarget(
            baseURL: "http://127.0.0.1:\(port)/api/v1/ultra-zai/anthropic",
            apiKey: "",
            vendorName: "ZCode Relay",
            vendorID: UUID(),
            targetModel: targetModel,
            isPassthrough: false,
            connectTimeoutSeconds: 5,
            readTimeoutSeconds: 10,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .transparent,
            vendorKind: .relay)
    }

    private func postHead(uri: String = "/v1/messages") -> HTTPRequestHead {
        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: uri)
        head.headers.add(name: "x-api-key", value: "client-key")
        head.headers.add(name: "anthropic-version", value: "2023-06-01")
        return head
    }

    private func requestBody(model: String) -> Data {
        let json: [String: Any] = [
            "model": model,
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

    private func waitUntil(
        timeout: TimeInterval = 5, _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// Reads every outbound part of an EmbeddedChannel: (head, concatenated
    /// body bytes, sawEnd).
    private func drainClientResponse(_ channel: EmbeddedChannel) throws -> (HTTPResponseHead, Data, Bool) {
        var head: HTTPResponseHead?
        var body = Data()
        var sawEnd = false
        while let part = try channel.readOutbound(as: HTTPServerResponsePart.self) {
            switch part {
            case .head(let h): head = h
            case .body(.byteBuffer(let buffer)):
                if let bytes = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes) {
                    body.append(bytes)
                }
            case .body(.fileRegion): break  // never produced on EmbeddedChannel
            case .end: sawEnd = true
            }
        }
        return (try #require(head), body, sawEnd)
    }

    private func finishChannel(_ channel: EmbeddedChannel) {
        _ = try? channel.finish()
    }

    // MARK: - Environment identity (AC: x-os-version = Darwin kernel release)

    /// The machine's live `uname(2)` `release` — computed independently of
    /// `RelayTarget.osVersion` so header assertions cross-check, not mirror.
    private static var liveUnameRelease: String {
        var systemInfo = utsname()
        precondition(uname(&systemInfo) == 0, "uname(2) does not fail on Darwin")
        return withUnsafeBytes(of: systemInfo.release) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    @Test func osVersionIsDarwinKernelReleaseNotProductVersion() {
        // Genuine zcode sends node's os.release() — the uname(2) kernel
        // release ("27.2.0" on this machine), NOT ProcessInfo's macOS
        // product version ("26.2.0" here). Identity-header fidelity is the
        // app's premise, so pin value and format.
        let value = RelayTarget.osVersion
        #expect(value == Self.liveUnameRelease)
        #expect(value =~ "^\\d+\\.\\d+\\.\\d+$")
    }

    // MARK: - Model canonicalization (zbridge mapModel parity)

    @Test func canonicalModelMirrorsZbridgeMap() {
        #expect(RelayTarget.canonicalModel("glm-5.3") == "GLM-5.3")
        #expect(RelayTarget.canonicalModel("glm-5.3[1m]") == "GLM-5.3")
        #expect(RelayTarget.canonicalModel("GLM-5.3") == "GLM-5.3")
        #expect(RelayTarget.canonicalModel("glm-5.3-flash") == "GLM-5.3-Flash")
        // Flash wins over the family map (zbridge checks flash first).
        #expect(RelayTarget.canonicalModel("glm-4-FlashX-250414") == "GLM-5.3-Flash")
        #expect(RelayTarget.canonicalModel("GLM-4.6") == "GLM-4.6")
        #expect(RelayTarget.canonicalModel("glm-99-x") == "GLM-5.3")  // glm-family unknown → main
        #expect(RelayTarget.canonicalModel("some-other-model") == "GLM-5.3-Flash")  // unknown → flash
        #expect(RelayTarget.canonicalModel("  GLM-5.3  ") == "GLM-5.3")
    }

    // MARK: - Outgoing header set (AC: fixture statics byte-identical, wire order, volatile shapes)

    @Test func outgoingHeadersMatchFixtureStaticsAndVolatileShapes() async throws {
        let relay = MockRelayServer(scripts: [.json(["id": "msg_1"])])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let (context, directory) = try makeRelayContext(control: control, directoryLabel: "headers")
        defer { try? FileManager.default.removeItem(at: directory) }

        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let outcome = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(model: "glm-5.3[1m]"),
            target: relayRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-headers")
        guard case .responded(let response) = outcome else {
            Issue.record("expected responded, got \(outcome)")
            return
        }
        #expect(response.status == .ok)

        let request = try #require(relay.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/v1/ultra-zai/anthropic/v1/messages")

        let headers = request.headers
        // Static identity set — byte-identical to the regenerated CLI-face
        // fixture (`v3-relay-request.json`, 27 headers in wire order).
        #expect(headers["user-agent"] == "ZCode/0.17.1 ai-sdk/anthropic/3.0.81")
        #expect(headers["anthropic-beta"] == "mid-conversation-system-2026-04-07")
        #expect(headers["anthropic-version"] == "2023-06-01")
        #expect(headers["content-type"] == "application/json")
        #expect(headers["http-referer"] == "https://zcode.z.ai")
        #expect(headers["x-title"] == "Z Code@cli")
        #expect(headers["x-zcode-agent"] == "glm")
        #expect(headers["x-zcode-app-version"] == "0.17.1")
        #expect(headers["x-zcode-query-source"] == "main_turn")
        #expect(headers["x-zcode-session-type"] == "main")
        #expect(headers["x-client-language"] == "en-US")
        #expect(headers["x-client-version"] == "0.17.1")
        #expect(headers["x-os-category"] == "macos")
        #expect(headers["x-app-id"] == "zcode")
        // Dropped from the CLI face: the CLI sends release-channel only when
        // one is env-provided; session-features is empty and not sent.
        #expect(headers["x-release-channel"] == nil)
        #expect(headers["x-zcode-session-features"] == nil)
        // Dynamic-but-known environment identity.
        #expect(headers["x-client-timezone"] == TimeZone.current.identifier)
        #expect(headers["x-platform"] == "darwin-arm64")
        // x-os-version: the Darwin kernel release (node os.release() =
        // uname(2)), not the macOS product version — cross-checked against
        // a live utsname call made here in the test.
        let osVersionHeader = try #require(headers["x-os-version"])
        #expect(osVersionHeader == Self.liveUnameRelease)
        #expect(osVersionHeader =~ "^\\d+\\.\\d+\\.\\d+$")

        // Auth: the synthetic session token in both headers.
        let session = try await context.signingClient.ensureSession()
        #expect(headers["authorization"] == "Bearer \(session.projectToken)")
        #expect(headers["x-api-key"] == session.projectToken)

        // Volatile quartet: shape + binding.
        let ts = try #require(headers["x-client-ts"])
        #expect(ts.count == 13)
        #expect(ts.allSatisfy { $0.isNumber })
        let tsValue = Int64(ts)!
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        #expect(abs(tsValue - nowMs) < 10_000)

        let nonce = try #require(headers["x-client-nonce"])
        #expect(nonce.count == 32)
        #expect(nonce.allSatisfy { $0.isHexDigit && ($0.isLowercase || $0.isNumber) })

        let pow = try #require(headers["x-client-pow"])
        #expect(pow.count == 32)
        #expect(pow.allSatisfy { $0.isHexDigit && ($0.isLowercase || $0.isNumber) })
        // Bound to this request's identity, with the leading-zero proof.
        #expect(CryptoCore.verifyPow(
            apiKeyId: session.apiKeyId, appId: "zcode", sessionId: context.sessionID,
            ts: ts, pow: pow))

        let sig = try #require(headers["x-client-sig"])
        #expect(sig.count == 88)
        let sigBytes = try #require(Data(base64Encoded: sig))
        #expect(sigBytes.count == 64)
        let publicKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Fixtures.ed25519Seed).publicKey
        let message = CryptoCore.requestSigMessage(
            apiKeyId: session.apiKeyId, ts: ts, version: "0.17.1",
            sessionId: context.sessionID, nonce: nonce)
        #expect(publicKey.isValidSignature(sigBytes, for: Data(message.utf8)))

        // Per-request UUIDs + the stable per-process session id.
        for key in ["x-query-id", "x-request-id", "x-zcode-trace-id"] {
            #expect(UUID(uuidString: headers[key] ?? "") != nil, "\(key) should be a UUID")
        }
        #expect(headers["x-session-id"] == context.sessionID)
        #expect(UUID(uuidString: context.sessionID) != nil)
    }

    /// The exact CLI 0.17.1 wire order (undici/HTTP 1.1 is order-preserving —
    /// this pins the real insertion sequence, not a sorted set). The signer's
    /// static block (`x-client-ts/-version/-sig/-nonce`, `x-app-id`,
    /// `x-client-pow`) is gated on `signed` exactly like the official
    /// `sendSigned` path; `x-api-key` stays this wave (Task 9 probe decides).
    @Test func relayHeadersMatchCLIWireOrder() throws {
        let session = SigningSession(
            projectToken: Fixtures.projectToken,
            apiKeyId: Fixtures.apiKeyId,
            privateKey: try Curve25519.Signing.PrivateKey(rawRepresentation: Fixtures.ed25519Seed),
            expiresAtMs: .max,
            marginRelaxed: false)

        // UA is built from the version, never a frozen literal.
        #expect(RelayTarget.userAgent(for: "0.17.1") == "ZCode/0.17.1 ai-sdk/anthropic/3.0.81")
        #expect(RelayTarget.userAgent(for: "9.9.9") == "ZCode/9.9.9 ai-sdk/anthropic/3.0.81")

        let identity = [
            "content-type", "anthropic-version", "authorization", "http-referer",
            "user-agent", "x-zcode-app-version", "x-title", "x-client-language",
            "x-client-timezone", "x-zcode-agent", "x-platform", "x-os-category",
            "x-os-version", "x-request-id", "x-zcode-session-type", "x-zcode-trace-id",
            "x-query-id", "x-zcode-query-source", "x-session-id", "anthropic-beta",
        ]
        let signer = [
            "x-client-ts", "x-client-version", "x-client-sig", "x-client-nonce",
            "x-app-id", "x-client-pow",
        ]

        let signed = try RelayTarget.relayHeaders(
            session: session, signed: true, sessionID: "sid")
        #expect(signed.map { $0.name } == identity + signer + ["x-api-key"])
        #expect(signed["user-agent"] == ["ZCode/0.17.1 ai-sdk/anthropic/3.0.81"])

        // Unsigned fail-open attempt: identity + auth only — the signer block
        // is the CLI signer's, so it never rides an unsigned request.
        let unsigned = try RelayTarget.relayHeaders(
            session: session, signed: false, sessionID: "sid")
        #expect(unsigned.map { $0.name } == identity + ["x-api-key"])

        // The Task 1 routing header rides immediately after `authorization`
        // (it is ZGate's, not part of the CLI static face).
        let routed = try RelayTarget.relayHeaders(
            session: session, signed: true, sessionID: "sid",
            zcodeAuthorization: "synthetic-zcode-jwt")
        let routedNames = routed.map { $0.name }
        #expect(routedNames == {
            var names = identity
            names.insert("x-zcode-authorization", at: names.firstIndex(of: "authorization")! + 1)
            return names
        }() + signer + ["x-api-key"])
    }

    @Test func sessionIDStaysStableAcrossRequests() async throws {
        let relay = MockRelayServer(scripts: [])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let (context, directory) = try makeRelayContext(control: control, directoryLabel: "sessid")
        defer { try? FileManager.default.removeItem(at: directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        for _ in 0..<2 {
            let outcome = await RelayTarget.execute(
                head: postHead(), bodyData: requestBody(model: "glm-5.3"),
                target: relayRouteTarget(port: port), httpClient: httpClient,
                context: context, requestID: "t-sessid")
            guard case .responded = outcome else {
                Issue.record("expected responded, got \(outcome)")
                return
            }
        }
        #expect(relay.requestCount == 2)
        #expect(relay.requests[0].headers["x-session-id"] == relay.requests[1].headers["x-session-id"])
    }

    // MARK: - Body rewrite (AC: model rewritten, rest byte-unchanged)

    @Test func bodyModelRewrittenToCanonicalTargetRestUnchanged() async throws {
        let relay = MockRelayServer(scripts: [])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let (context, directory) = try makeRelayContext(control: control, directoryLabel: "body")
        defer { try? FileManager.default.removeItem(at: directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let original = requestBody(model: "glm-5.3[1m]")
        let outcome = await RelayTarget.execute(
            head: postHead(), bodyData: original,
            target: relayRouteTarget(port: port, targetModel: "glm-5.3"),
            httpClient: httpClient, context: context, requestID: "t-body")
        guard case .responded = outcome else {
            Issue.record("expected responded, got \(outcome)")
            return
        }

        let sent = try #require(relay.requests.first).body
        // Canonical round-trip: everything except `model` deep-equal, model = target.
        var originalJSON = try #require(try JSONSerialization.jsonObject(with: original) as? [String: Any])
        var sentJSON = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        #expect(sentJSON["model"] as? String == "GLM-5.3")
        originalJSON.removeValue(forKey: "model")
        sentJSON.removeValue(forKey: "model")
        let reencodedOriginal = try JSONSerialization.data(withJSONObject: originalJSON, options: [.sortedKeys])
        let reencodedSent = try JSONSerialization.data(withJSONObject: sentJSON, options: [.sortedKeys])
        #expect(reencodedOriginal == reencodedSent)
    }

    @Test func noTargetModelCanonicalizesBodyModelInPlace() async throws {
        let relay = MockRelayServer(scripts: [])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let (context, directory) = try makeRelayContext(control: control, directoryLabel: "body2")
        defer { try? FileManager.default.removeItem(at: directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let outcome = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(model: "Haiku-Flash-Model"),
            target: relayRouteTarget(port: port, targetModel: nil),
            httpClient: httpClient, context: context, requestID: "t-body2")
        guard case .responded = outcome else {
            Issue.record("expected responded, got \(outcome)")
            return
        }
        let sentJSON = try #require(
            try JSONSerialization.jsonObject(with: relay.requests.first!.body) as? [String: Any])
        #expect(sentJSON["model"] as? String == "GLM-5.3-Flash")
    }

    // MARK: - SSE passthrough (AC: byte-identical stream, split mid-JSON survives)

    @Test func ssePassthroughStreamsByteIdenticalIncludingSplitMidJSONEvent() async throws {
        let chunks: [Data] = [
            Data("event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\"}}\n\n".utf8),
            Data("event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0}\n\n".utf8),
            Data("event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"héllo\"}}\n\n".utf8),
            // One SSE event split across two chunks mid-JSON.
            Data("event: content_block_delta\ndata: {\"type\":\"content_block_del".utf8),
            Data("ta\",\"delta\":{\"text\":\" wörld\"}}\n\n".utf8),
            Data("event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n".utf8),
        ]
        let relay = MockRelayServer(scripts: [
            MockRelayServer.Script(
                status: 200,
                headers: ["content-type": "text/event-stream"],
                chunks: chunks,
                chunkDelayMs: 30)
        ])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let (context, directory) = try makeRelayContext(control: control, directoryLabel: "sse")
        defer { try? FileManager.default.removeItem(at: directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let outcome = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(model: "glm-5.3"),
            target: relayRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-sse")
        guard case .responded(let response) = outcome else {
            Issue.record("expected responded, got \(outcome)")
            return
        }
        #expect(response.status == .ok)

        let client = EmbeddedChannel()
        _ = await ResponseRelay.relay(upstreamResponse: response, to: client, requestID: "t-sse")
        let (head, body, sawEnd) = try drainClientResponse(client)
        #expect(head.status == .ok)
        #expect(head.headers["content-type"] == ["text/event-stream"])
        #expect(sawEnd)
        let expected = chunks.reduce(Data()) { $0 + $1 }
        #expect(body == expected)
        finishChannel(client)
    }

    @Test func midStreamClientDisconnectAbortsUpstream() async throws {
        let relay = MockRelayServer(scripts: [
            MockRelayServer.Script(
                status: 200,
                headers: ["content-type": "text/event-stream"],
                chunks: [
                    Data("event: message_start\ndata: {\"type\":\"message_start\"}\n\n".utf8),
                    Data("event: content_block_delta\ndata: {\"type\":\"content_block_delta\"}\n\n".utf8),
                    Data("event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n".utf8),
                ],
                chunkDelayMs: 120,
                holdOpen: true)
        ])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let (context, _) = try makeRelayContext(control: control, directoryLabel: "abort")
        let fixture = try makeForwardFixture(relayPort: port, backupPort: nil)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        // The proxy client is a REAL socket: EmbeddedChannel succeeds writes
        // after close, so only a genuine connection exhibits the disconnect
        // (channel close → stream task cancelled → upstream aborted).
        let collector = ByteCollectorServer()
        let collectorPort = try await collector.start()
        defer { Task { await collector.shutdown() } }
        let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await clientGroup.shutdownGracefully() } }
        let clientChannel = try await ClientBootstrap(group: clientGroup)
            .channelInitializer { channel in
                channel.pipeline.addHandler(HTTPResponseEncoder())
            }
            .connect(host: "127.0.0.1", port: collectorPort).get()

        let forwardTask = Task {
            await forward(fixture, httpClient: httpClient, context: context, channel: clientChannel)
        }

        // Wait until the first SSE chunk reached the (proxy) client, then
        // drop the client connection mid-stream.
        let firstChunkArrived = await waitUntil(timeout: 5) { collector.receivedCount > 0 }
        #expect(firstChunkArrived)
        try await clientChannel.close().get()
        _ = await forwardTask.value

        // The cancelled upstream body tears the relay connection down: the
        // mock saw the close while its response was still open.
        let sawClose = await waitUntil(timeout: 5) { relay.abortedStreams >= 1 }
        #expect(sawClose)
        #expect(relay.abortedStreams == 1)
    }

    // MARK: - Cold start (AC: never unsigned; 502 with clear body)

    @Test func coldStartHandshakeFailureNeverSendsUnsigned() async throws {
        let relay = MockRelayServer(scripts: [])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        control.failHandshakeFromCount = 0  // every handshake fails
        let (context, directory) = try makeRelayContext(control: control, directoryLabel: "cold")
        defer { try? FileManager.default.removeItem(at: directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let outcome = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(model: "glm-5.3"),
            target: relayRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-cold")
        guard case .signingUnavailable(let reason) = outcome else {
            Issue.record("expected signingUnavailable, got \(outcome)")
            return
        }
        #expect(reason.localizedCaseInsensitiveContains("handshake"))
        // The request never left the process unsigned — the relay saw nothing.
        #expect(relay.requestCount == 0)
    }

    // MARK: - 401 policy (AC: reject ladder, fail-open gate, expired event)

    @Test func firstRejectPassesThroughWithoutRetryOrLadder() async throws {
        let relay = MockRelayServer(scripts: [.json(
            ["type": "error", "error": ["type": "authentication_error", "message": "invalid signature"]],
            status: 401)])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let events = CredentialEventChannel()
        let (context, directory) = try makeRelayContext(control: control, events: events, directoryLabel: "first401")
        defer { try? FileManager.default.removeItem(at: directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let outcome = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(model: "glm-5.3"),
            target: relayRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-first401")
        guard case .responded(let response) = outcome else {
            Issue.record("expected responded (passthrough), got \(outcome)")
            return
        }
        // The true relay 401 streams back with its body intact.
        #expect(Int(response.status.code) == 401)
        var body = Data()
        for try await chunk in response.body {
            if let bytes = chunk.getData(at: chunk.readerIndex, length: chunk.readableBytes) {
                body.append(bytes)
            }
        }
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["message"] as? String == "invalid signature")
        // Single reject: no retry, no rebuild, no expired event.
        #expect(relay.requestCount == 1)
        #expect(control.mintCount == 1)
        #expect(events.events.isEmpty)
        #expect(await context.signingClient.currentPhase() == .signed)
    }

    @Test func tokenExpired401EmitsCredentialExpiredEventWithoutRetry() async throws {
        let relay = MockRelayServer(scripts: [.json(
            ["type": "error", "error": ["type": "authentication_error", "message": "token expired"]],
            status: 401)])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let events = CredentialEventChannel()
        let (context, directory) = try makeRelayContext(control: control, events: events, directoryLabel: "expired")
        defer { try? FileManager.default.removeItem(at: directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let outcome = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(model: "glm-5.3"),
            target: relayRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-expired")
        guard case .responded(let response) = outcome else {
            Issue.record("expected responded (passthrough), got \(outcome)")
            return
        }
        #expect(Int(response.status.code) == 401)
        // The expiry surfaces to the UI channel immediately…
        #expect(events.events == [CredentialEvent.expired(reason: "token expired")])
        // …and nothing retries: exactly one relay request left the process.
        #expect(relay.requestCount == 1)
        #expect(control.mintCount == 1)
    }

    @Test func twoRejectsRebuildChainRetryOnceThenSurfaceExpired() async throws {
        // Every relay answer is a 401; the chain rebuild succeeds but the
        // retry keeps failing — the ladder terminates with the event + 502.
        let reject = MockRelayServer.Script.json(
            ["type": "error", "error": ["type": "authentication_error", "message": "signature mismatch"]],
            status: 401)
        let relay = MockRelayServer(scripts: [reject, reject, reject])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let events = CredentialEventChannel()
        let (context, directory) = try makeRelayContext(control: control, events: events, directoryLabel: "ladder")
        defer { try? FileManager.default.removeItem(at: directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        // Request 1: first reject → passthrough.
        let first = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(model: "glm-5.3"),
            target: relayRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-ladder-1")
        guard case .responded(let firstResponse) = first else {
            Issue.record("expected responded, got \(first)")
            return
        }
        #expect(Int(firstResponse.status.code) == 401)
        _ = firstResponse

        // Request 2: second reject → rebuild + one signed retry → 401 again.
        let second = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(model: "glm-5.3"),
            target: relayRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-ladder-2")
        guard case .credentialsExpired(let reason) = second else {
            Issue.record("expected credentialsExpired, got \(second)")
            return
        }
        #expect(reason == "signature mismatch")
        #expect(events.events == [CredentialEvent.expired(reason: "signature mismatch")])
        // Bounded: 3 relay requests total (1st req + reject + retry), 2 chains.
        #expect(relay.requestCount == 3)
        #expect(control.mintCount == 2)
        #expect(control.handshakeCount == 2)
    }

    @Test func rebuiltChainRetryCanRecover() async throws {
        let reject = MockRelayServer.Script.json(
            ["type": "error", "error": ["type": "authentication_error", "message": "stale signature"]],
            status: 401)
        let relay = MockRelayServer(scripts: [reject, reject, .json(["id": "msg_recovered"])])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let events = CredentialEventChannel()
        let (context, directory) = try makeRelayContext(control: control, events: events, directoryLabel: "recover")
        defer { try? FileManager.default.removeItem(at: directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        _ = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(model: "glm-5.3"),
            target: relayRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-recover-1")

        let second = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(model: "glm-5.3"),
            target: relayRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-recover-2")
        guard case .responded(let response) = second else {
            Issue.record("expected responded (recovered), got \(second)")
            return
        }
        #expect(response.status == .ok)
        #expect(events.events.isEmpty)
        #expect(relay.requestCount == 3)
    }

    @Test func failOpenUnsignedOnlyAfterEstablishedSessionAndTwoRejects() async throws {
        let reject = MockRelayServer.Script.json(
            ["type": "error", "error": ["type": "authentication_error", "message": "signature mismatch"]],
            status: 401)
        // Signed attempt → 401; rebuilt signed retry → 401; fail-open unsigned → 200.
        let relay = MockRelayServer(scripts: [reject, reject, .json(["id": "msg_failopen"])])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        control.failHandshakeFromCount = 1  // first handshake OK, the rebuild fails
        let events = CredentialEventChannel()
        let (context, directory) = try makeRelayContext(control: control, events: events, directoryLabel: "failopen")
        defer { try? FileManager.default.removeItem(at: directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        // Request 1 establishes the signed session, then rejects once.
        let first = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(model: "glm-5.3"),
            target: relayRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-failopen-1")
        guard case .responded(let firstResponse) = first else {
            Issue.record("expected responded, got \(first)")
            return
        }
        #expect(Int(firstResponse.status.code) == 401)

        // Request 2: second reject → rebuild fails (handshake now failing) →
        // the previously established session allows ONE unsigned attempt.
        let second = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(model: "glm-5.3"),
            target: relayRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-failopen-2")
        guard case .responded(let secondResponse) = second else {
            Issue.record("expected responded (fail-open), got \(second)")
            return
        }
        #expect(secondResponse.status == .ok)
        #expect(events.events.isEmpty)

        // Three relay attempts; only the third is unsigned.
        #expect(relay.requestCount == 3)
        let unsignedRequest = relay.requests[2]
        #expect(unsignedRequest.headers["x-client-sig"] == nil)
        #expect(unsignedRequest.headers["x-client-pow"] == nil)
        #expect(unsignedRequest.headers["x-client-ts"] == nil)
        #expect(unsignedRequest.headers["x-client-nonce"] == nil)
        // Auth still rides along in the fail-open attempt.
        let session = try await context.signingClient.ensureSession()
        #expect(unsignedRequest.headers["authorization"] == "Bearer \(session.projectToken)")
        // And the signed attempts did carry the quartet.
        #expect(relay.requests[0].headers["x-client-sig"]?.count == 88)
    }

    // MARK: - 429 policy (AC: one backoff retry, then fallback / 529)

    @Test func rateLimitBackoffDefaultIsOneSecond() {
        #expect(RelayTarget.defaultRateLimitBackoff == 1)
    }

    @Test func relay429RetriesOnceAfterBackoffThenReturnsRateLimited() async throws {
        let limited = MockRelayServer.Script.json(
            ["type": "error", "error": ["type": "rate_limit_error", "message": "rate limited"]],
            status: 429)
        let relay = MockRelayServer(scripts: [limited, limited])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let (context, directory) = try makeRelayContext(control: control, directoryLabel: "429")
        defer { try? FileManager.default.removeItem(at: directory) }
        context.rateLimitBackoff = 0.05
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let start = Date()
        let outcome = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(model: "glm-5.3"),
            target: relayRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-429")
        let elapsed = Date().timeIntervalSince(start)

        guard case .rateLimitedAfterRetry = outcome else {
            Issue.record("expected rateLimitedAfterRetry, got \(outcome)")
            return
        }
        #expect(relay.requestCount == 2)  // initial + exactly one retry
        #expect(elapsed >= 0.045)         // the backoff ran before the retry
    }

    @Test func failOpen429FollowsTheRateLimitPolicy() async throws {
        // A 429 on the unsigned fail-open attempt must follow the same
        // rate-limit policy as the signed path: one backoff retry (also
        // unsigned), then the caller's rate-limit decision — not a raw
        // 429 passed through as `.responded`.
        let reject = MockRelayServer.Script.json(
            ["type": "error", "error": ["type": "authentication_error", "message": "signature mismatch"]],
            status: 401)
        let limited = MockRelayServer.Script.json(
            ["type": "error", "error": ["type": "rate_limit_error", "message": "rate limited"]],
            status: 429)
        // Signed → 401; rebuilt signed → 401; fail-open unsigned → 429;
        // its backoff retry (also unsigned) → 429.
        let relay = MockRelayServer(scripts: [reject, reject, limited, limited])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        control.failHandshakeFromCount = 1  // first handshake OK, the rebuild fails
        let (context, directory) = try makeRelayContext(control: control, directoryLabel: "failopen429")
        defer { try? FileManager.default.removeItem(at: directory) }
        context.rateLimitBackoff = 0.05
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        // Request 1 establishes the signed session, then rejects once.
        let first = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(model: "glm-5.3"),
            target: relayRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-failopen429-1")
        guard case .responded(let firstResponse) = first else {
            Issue.record("expected responded, got \(first)")
            return
        }
        #expect(Int(firstResponse.status.code) == 401)

        // Request 2: reject → rebuild fails → the established session allows
        // ONE unsigned attempt → 429 there → backoff retry (unsigned) → 429
        // → rateLimitedAfterRetry for the caller.
        let second = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(model: "glm-5.3"),
            target: relayRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-failopen429-2")
        guard case .rateLimitedAfterRetry = second else {
            Issue.record("expected rateLimitedAfterRetry, got \(second)")
            return
        }
        // Signed, signed, unsigned, unsigned retry — the retry rode the SAME
        // fail-open attempt, not a new signed exchange.
        #expect(relay.requestCount == 4)
        if relay.requests.count >= 4 {
            #expect(relay.requests[2].headers["x-client-sig"] == nil)
            #expect(relay.requests[3].headers["x-client-sig"] == nil)
        }
    }

    // MARK: - Endpoint routing (agent/configs, relay fidelity Task 1)

    /// EndpointResolving stub: rewrites the `from` prefix to `to` (keeping
    /// the request's path remainder, like the real service) and serves a
    /// fixed token; records what it was asked to resolve. nil `from`/`token`
    /// exercise the fail-open pass-throughs.
    private final class StubEndpointResolver: EndpointResolving, @unchecked Sendable {
        private let lock = NSLock()
        private var _resolved: [String] = []
        let from: String?
        let to: String?
        let token: String?

        init(from: String?, to: String?, token: String?) {
            self.from = from
            self.to = to
            self.token = token
        }

        var resolvedURLs: [String] {
            lock.lock(); defer { lock.unlock() }
            return _resolved
        }

        func resolve(_ url: String) async -> (url: String, addZcodeAuthorization: Bool) {
            lock.lock(); _resolved.append(url); lock.unlock()
            guard let from, let to, url.hasPrefix(from) else {
                return (url: url, addZcodeAuthorization: false)
            }
            return (to + url.dropFirst(from.count), true)
        }

        func zcodeAuthorizationToken() -> String? { token }
    }

    /// A relay target pinned to the CLI's PRE-routing URL (local stand-in).
    private func preRoutingRouteTarget(port: Int) -> RoutingSnapshot.RouteTarget {
        RoutingSnapshot.RouteTarget(
            baseURL: "http://127.0.0.1:\(port)/api/v1/zcode-plan/anthropic",
            apiKey: "",
            vendorName: "ZCode Relay",
            vendorID: UUID(),
            targetModel: "glm-5.3",
            isPassthrough: false,
            connectTimeoutSeconds: 5,
            readTimeoutSeconds: 10,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .transparent,
            vendorKind: .relay)
    }

    @Test func endpointRoutingRewritesRequestAndAddsZcodeAuthorization() async throws {
        let relay = MockRelayServer(scripts: [.json(["id": "msg_route"])])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let directory = try makeTempDirectory("ep-route")
        defer { try? FileManager.default.removeItem(at: directory) }
        let signingClient = makeSigningClient(directory: directory, control: control)
        let resolver = StubEndpointResolver(
            from: "http://127.0.0.1:\(port)/api/v1/zcode-plan/anthropic",
            to: "http://127.0.0.1:\(port)/api/v1/ultra-zai/anthropic",
            token: "synthetic-zcode-jwt")
        let context = RelayTarget.Context(
            signingClient: signingClient, endpointConfig: resolver)
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let outcome = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(model: "glm-5.3"),
            target: preRoutingRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-ep-route")
        guard case .responded(let response) = outcome else {
            Issue.record("expected responded, got \(outcome)")
            return
        }
        #expect(response.status == .ok)

        // The relay path consulted the service per request with the FULL
        // pinned URL (baseURL + request uri)...
        #expect(resolver.resolvedURLs
            == ["http://127.0.0.1:\(port)/api/v1/zcode-plan/anthropic/v1/messages"])
        // ...and the request went to the rewritten target with the zcode
        // plan JWT riding the flagged header.
        let request = try #require(relay.requests.first)
        #expect(request.path == "/api/v1/ultra-zai/anthropic/v1/messages")
        #expect(request.headers["x-zcode-authorization"] == "Bearer synthetic-zcode-jwt")
        // The signing quartet still rides the same request.
        #expect(request.headers["x-client-sig"]?.count == 88)
    }

    @Test func endpointRoutingWithoutTokenOmitsHeaderFailOpen() async throws {
        let relay = MockRelayServer(scripts: [.json(["id": "msg_notoken"])])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let directory = try makeTempDirectory("ep-notoken")
        defer { try? FileManager.default.removeItem(at: directory) }
        let signingClient = makeSigningClient(directory: directory, control: control)
        let resolver = StubEndpointResolver(
            from: "http://127.0.0.1:\(port)/api/v1/zcode-plan/anthropic",
            to: "http://127.0.0.1:\(port)/api/v1/ultra-zai/anthropic",
            token: nil)
        let context = RelayTarget.Context(
            signingClient: signingClient, endpointConfig: resolver)
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let outcome = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(model: "glm-5.3"),
            target: preRoutingRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-ep-notoken")
        guard case .responded = outcome else {
            Issue.record("expected responded, got \(outcome)")
            return
        }
        // No credential-store JWT → the header is omitted, the request
        // still serves at the rewritten target (fail-open on the token).
        let request = try #require(relay.requests.first)
        #expect(request.path == "/api/v1/ultra-zai/anthropic/v1/messages")
        #expect(request.headers["x-zcode-authorization"] == nil)
    }

    @Test func zcodeAuthorizationHeaderSitsRightAfterAuthorization() throws {
        let session = SigningSession(
            projectToken: Fixtures.projectToken,
            apiKeyId: Fixtures.apiKeyId,
            privateKey: try Curve25519.Signing.PrivateKey(rawRepresentation: Fixtures.ed25519Seed),
            expiresAtMs: .max,
            marginRelaxed: false)
        let headers = try RelayTarget.relayHeaders(
            session: session, signed: false, sessionID: "sid",
            zcodeAuthorization: "synthetic-zcode-jwt")
        let names = headers.map { $0.name }
        let authorization = try #require(names.firstIndex(of: "authorization"))
        #expect(names.firstIndex(of: "x-zcode-authorization") == authorization + 1)
        #expect(headers["x-zcode-authorization"] == ["Bearer synthetic-zcode-jwt"])

        let bare = try RelayTarget.relayHeaders(
            session: session, signed: false, sessionID: "sid")
        #expect(!bare.map { $0.name }.contains("x-zcode-authorization"))
    }

    // MARK: - ProxyForwarder integration (route wiring + terminal bodies)

    private struct ForwardFixture {
        let router: RequestRouter
        let trafficLog: TrafficLog
        let tokenStatsStore: TokenStatsStore
        let lineageBroker: SessionLineageBroker
        let portableNormalizer: PortableContentNormalizer
        let requestCoordinator: BranchRequestCoordinator
        let relayVendorID: UUID
        let directory: URL
    }

    private func makeForwardFixture(
        relayPort: Int, backupPort: Int?
    ) throws -> ForwardFixture {
        let relayVendorID = UUID()
        var vendors = [Vendor(
            id: relayVendorID, name: "ZCode Relay",
            baseURL: "http://127.0.0.1:\(relayPort)/api/v1/ultra-zai/anthropic",
            apiKey: "", readTimeoutSeconds: 10, vendorKind: .relay)]
        var mapping = ModelMapping(
            sourceModel: "claude-sonnet-5", targetModel: "glm-5.3",
            targetVendorID: relayVendorID, isEnabled: true)
        if let backupPort {
            let backupVendor = Vendor(
                id: UUID(), name: "Backup Vendor",
                baseURL: "http://127.0.0.1:\(backupPort)",
                apiKey: "backup-key", readTimeoutSeconds: 10)
            vendors.append(backupVendor)
            mapping.backupTargetVendorID = backupVendor.id
            mapping.backupTargetModel = "glm-5.3"
        }
        let clientConfig = ClientConfig(
            clientName: "Claude Code", port: 0,
            defaultUpstream: "https://api.anthropic.com", unmappedPolicy: .block)
        let config = AppConfig(vendors: vendors, clients: [clientConfig], modelMappings: [mapping])
        let snapshot = RoutingSnapshot(from: config, for: clientConfig)

        let directory = try makeTempDirectory("forward")
        let lineageBroker = SessionLineageBroker(
            store: FileLineageStore(fileURL: directory.appendingPathComponent("lineages.json")))
        return ForwardFixture(
            router: RequestRouter(snapshot: snapshot),
            trafficLog: TrafficLog(),
            tokenStatsStore: TokenStatsStore(),
            lineageBroker: lineageBroker,
            portableNormalizer: PortableContentNormalizer(),
            requestCoordinator: BranchRequestCoordinator(),
            relayVendorID: relayVendorID,
            directory: directory)
    }

    @discardableResult
    private func forward(
        _ fixture: ForwardFixture, httpClient: HTTPClient, context: RelayTarget.Context?,
        channel: any Channel, model: String = "claude-sonnet-5"
    ) async -> Void {
        var body = ByteBufferAllocator().buffer(capacity: 0)
        body.writeData(requestBody(model: model))
        await ProxyForwarder.forward(
            clientName: "Claude Code",
            head: postHead(),
            body: body,
            channel: channel,
            router: fixture.router,
            httpClient: httpClient,
            trafficLog: fixture.trafficLog,
            tokenStatsStore: fixture.tokenStatsStore,
            lineageBroker: fixture.lineageBroker,
            portableNormalizer: fixture.portableNormalizer,
            requestCoordinator: fixture.requestCoordinator,
            webSearchProvider: nil,
            webSearchForwardAsIs: false,
            relayContext: context)
    }

    @Test func forwardRoutesRelayVendorThroughSignedLadder() async throws {
        let relay = MockRelayServer(scripts: [.json(["id": "msg_forward", "role": "assistant"])])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let (context, _) = try makeRelayContext(control: control, directoryLabel: "fwd")
        let fixture = try makeForwardFixture(relayPort: port, backupPort: nil)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let client = EmbeddedChannel()
        await forward(fixture, httpClient: httpClient, context: context, channel: client)
        let (head, body, sawEnd) = try drainClientResponse(client)
        #expect(head.status == .ok)
        #expect(sawEnd)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["id"] as? String == "msg_forward")

        // The relay request: signed, GLM-canonical model, rule target applied.
        let request = try #require(relay.requests.first)
        #expect(request.path == "/api/v1/ultra-zai/anthropic/v1/messages")
        #expect(request.headers["x-client-sig"]?.count == 88)
        let sentJSON = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(sentJSON["model"] as? String == "GLM-5.3")
        // The client's own credentials never reach the relay.
        #expect(request.headers["x-api-key"] != "client-key")
        finishChannel(client)
    }

    @Test func forwardRelayHandshakeFailureAnswers502WithClearBody() async throws {
        let relay = MockRelayServer(scripts: [])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        control.failHandshakeFromCount = 0
        let (context, _) = try makeRelayContext(control: control, directoryLabel: "fwd502")
        let fixture = try makeForwardFixture(relayPort: port, backupPort: nil)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let client = EmbeddedChannel()
        await forward(fixture, httpClient: httpClient, context: context, channel: client)
        let (head, body, sawEnd) = try drainClientResponse(client)
        #expect(head.status == .badGateway)
        #expect(sawEnd)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["type"] as? String == "api_error")
        #expect((error["message"] as? String)?.localizedCaseInsensitiveContains("signing") == true)
        // Never unsigned: nothing reached the relay.
        #expect(relay.requestCount == 0)
        finishChannel(client)
    }

    @Test func forward429WithoutFallbackAnswers529() async throws {
        let limited = MockRelayServer.Script.json(
            ["type": "error", "error": ["type": "rate_limit_error", "message": "rate limited"]],
            status: 429)
        let relay = MockRelayServer(scripts: [limited, limited])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let (context, _) = try makeRelayContext(control: control, directoryLabel: "fwd529")
        context.rateLimitBackoff = 0.05
        let fixture = try makeForwardFixture(relayPort: port, backupPort: nil)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let client = EmbeddedChannel()
        await forward(fixture, httpClient: httpClient, context: context, channel: client)
        let (head, body, sawEnd) = try drainClientResponse(client)
        #expect(head.status == HTTPResponseStatus(statusCode: 529))
        #expect(sawEnd)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["type"] as? String == "overloaded_error")
        #expect((error["message"] as? String)?.localizedCaseInsensitiveContains("no fallback") == true)
        #expect(relay.requestCount == 2)
        finishChannel(client)
    }

    @Test func forward429WithBackupRuleFallsBackToBackupVendor() async throws {
        let limited = MockRelayServer.Script.json(
            ["type": "error", "error": ["type": "rate_limit_error", "message": "rate limited"]],
            status: 429)
        let relay = MockRelayServer(scripts: [limited, limited])
        let relayPort = try await relay.start()
        let backup = MockRelayServer(scripts: [.json(["id": "msg_backup"])])
        let backupPort = try await backup.start()
        defer {
            Task { await relay.shutdown() }
            Task { await backup.shutdown() }
        }
        let control = SigningControl()
        let (context, _) = try makeRelayContext(control: control, directoryLabel: "fwdfallback")
        context.rateLimitBackoff = 0.05
        let fixture = try makeForwardFixture(relayPort: relayPort, backupPort: backupPort)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let client = EmbeddedChannel()
        await forward(fixture, httpClient: httpClient, context: context, channel: client)
        let (head, body, sawEnd) = try drainClientResponse(client)
        #expect(head.status == .ok)
        #expect(sawEnd)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["id"] as? String == "msg_backup")
        // Relay saw initial + one retry; the backup served the final answer.
        #expect(relay.requestCount == 2)
        #expect(backup.requestCount == 1)
        finishChannel(client)
    }
}

// MARK: - Regex helper

/// Minimal `=~` for the few shape asserts (no Foundation NSRegularExpression noise).
infix operator =~ : ComparisonPrecedence
private func =~ (lhs: String, rhs: String) -> Bool {
    lhs.range(of: rhs, options: .regularExpression) != nil
}

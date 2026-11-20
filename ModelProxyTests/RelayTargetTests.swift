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
    private func makeSigningClient(
        directory: URL, control: SigningControl, seedCache: Bool = true
    ) -> SigningClient {
        SigningURLProtocolMock.control = control
        var configuration = SigningClient.Configuration()
        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [SigningURLProtocolMock.self]
        configuration.session = URLSession(configuration: urlSessionConfiguration)
        configuration.storeLoader = { nil }
        configuration.initialLocation = Fixtures.location
        let cacheURL = directory.appendingPathComponent("biz-session.cache")
        configuration.cacheURL = cacheURL
        if seedCache {
            let cache = BizSessionCache(fileURL: cacheURL)
            try? cache.save(BizSession(
                bizJwt: Fixtures.bizJwt,
                acquiredAtMs: Int64(Date().timeIntervalSince1970 * 1000) - 1_000,
                location: Fixtures.location))
        }
        return SigningClient(configuration: configuration)
    }

    private func makeRelayContext(
        control: SigningControl,
        events: CredentialEventChannel? = nil,
        directoryLabel: String,
        quota: (any QuotaRelayCounting)? = nil,
        onRiskControl: (@Sendable (String) -> Void)? = nil,
        relayHealth: RelayHealth? = nil,
        seedCache: Bool = true
    ) throws -> (RelayTarget.Context, URL) {
        let directory = try makeTempDirectory(directoryLabel)
        let client = makeSigningClient(directory: directory, control: control, seedCache: seedCache)
        return (RelayTarget.Context(
            signingClient: client, credentialEvents: events, quota: quota,
            onRiskControl: onRiskControl, relayHealth: relayHealth), directory)
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

    /// The inbound client request head. The optional Claude Code identity
    /// headers (session/agent) ride along so session-derivation tests can
    /// exercise the real inbound face — the relay never forwards them.
    private func postHead(
        uri: String = "/v1/messages", claudeSessionID: String? = nil, agentID: String? = nil
    ) -> HTTPRequestHead {
        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: uri)
        head.headers.add(name: "x-api-key", value: "client-key")
        head.headers.add(name: "anthropic-version", value: "2023-06-01")
        if let claudeSessionID {
            head.headers.add(name: ProxyForwarder.claudeCodeSessionHeader, value: claudeSessionID)
        }
        if let agentID {
            head.headers.add(name: ProxyForwarder.claudeCodeAgentHeader, value: agentID)
        }
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
        // Retired names (upstream 400 code 3006) canonicalize to the current
        // main model instead of passing through.
        #expect(RelayTarget.canonicalModel("glm-5.2") == "GLM-5.3")
        #expect(RelayTarget.canonicalModel("glm-5.1") == "GLM-5.3")
        #expect(RelayTarget.canonicalModel("glm-5.1-highspeed") == "GLM-5.3")
        #expect(RelayTarget.canonicalModel("glm-5-turbo") == "GLM-5.3")
        #expect(RelayTarget.canonicalModel("glm-4.7") == "GLM-5.3")
        #expect(RelayTarget.canonicalModel("glm-turbo") == "GLM-5.3")
        // Flash-suffixed retired names ride the flash rule (checked first).
        #expect(RelayTarget.canonicalModel("glm-5.2-flash") == "GLM-5.3-Flash")
        #expect(RelayTarget.canonicalModel("glm-4.7-flash") == "GLM-5.3-Flash")
        // Older family names still pass through verbatim.
        #expect(RelayTarget.canonicalModel("GLM-4.5-Air") == "GLM-4.5-Air")
        // Provider-qualified names strip the prefix before canonicalization.
        #expect(RelayTarget.canonicalModel("zai/GLM-5.3") == "GLM-5.3")
        #expect(RelayTarget.canonicalModel("bigmodel/glm-5.3") == "GLM-5.3")
        #expect(RelayTarget.canonicalModel("ZAI/glm-5.2") == "GLM-5.3")
        #expect(RelayTarget.canonicalModel("zai/glm-5.3-flash") == "GLM-5.3-Flash")
        #expect(RelayTarget.canonicalModel("  bigmodel/GLM-4.6  ") == "GLM-4.6")
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
        // fixture (`v3-relay-request.json`, 26 headers in wire order since
        // the probe-B flip dropped `x-api-key`).
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

        // Auth: the synthetic session token rides Authorization only —
        // `x-api-key` is never sent on the relay face (probe-B flip,
        // live-verified 2026-11-20: Bearer + V4 quartet alone answers 200).
        let session = try await context.signingClient.ensureSession()
        #expect(headers["authorization"] == "Bearer \(session.projectToken)")
        #expect(headers["x-api-key"] == nil)

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
    /// `sendSigned` path; no `x-api-key` anywhere (probe-B flip — the
    /// Authorization bearer + quartet alone is the accepted face).
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
            session: session, signed: true,
            identity: RelayTarget.SessionIdentity(id: "sid", type: "main"))
        #expect(signed.map { $0.name } == identity + signer)
        #expect(signed["user-agent"] == ["ZCode/0.17.1 ai-sdk/anthropic/3.0.81"])

        // Unsigned fail-open attempt: identity only — the signer block
        // is the CLI signer's, so it never rides an unsigned request.
        let unsigned = try RelayTarget.relayHeaders(
            session: session, signed: false,
            identity: RelayTarget.SessionIdentity(id: "sid", type: "main"))
        #expect(unsigned.map { $0.name } == identity)

        // The Task 1 routing header rides immediately after `authorization`
        // (it is ZGate's, not part of the CLI static face).
        let routed = try RelayTarget.relayHeaders(
            session: session, signed: true,
            identity: RelayTarget.SessionIdentity(id: "sid", type: "main"),
            zcodeAuthorization: "synthetic-zcode-jwt")
        let routedNames = routed.map { $0.name }
        #expect(routedNames == {
            var names = identity
            names.insert("x-zcode-authorization", at: names.firstIndex(of: "authorization")! + 1)
            return names
        }() + signer)
    }

    // MARK: - Configured client version (relay fidelity Task 4:
    // UA, x-zcode-app-version, x-client-version, sig message — one source)

    /// The four version surfaces all derive from the configured value: with
    /// a bumped pin the UA, both version headers, AND the Ed25519 sig
    /// message carry it (the default-parameter statics above stay the
    /// bundled-default face).
    @Test func configuredVersionDrivesAllFourSurfaces() throws {
        let session = SigningSession(
            projectToken: Fixtures.projectToken,
            apiKeyId: Fixtures.apiKeyId,
            privateKey: try Curve25519.Signing.PrivateKey(rawRepresentation: Fixtures.ed25519Seed),
            expiresAtMs: .max,
            marginRelaxed: false)
        let identity = RelayTarget.SessionIdentity(id: "sid", type: "main")

        let headers = try RelayTarget.relayHeaders(
            session: session, signed: true, identity: identity, clientVersion: "0.18.0")
        #expect(headers["user-agent"] == ["ZCode/0.18.0 ai-sdk/anthropic/3.0.81"])
        #expect(headers["x-zcode-app-version"] == ["0.18.0"])
        #expect(headers["x-client-version"] == ["0.18.0"])

        // Sig surface: the message is built from the configured version, so
        // the fixture key verifies it only when the version rode along.
        let ts = try #require(headers["x-client-ts"].first)
        let nonce = try #require(headers["x-client-nonce"].first)
        let sig = try #require(headers["x-client-sig"].first)
        let sigBytes = try #require(Data(base64Encoded: sig))
        let publicKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Fixtures.ed25519Seed).publicKey
        let message = CryptoCore.requestSigMessage(
            apiKeyId: Fixtures.apiKeyId, ts: ts, version: "0.18.0",
            sessionId: "sid", nonce: nonce)
        #expect(publicKey.isValidSignature(sigBytes, for: Data(message.utf8)))
        let staleVersionMessage = CryptoCore.requestSigMessage(
            apiKeyId: Fixtures.apiKeyId, ts: ts, version: "0.17.1",
            sessionId: "sid", nonce: nonce)
        #expect(!publicKey.isValidSignature(sigBytes, for: Data(staleVersionMessage.utf8)))
    }

    /// The execute path threads `Context.clientVersion` into the same four
    /// surfaces (this is the wiring a live VersionPinService bump mutates).
    @Test func contextVersionDrivesTheExecutePath() async throws {
        let relay = MockRelayServer(scripts: [.json(["id": "msg_version"])])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let directory = try makeTempDirectory("version")
        defer { try? FileManager.default.removeItem(at: directory) }
        let signingClient = makeSigningClient(directory: directory, control: control)
        let context = RelayTarget.Context(signingClient: signingClient, clientVersion: "0.18.0")
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let outcome = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(model: "glm-5.3"),
            target: relayRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-version")
        guard case .responded = outcome else {
            Issue.record("expected responded, got \(outcome)")
            return
        }

        let headers = try #require(relay.requests.first).headers
        #expect(headers["user-agent"] == "ZCode/0.18.0 ai-sdk/anthropic/3.0.81")
        #expect(headers["x-zcode-app-version"] == "0.18.0")
        #expect(headers["x-client-version"] == "0.18.0")

        let session = try await context.signingClient.ensureSession()
        let ts = try #require(headers["x-client-ts"])
        let nonce = try #require(headers["x-client-nonce"])
        let sig = try #require(headers["x-client-sig"])
        let sigBytes = try #require(Data(base64Encoded: sig))
        let publicKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Fixtures.ed25519Seed).publicKey
        let message = CryptoCore.requestSigMessage(
            apiKeyId: session.apiKeyId, ts: ts, version: "0.18.0",
            sessionId: context.sessionID, nonce: nonce)
        #expect(publicKey.isValidSignature(sigBytes, for: Data(message.utf8)))
    }

    /// No inbound CC headers → the per-process UUID stays the session id,
    /// stable across requests — the pre-Task-3 face, now the fallback.
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
        #expect(relay.requests[0].headers["x-session-id"] == context.sessionID)
        #expect(relay.requests[0].headers["x-zcode-session-type"] == "main")
    }

    // MARK: - Session identity (AC: per-conversation id, subagent type, fallback)

    /// Sanitize: lowercase, keep ASCII hex (digits included) + `-`, accept
    /// 8–64 chars before cleaning and ≥ 8 after — anything else → nil.
    @Test func sessionIdentitySanitizeAcceptsHexDashWithinBounds() {
        let uuid = "1b0e0c6e-9d8a-4c3f-8e2d-2f9a6d4b1c0e"
        #expect(RelayTarget.SessionIdentity.sanitize(uuid) == uuid)
        #expect(RelayTarget.SessionIdentity.sanitize(uuid.uppercased()) == uuid)
        // Digits are hex characters — a digit-heavy conversation uuid must
        // survive cleaning byte-for-byte (lowercased).
        #expect(RelayTarget.SessionIdentity.sanitize("04cbf1c5-caed-4278-91ab-c3d0e5f6a7b8")
            == "04cbf1c5-caed-4278-91ab-c3d0e5f6a7b8")
        // Non-hex characters are dropped; what survives must still be ≥ 8.
        #expect(RelayTarget.SessionIdentity.sanitize("zz1b0e0c6e9d8azz") == "1b0e0c6e9d8a")
        #expect(RelayTarget.SessionIdentity.sanitize("zzzzzzzzzzzzzzzz") == nil)
        // Length bounds: 8 passes, 7 fails, 64 passes, 65 fails.
        #expect(RelayTarget.SessionIdentity.sanitize("12345678") == "12345678")
        #expect(RelayTarget.SessionIdentity.sanitize("1234567") == nil)
        #expect(RelayTarget.SessionIdentity.sanitize(String(repeating: "a", count: 64))
            == String(repeating: "a", count: 64))
        #expect(RelayTarget.SessionIdentity.sanitize(String(repeating: "a", count: 65)) == nil)
        #expect(RelayTarget.SessionIdentity.sanitize(nil) == nil)
    }

    /// shortHash: first 8 hex chars of SHA-256 — pinned against the
    /// well-known empty-string digest, stable, input-sensitive.
    @Test func sessionIdentityShortHashIsFirstEightHexOfSHA256() {
        #expect(RelayTarget.SessionIdentity.shortHash("") == "e3b0c442")
        let hash = RelayTarget.SessionIdentity.shortHash("agent-77")
        #expect(hash.count == 8)
        #expect(hash.allSatisfy { $0.isHexDigit && ($0.isLowercase || $0.isNumber) })
        #expect(hash == RelayTarget.SessionIdentity.shortHash("agent-77"))
        #expect(hash != RelayTarget.SessionIdentity.shortHash("agent-78"))
    }

    /// derive: conversation header → sanitized id (main); agent header →
    /// per-agent subagent id; absent/garbage session header → per-process
    /// fallback base.
    @Test func sessionIdentityDeriveRules() {
        let fallback = "0d8a6e1f-2c3b-4d5e-9f8a-7b6c5d4e3f2a"
        let conversation = "5f4e3d2c-1b0a-4c9d-8e7f-6a5b4c3d2e1f"

        // No CC headers: the per-process fallback, main.
        #expect(RelayTarget.SessionIdentity.derive(from: postHead(), fallback: fallback)
            == RelayTarget.SessionIdentity(id: fallback, type: "main"))

        // Conversation header (uppercased inbound — sanitized to lowercase).
        let conversed = postHead(claudeSessionID: conversation.uppercased())
        #expect(RelayTarget.SessionIdentity.derive(from: conversed, fallback: fallback)
            == RelayTarget.SessionIdentity(id: conversation, type: "main"))

        // Agent header: subagent turn with its own per-agent id.
        let subagentHead = postHead(claudeSessionID: conversation, agentID: "agent-77")
        let subagent = RelayTarget.SessionIdentity.derive(from: subagentHead, fallback: fallback)
        #expect(subagent.type == "subagent")
        #expect(subagent.id == "\(conversation)-\(RelayTarget.SessionIdentity.shortHash("agent-77"))")

        // Garbage conversation id: the fallback is the base (the agent header
        // still marks the turn and derives its own id from that base).
        let garbage = postHead(claudeSessionID: "zzzzzzzzzzzzzzzz", agentID: "agent-77")
        let garbageIdentity = RelayTarget.SessionIdentity.derive(from: garbage, fallback: fallback)
        #expect(garbageIdentity.id == "\(fallback)-\(RelayTarget.SessionIdentity.shortHash("agent-77"))")
        #expect(garbageIdentity.type == "subagent")

        // Empty agent header = not present (still main).
        let emptyAgent = postHead(claudeSessionID: conversation, agentID: "")
        #expect(RelayTarget.SessionIdentity.derive(from: emptyAgent, fallback: fallback).type == "main")
    }

    /// Relay level: the inbound CC conversation header drives `x-session-id`
    /// — identical across requests in one conversation, distinct across
    /// conversations, never the per-process fallback — and PoW + sig are
    /// bound to the DERIVED id (the server sees one session id everywhere).
    @Test func ccSessionHeaderDrivesSessionIDAndSigningInputs() async throws {
        let relay = MockRelayServer(scripts: [])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let (context, directory) = try makeRelayContext(control: control, directoryLabel: "ccsess")
        defer { try? FileManager.default.removeItem(at: directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let conversation = "5f4e3d2c-1b0a-4c9d-8e7f-6a5b4c3d2e1f"
        for _ in 0..<2 {
            let outcome = await RelayTarget.execute(
                head: postHead(claudeSessionID: conversation),
                bodyData: requestBody(model: "glm-5.3"),
                target: relayRouteTarget(port: port), httpClient: httpClient,
                context: context, requestID: "t-ccsess")
            guard case .responded = outcome else {
                Issue.record("expected responded, got \(outcome)")
                return
            }
        }
        let otherConversation = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeffff0000"
        let outcome = await RelayTarget.execute(
            head: postHead(claudeSessionID: otherConversation),
            bodyData: requestBody(model: "glm-5.3"),
            target: relayRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-ccsess")
        guard case .responded = outcome else {
            Issue.record("expected responded, got \(outcome)")
            return
        }

        #expect(relay.requestCount == 3)
        let first = relay.requests[0].headers
        let second = relay.requests[1].headers
        let third = relay.requests[2].headers
        #expect(first["x-session-id"] == conversation)
        #expect(first["x-session-id"] == second["x-session-id"])
        #expect(third["x-session-id"] == otherConversation)
        #expect(first["x-session-id"] != third["x-session-id"])
        #expect(first["x-session-id"] != context.sessionID)
        #expect(first["x-zcode-session-type"] == "main")

        // PoW + Ed25519 sig use the derived id — not the per-process fallback.
        let session = try await context.signingClient.ensureSession()
        let ts = try #require(first["x-client-ts"])
        let pow = try #require(first["x-client-pow"])
        #expect(CryptoCore.verifyPow(
            apiKeyId: session.apiKeyId, appId: "zcode", sessionId: conversation,
            ts: ts, pow: pow))
        let nonce = try #require(first["x-client-nonce"])
        let sig = try #require(first["x-client-sig"])
        let sigBytes = try #require(Data(base64Encoded: sig))
        let publicKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Fixtures.ed25519Seed).publicKey
        let message = CryptoCore.requestSigMessage(
            apiKeyId: session.apiKeyId, ts: ts, version: "0.17.1",
            sessionId: conversation, nonce: nonce)
        #expect(publicKey.isValidSignature(sigBytes, for: Data(message.utf8)))
    }

    /// Relay level: an inbound agent-id header marks the turn `subagent` with
    /// the per-agent derived session id — and PoW binds to that same id.
    @Test func agentHeaderMarksSubagentWithPerAgentSessionID() async throws {
        let relay = MockRelayServer(scripts: [])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let (context, directory) = try makeRelayContext(control: control, directoryLabel: "ccagent")
        defer { try? FileManager.default.removeItem(at: directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let conversation = "5f4e3d2c-1b0a-4c9d-8e7f-6a5b4c3d2e1f"
        let outcome = await RelayTarget.execute(
            head: postHead(claudeSessionID: conversation, agentID: "agent-77"),
            bodyData: requestBody(model: "glm-5.3"),
            target: relayRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-ccagent")
        guard case .responded = outcome else {
            Issue.record("expected responded, got \(outcome)")
            return
        }

        let headers = try #require(relay.requests.first).headers
        let expected = "\(conversation)-\(RelayTarget.SessionIdentity.shortHash("agent-77"))"
        #expect(headers["x-session-id"] == expected)
        #expect(headers["x-zcode-session-type"] == "subagent")
        // Distinct from both the conversation id and the per-process fallback.
        #expect(expected != conversation)
        #expect(headers["x-session-id"] != context.sessionID)

        let session = try await context.signingClient.ensureSession()
        let ts = try #require(headers["x-client-ts"])
        let pow = try #require(headers["x-client-pow"])
        #expect(CryptoCore.verifyPow(
            apiKeyId: session.apiKeyId, appId: "zcode", sessionId: expected,
            ts: ts, pow: pow))
    }

    /// Relay level: garbage inbound session ids (non-hex, <8 chars, >64
    /// chars) all fall back to the per-process UUID with type `main` —
    /// identical to the no-header face.
    @Test func garbageSessionHeadersFallBackToProcessSessionID() async throws {
        let relay = MockRelayServer(scripts: [])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let (context, directory) = try makeRelayContext(control: control, directoryLabel: "ccgarbage")
        defer { try? FileManager.default.removeItem(at: directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        for garbage in ["short", "zzzzzzzzzzzzzzzz", String(repeating: "a", count: 65)] {
            let outcome = await RelayTarget.execute(
                head: postHead(claudeSessionID: garbage),
                bodyData: requestBody(model: "glm-5.3"),
                target: relayRouteTarget(port: port), httpClient: httpClient,
                context: context, requestID: "t-ccgarbage")
            guard case .responded = outcome else {
                Issue.record("expected responded, got \(outcome)")
                return
            }
        }
        #expect(relay.requestCount == 3)
        for request in relay.requests {
            #expect(request.headers["x-session-id"] == context.sessionID)
            #expect(request.headers["x-zcode-session-type"] == "main")
        }
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

    // MARK: - Model hygiene on the wire (AC: retired aliases, prefix strip, max_tokens clamp)

    /// wireBody fixture whose model is already canonical, so the model splice
    /// is a byte-identical no-op and any output difference is the clamp alone.
    /// Expected outputs are built from the same generator with only the digits
    /// changed — the assertion is byte-exact, formatting included.
    private func clampFixtureBody(maxTokens: String) -> Data {
        Data("{\"model\":\"GLM-5.3\",\"stream\":true,\"max_tokens\":\(maxTokens),\"messages\":[{\"role\":\"user\",\"content\":\"héllo\"}]}".utf8)
    }

    private func clampWire(_ body: Data) -> Data {
        RelayTarget.wireBody(bodyData: body, target: relayRouteTarget(port: 1, targetModel: "GLM-5.3"))
    }

    @Test func wireBodyLeavesInRangeMaxTokensBytesUntouched() {
        // Both bounds included: in-range values come back byte-identical.
        for value in ["1", "128", "131072"] {
            let body = clampFixtureBody(maxTokens: value)
            #expect(clampWire(body) == body)
        }
    }

    @Test func wireBodyClampsOutOfRangeMaxTokens() {
        // 0 → 1, 131073 → 131072, 200000 → 131072: only the digits change.
        let cases: [(sent: String, wire: String)] = [
            ("0", "1"), ("131073", "131072"), ("200000", "131072"),
        ]
        for testCase in cases {
            #expect(
                clampWire(clampFixtureBody(maxTokens: testCase.sent))
                    == clampFixtureBody(maxTokens: testCase.wire))
        }
    }

    @Test func wireBodyClampPreservesFormattingBytes() {
        // Whitespace around the key/colon survives the splice untouched.
        let body = Data("{\"model\":\"GLM-5.3\" ,  \"max_tokens\" :\n 200000 , \"stream\":true}".utf8)
        let expected = Data("{\"model\":\"GLM-5.3\" ,  \"max_tokens\" :\n 131072 , \"stream\":true}".utf8)
        #expect(clampWire(body) == expected)
    }

    @Test func wireBodyLeavesAbsentMaxTokensUntouched() {
        let body = Data("{\"model\":\"GLM-5.3\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"héllo\"}]}".utf8)
        #expect(clampWire(body) == body)
    }

    @Test func wireBodyIgnoresNestedMaxTokens() {
        // Nested max_tokens (inside a message object) is not the request
        // field: with no top-level key, an out-of-range nested value stays
        // byte-untouched.
        let nestedOnly = Data("{\"model\":\"GLM-5.3\",\"messages\":[{\"role\":\"user\",\"content\":\"x\",\"max_tokens\":200000}]}".utf8)
        #expect(clampWire(nestedOnly) == nestedOnly)

        // With both present, only the top-level value is clamped and the
        // nested out-of-range bytes survive verbatim.
        let both = Data("{\"model\":\"GLM-5.3\",\"max_tokens\":200000,\"messages\":[{\"role\":\"user\",\"content\":\"x\",\"max_tokens\":999999}]}".utf8)
        let expected = Data("{\"model\":\"GLM-5.3\",\"max_tokens\":131072,\"messages\":[{\"role\":\"user\",\"content\":\"x\",\"max_tokens\":999999}]}".utf8)
        #expect(clampWire(both) == expected)
    }

    @Test func wireBodyCanonicalizesProviderPrefixedRetiredModel() throws {
        // Full-path composition: prefix strip + retired alias + in-range
        // clamp no-op on a body-carried model (targetModel nil).
        let body = Data("{\"model\":\"zai/glm-5.2\",\"max_tokens\":128,\"messages\":[]}".utf8)
        let wire = RelayTarget.wireBody(
            bodyData: body, target: relayRouteTarget(port: 1, targetModel: nil))
        let json = try #require(try JSONSerialization.jsonObject(with: wire) as? [String: Any])
        #expect(json["model"] as? String == "GLM-5.3")
        #expect(json["max_tokens"] as? Int == 128)
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

    // MARK: - Business-code taxonomy (relay fidelity Task 6)

    /// Quota-relay seam stub: counts exchange ticks and immediate polls.
    private final class RecordingQuotaCounter: QuotaRelayCounting, @unchecked Sendable {
        private let lock = NSLock()
        private var _relayed = 0
        private var _polls = 0
        var relayed: Int {
            lock.lock(); defer { lock.unlock() }
            return _relayed
        }
        var polls: Int {
            lock.lock(); defer { lock.unlock() }
            return _polls
        }
        func noteRelayedRequest() {
            lock.lock(); _relayed += 1; lock.unlock()
        }
        func pollNow() async {
            lock.lock(); _polls += 1; lock.unlock()
        }
    }

    /// Concurrency-sleeper stub: records requested delays, sleeps nothing.
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

    /// Risk-control event stub: records the surfaced reasons.
    private final class RiskEventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _reasons: [String] = []
        var reasons: [String] {
            lock.lock(); defer { lock.unlock() }
            return _reasons
        }
        func record(_ reason: String) {
            lock.lock(); _reasons.append(reason); lock.unlock()
        }
    }

    @Test func quotaExhaustedCodeOn429DoesNotRetryTicksQuotaSurfaces429Class() async throws {
        // Code 1113 on a 429 body whose message text contains a colliding
        // 20-digit logid: the PARSED code classifies, no retry runs, the
        // quota poll ticks immediately.
        let relay = MockRelayServer(scripts: [.json(
            ["code": 1113, "msg": "Insufficient balance, logid 11139999999999993009"],
            status: 429)])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let quota = RecordingQuotaCounter()
        let (context, directory) = try makeRelayContext(
            control: control, directoryLabel: "quota1113", quota: quota)
        defer { try? FileManager.default.removeItem(at: directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let outcome = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(model: "glm-5.3"),
            target: relayRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-quota1113")
        guard case .quotaExhausted(let reason) = outcome else {
            Issue.record("expected quotaExhausted, got \(outcome)")
            return
        }
        #expect(reason == "Insufficient balance, logid 11139999999999993009")
        #expect(relay.requestCount == 1)  // no retry
        #expect(quota.relayed == 1)       // the exchange tick
        #expect(quota.polls == 1)         // the immediate exhausted tick
    }

    @Test func http402StatusFallbackIsQuotaExhausted() async throws {
        let relay = MockRelayServer(scripts: [.json(["msg": "payment required"], status: 402)])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let quota = RecordingQuotaCounter()
        let (context, directory) = try makeRelayContext(
            control: control, directoryLabel: "quota402", quota: quota)
        defer { try? FileManager.default.removeItem(at: directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let outcome = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(model: "glm-5.3"),
            target: relayRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-quota402")
        guard case .quotaExhausted(let reason) = outcome else {
            Issue.record("expected quotaExhausted, got \(outcome)")
            return
        }
        #expect(reason == "payment required")
        #expect(relay.requestCount == 1)
        #expect(quota.polls == 1)
    }

    @Test func rateLimitCode1302WithCollidingLogidRidesTheBackoffRetry() async throws {
        // The live collision case: a 429 whose parsed code is 1302 (rate
        // limit) while the message text contains "1113…3009" — the logid
        // must NOT turn this into quota exhaustion or a concurrency ladder.
        let limited = MockRelayServer.Script.json(
            ["code": 1302, "msg": "rate limited, logid 11139999999999993009"],
            status: 429)
        let relay = MockRelayServer(scripts: [limited, limited])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let quota = RecordingQuotaCounter()
        let (context, directory) = try makeRelayContext(
            control: control, directoryLabel: "rl1302", quota: quota)
        defer { try? FileManager.default.removeItem(at: directory) }
        context.rateLimitBackoff = 0.05
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let outcome = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(model: "glm-5.3"),
            target: relayRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-rl1302")
        guard case .rateLimitedAfterRetry = outcome else {
            Issue.record("expected rateLimitedAfterRetry, got \(outcome)")
            return
        }
        #expect(relay.requestCount == 2)  // initial + exactly one retry
        #expect(quota.polls == 0)         // not quota — no poll tick
    }

    @Test func rateLimitCode1302OnNon429StatusStillRetriesOnce() async throws {
        // Classification, not status, drives remediation: a 400 carrying
        // 1302 enters the same single-backoff-retry policy and recovers.
        let relay = MockRelayServer(scripts: [
            .json(["code": 1302, "msg": "rate limited"], status: 400),
            .json(["id": "msg_rl_recovered"]),
        ])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let (context, directory) = try makeRelayContext(control: control, directoryLabel: "rl400")
        defer { try? FileManager.default.removeItem(at: directory) }
        context.rateLimitBackoff = 0.05
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let outcome = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(model: "glm-5.3"),
            target: relayRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-rl400")
        guard case .responded(let response) = outcome else {
            Issue.record("expected responded (recovered), got \(outcome)")
            return
        }
        #expect(response.status == .ok)
        #expect(relay.requestCount == 2)
    }

    @Test func concurrencyLimitedRetriesTwiceWithJitteredBackoffThenCallerFallback() async throws {
        let limited = MockRelayServer.Script.json(
            ["code": 3009, "msg": "concurrent request limit reached"], status: 429)
        let relay = MockRelayServer(scripts: [limited, limited, limited])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let (context, directory) = try makeRelayContext(control: control, directoryLabel: "conc")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sleeper = SleepRecorder()
        context.concurrencySleeper = { delay in sleeper.record(delay) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let outcome = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(model: "glm-5.3"),
            target: relayRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-conc")
        guard case .concurrencyLimitedAfterRetries = outcome else {
            Issue.record("expected concurrencyLimitedAfterRetries, got \(outcome)")
            return
        }
        // Initial send + exactly two in-place retries.
        #expect(relay.requestCount == 3)
        #expect(sleeper.delays.count == 2)
        // 3 s ± 1 s, then 6 s ± 1 s.
        #expect(sleeper.delays[0] >= 2 && sleeper.delays[0] <= 4)
        #expect(sleeper.delays[1] >= 5 && sleeper.delays[1] <= 7)
    }

    @Test func concurrencyLimitedRetryRecoversAfterFirstBackoff() async throws {
        let relay = MockRelayServer(scripts: [
            .json(["code": 3008, "msg": "concurrent limit"], status: 429),
            .json(["id": "msg_conc_recovered"]),
        ])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let (context, directory) = try makeRelayContext(control: control, directoryLabel: "concok")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sleeper = SleepRecorder()
        context.concurrencySleeper = { delay in sleeper.record(delay) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let outcome = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(model: "glm-5.3"),
            target: relayRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-concok")
        guard case .responded(let response) = outcome else {
            Issue.record("expected responded (recovered), got \(outcome)")
            return
        }
        #expect(response.status == .ok)
        #expect(relay.requestCount == 2)
        #expect(sleeper.delays.count == 1)
        #expect(sleeper.delays[0] >= 2 && sleeper.delays[0] <= 4)
    }

    @Test func riskControl405DoesNotRetryEmitsEventSurfaces502Class() async throws {
        let relay = MockRelayServer(scripts: [.json(["msg": "Method Not Allowed"], status: 405)])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let riskReasons = RiskEventRecorder()
        let (context, directory) = try makeRelayContext(
            control: control, directoryLabel: "risk405",
            onRiskControl: { reason in riskReasons.record(reason) })
        defer { try? FileManager.default.removeItem(at: directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let outcome = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(model: "glm-5.3"),
            target: relayRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-risk405")
        guard case .riskControl(let reason) = outcome else {
            Issue.record("expected riskControl, got \(outcome)")
            return
        }
        #expect(reason == "Method Not Allowed")
        #expect(riskReasons.reasons == ["Method Not Allowed"])
        #expect(relay.requestCount == 1)  // no retry
    }

    @Test func riskControlCode3012On400DoesNotRetry() async throws {
        let relay = MockRelayServer(scripts: [.json(
            ["code": 3012, "msg": "risk control triggered"], status: 400)])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let riskReasons = RiskEventRecorder()
        let (context, directory) = try makeRelayContext(
            control: control, directoryLabel: "risk3012",
            onRiskControl: { reason in riskReasons.record(reason) })
        defer { try? FileManager.default.removeItem(at: directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let outcome = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(model: "glm-5.3"),
            target: relayRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-risk3012")
        guard case .riskControl(let reason) = outcome else {
            Issue.record("expected riskControl, got \(outcome)")
            return
        }
        #expect(reason == "risk control triggered")
        #expect(riskReasons.reasons.count == 1)
        #expect(relay.requestCount == 1)
    }

    @Test func captcha3007SurfacesAsIsNeverSolved() async throws {
        let script = MockRelayServer.Script.json(
            ["code": 3007, "msg": "captcha challenge required"], status: 400)
        let relay = MockRelayServer(scripts: [script])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let (context, directory) = try makeRelayContext(control: control, directoryLabel: "captcha")
        defer { try? FileManager.default.removeItem(at: directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let outcome = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(model: "glm-5.3"),
            target: relayRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-captcha")
        guard case .responded(let response) = outcome else {
            Issue.record("expected responded (captcha passthrough), got \(outcome)")
            return
        }
        #expect(Int(response.status.code) == 400)
        var body = Data()
        for try await chunk in response.body {
            if let bytes = chunk.getData(at: chunk.readerIndex, length: chunk.readableBytes) {
                body.append(bytes)
            }
        }
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["code"] as? Int == 3007)
        #expect(relay.requestCount == 1)  // no retry, no solve attempt
    }

    @Test func surfaceAsIsClassesPassThroughWithoutRetry() async throws {
        // 3006 (model), 1210 (max_tokens), 1114 (nonexistent): all surface
        // verbatim — 1114 in particular must never enter a remediation class.
        let cases: [[String: Any]] = [
            ["code": 3006, "msg": "model not allowed"],
            ["code": 1210, "msg": "max_tokens out of range"],
            ["code": 1114, "msg": "unknown code, logid 11149999999999993009"],
        ]
        let relay = MockRelayServer(scripts: cases.map {
            .json($0, status: 400)
        })
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let (context, directory) = try makeRelayContext(control: control, directoryLabel: "asis")
        defer { try? FileManager.default.removeItem(at: directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        for (index, _) in cases.enumerated() {
            let outcome = await RelayTarget.execute(
                head: postHead(), bodyData: requestBody(model: "glm-5.3"),
                target: relayRouteTarget(port: port), httpClient: httpClient,
                context: context, requestID: "t-asis-\(index)")
            guard case .responded(let response) = outcome else {
                Issue.record("expected responded (passthrough), got \(outcome)")
                return
            }
            #expect(Int(response.status.code) == 400)
        }
        #expect(relay.requestCount == 3)  // one send each, no retries
    }

    @Test func businessEnvelopeOn200IsClassifiedNotRelayedAsSuccess() async throws {
        // A 200 whose JSON body carries code 1113 is quota exhaustion, not a
        // success — classified, no retry, quota ticked.
        let relay = MockRelayServer(scripts: [.json(
            ["code": 1113, "msg": "insufficient quota"], status: 200)])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let quota = RecordingQuotaCounter()
        let (context, directory) = try makeRelayContext(
            control: control, directoryLabel: "env200", quota: quota)
        defer { try? FileManager.default.removeItem(at: directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let outcome = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(model: "glm-5.3"),
            target: relayRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-env200")
        guard case .quotaExhausted(let reason) = outcome else {
            Issue.record("expected quotaExhausted from 200 envelope, got \(outcome)")
            return
        }
        #expect(reason == "insufficient quota")
        #expect(relay.requestCount == 1)
        #expect(quota.polls == 1)
    }

    @Test func businessEnvelope1302On200RidesTheRateLimitRetryTerminally() async throws {
        // 200 + code 1302: enters the rate-limit policy; the retry's own
        // 200-envelope 1302 is terminal (bounded ladder — no re-entry).
        let limited = MockRelayServer.Script.json(
            ["code": 1302, "msg": "rate limited in a 200"], status: 200)
        let relay = MockRelayServer(scripts: [limited, limited])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let (context, directory) = try makeRelayContext(control: control, directoryLabel: "env1302")
        defer { try? FileManager.default.removeItem(at: directory) }
        context.rateLimitBackoff = 0.05
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let outcome = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(model: "glm-5.3"),
            target: relayRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-env1302")
        guard case .rateLimitedAfterRetry = outcome else {
            Issue.record("expected rateLimitedAfterRetry, got \(outcome)")
            return
        }
        #expect(relay.requestCount == 2)
    }

    @Test func legitNonStreaming200JSONSuccessRelaysByteIdentical() async throws {
        // An Anthropic non-streaming success IS application/json — the
        // 200-envelope check must not eat it (no top-level `code`).
        let body = try JSONSerialization.data(withJSONObject: [
            "id": "msg_ns", "type": "message", "role": "assistant",
            "content": [["type": "text", "text": "héllo"]],
            "model": "GLM-5.3", "stop_reason": "end_turn",
        ])
        let relay = MockRelayServer(scripts: [
            MockRelayServer.Script(
                status: 200, headers: ["content-type": "application/json"], chunks: [body])
        ])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let (context, directory) = try makeRelayContext(control: control, directoryLabel: "ns200")
        defer { try? FileManager.default.removeItem(at: directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let outcome = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(model: "glm-5.3"),
            target: relayRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-ns200")
        guard case .responded(let response) = outcome else {
            Issue.record("expected responded, got \(outcome)")
            return
        }
        #expect(response.status == .ok)
        var relayed = Data()
        for try await chunk in response.body {
            if let bytes = chunk.getData(at: chunk.readerIndex, length: chunk.readableBytes) {
                relayed.append(bytes)
            }
        }
        #expect(relayed == body)
    }

    @Test func oversizedJSON200SuccessIsNotDrainedOrMangled() async throws {
        // content-length beyond envelope size: cannot be a business
        // envelope — the stream relays untouched, so a >8 KiB success
        // survives byte-identical (no truncating peek).
        let text = String(repeating: "x", count: 9000)
        let body = Data("{\"id\":\"msg_big\",\"type\":\"message\",\"content\":\"\(text)\"}".utf8)
        #expect(body.count > 8192)
        let relay = MockRelayServer(scripts: [
            MockRelayServer.Script(
                status: 200, headers: ["content-type": "application/json"], chunks: [body])
        ])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let (context, directory) = try makeRelayContext(control: control, directoryLabel: "big200")
        defer { try? FileManager.default.removeItem(at: directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let outcome = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(model: "glm-5.3"),
            target: relayRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-big200")
        guard case .responded(let response) = outcome else {
            Issue.record("expected responded, got \(outcome)")
            return
        }
        #expect(response.status == .ok)
        var relayed = Data()
        for try await chunk in response.body {
            if let bytes = chunk.getData(at: chunk.readerIndex, length: chunk.readableBytes) {
                relayed.append(bytes)
            }
        }
        #expect(relayed == body)
    }

    @Test func codeZero200BodyRelaysAsSuccess() async throws {
        // Business success envelope (`code` 0): NOT an error envelope —
        // relayed as-is per the `code != 0` gate.
        let relay = MockRelayServer(scripts: [.json(["code": 0, "msg": "ok", "data": ["n": 1]])])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let (context, directory) = try makeRelayContext(control: control, directoryLabel: "zero200")
        defer { try? FileManager.default.removeItem(at: directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let outcome = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(model: "glm-5.3"),
            target: relayRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-zero200")
        guard case .responded(let response) = outcome else {
            Issue.record("expected responded, got \(outcome)")
            return
        }
        #expect(response.status == .ok)
        #expect(relay.requestCount == 1)
    }

    @Test func quotaPollDoesNotTickForBare429s() async throws {
        // The immediate poll is the exhausted-class remediation only: a
        // bare (unclassifiable) 429 goes through the retry without polling.
        let limited = MockRelayServer.Script.json(
            ["type": "error", "error": ["type": "rate_limit_error", "message": "rate limited"]],
            status: 429)
        let relay = MockRelayServer(scripts: [limited, limited])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let quota = RecordingQuotaCounter()
        let (context, directory) = try makeRelayContext(
            control: control, directoryLabel: "bare429", quota: quota)
        defer { try? FileManager.default.removeItem(at: directory) }
        context.rateLimitBackoff = 0.05
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let outcome = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(model: "glm-5.3"),
            target: relayRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-bare429")
        guard case .rateLimitedAfterRetry = outcome else {
            Issue.record("expected rateLimitedAfterRetry, got \(outcome)")
            return
        }
        #expect(relay.requestCount == 2)
        #expect(quota.relayed == 1)
        #expect(quota.polls == 0)
    }

    // MARK: - Ladder bounds (fix round 1: no re-entry from inside a retry ladder)

    @Test func rateLimitCarrierOnNon429StatusCannotLoopTheLadder() async throws {
        // Adversarial carrier: HTTP 400 + {"code":1302} forever. The entry
        // classification starts the single-backoff-retry policy once; the
        // retry's re-classified carrier must be TERMINAL — bounded at
        // exactly 2 upstream requests, client gets the rate-limit fallback.
        let carrier = MockRelayServer.Script.json(
            ["code": 1302, "msg": "rate limited"], status: 400)
        let relay = MockRelayServer(scripts: Array(repeating: carrier, count: 12))
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let (context, directory) = try makeRelayContext(control: control, directoryLabel: "loop1302")
        defer { try? FileManager.default.removeItem(at: directory) }
        context.rateLimitBackoff = 0.05
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let outcome = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(model: "glm-5.3"),
            target: relayRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-loop1302")
        guard case .rateLimitedAfterRetry = outcome else {
            Issue.record("expected rateLimitedAfterRetry, got \(outcome)")
            return
        }
        // Exactly initial + one backoff retry — a looping carrier buys no
        // further ladders (12 scripted carriers would otherwise all burn).
        #expect(relay.requestCount == 2)
    }

    @Test func concurrencyCarrierOnNon200StatusCannotLoopTheLadder() async throws {
        // Adversarial carrier inside the concurrency ladder: entry 429 +
        // {"code":3009}, every retry answered HTTP 400 + {"code":3008}. The
        // re-classified concurrency carrier must be TERMINAL — bounded at
        // exactly 2 upstream requests, client gets the fallback outcome.
        let entry = MockRelayServer.Script.json(
            ["code": 3009, "msg": "concurrent limit"], status: 429)
        let carrier = MockRelayServer.Script.json(
            ["code": 3008, "msg": "concurrent limit"], status: 400)
        let relay = MockRelayServer(scripts: [entry] + Array(repeating: carrier, count: 12))
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let (context, directory) = try makeRelayContext(control: control, directoryLabel: "loop3008")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sleeper = SleepRecorder()
        context.concurrencySleeper = { delay in sleeper.record(delay) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let outcome = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(model: "glm-5.3"),
            target: relayRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-loop3008")
        guard case .concurrencyLimitedAfterRetries = outcome else {
            Issue.record("expected concurrencyLimitedAfterRetries, got \(outcome)")
            return
        }
        // Entry + first concurrency retry only: the 400+3008 carrier ends
        // the ladder instead of spawning a fresh 2-attempt one per cycle.
        #expect(relay.requestCount == 2)
        #expect(sleeper.delays.count == 1)
    }

    @Test func concurrencyEnvelopeInsideRateLimitLadderIsTerminal() async throws {
        // Mixed carriers: entry 429 + {"code":1302} starts the rate-limit
        // policy; its retry answers 200 + {"code":3008}. The envelope's
        // concurrency class must be TERMINAL inside the rate-limit ladder —
        // no fresh concurrency ladder from within a retry.
        let entry = MockRelayServer.Script.json(
            ["code": 1302, "msg": "rate limited"], status: 429)
        let envelope = MockRelayServer.Script.json(
            ["code": 3008, "msg": "concurrent limit"], status: 200)
        let relay = MockRelayServer(scripts: [entry, envelope, envelope, envelope])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let (context, directory) = try makeRelayContext(control: control, directoryLabel: "mix3008")
        defer { try? FileManager.default.removeItem(at: directory) }
        context.rateLimitBackoff = 0.05
        let sleeper = SleepRecorder()
        context.concurrencySleeper = { delay in sleeper.record(delay) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let outcome = await RelayTarget.execute(
            head: postHead(), bodyData: requestBody(model: "glm-5.3"),
            target: relayRouteTarget(port: port), httpClient: httpClient,
            context: context, requestID: "t-mix3008")
        guard case .concurrencyLimitedAfterRetries = outcome else {
            Issue.record("expected concurrencyLimitedAfterRetries, got \(outcome)")
            return
        }
        #expect(relay.requestCount == 2)      // entry + rate-limit retry only
        #expect(sleeper.delays.isEmpty)       // no concurrency ladder spawned
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
            session: session, signed: false,
            identity: RelayTarget.SessionIdentity(id: "sid", type: "main"),
            zcodeAuthorization: "synthetic-zcode-jwt")
        let names = headers.map { $0.name }
        let authorization = try #require(names.firstIndex(of: "authorization"))
        #expect(names.firstIndex(of: "x-zcode-authorization") == authorization + 1)
        #expect(headers["x-zcode-authorization"] == ["Bearer synthetic-zcode-jwt"])

        let bare = try RelayTarget.relayHeaders(
            session: session, signed: false,
            identity: RelayTarget.SessionIdentity(id: "sid", type: "main"))
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
        relayPort: Int, backupPort: Int?, fallbackEdgePort: Int? = nil,
        matchClass: ModelClass? = nil
    ) throws -> ForwardFixture {
        let relayVendorID = UUID()
        var vendors = [Vendor(
            id: relayVendorID, name: "ZCode Relay",
            baseURL: "http://127.0.0.1:\(relayPort)/api/v1/ultra-zai/anthropic",
            apiKey: "", readTimeoutSeconds: 10, vendorKind: .relay)]
        var mapping = ModelMapping(
            sourceModel: matchClass.map { "\($0.rawValue) class" } ?? "claude-sonnet-5",
            targetModel: "glm-5.3",
            targetVendorID: relayVendorID, isEnabled: true,
            matchClass: matchClass)
        if fallbackEdgePort != nil {
            // The Task-7 fallback edge: keyless until the mint, canonicalized
            // models, Claude-only fields stripped.
            let edgeVendor = Vendor(
                id: UUID(), name: "z.ai API key (fallback)",
                baseURL: "http://127.0.0.1:\(fallbackEdgePort!)/api/anthropic",
                apiKey: "", readTimeoutSeconds: 10,
                supportsThinkingBlocks: true,
                stripsClaudeOnlyRequestFields: true,
                applyGLMCanonicalization: true)
            vendors.append(edgeVendor)
            mapping.backupTargetVendorID = edgeVendor.id
            mapping.backupTargetModel = "glm-5.3"
        } else if let backupPort {
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

    // MARK: - ProxyForwarder + taxonomy terminals (relay fidelity Task 6)

    @Test func forwardQuotaExhaustedAnswers429ShapedError() async throws {
        let relay = MockRelayServer(scripts: [.json(
            ["code": 1113, "msg": "insufficient quota"], status: 429)])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let (context, _) = try makeRelayContext(control: control, directoryLabel: "fwd429q")
        let fixture = try makeForwardFixture(relayPort: port, backupPort: nil)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let client = EmbeddedChannel()
        await forward(fixture, httpClient: httpClient, context: context, channel: client)
        let (head, body, sawEnd) = try drainClientResponse(client)
        #expect(head.status == .tooManyRequests)
        #expect(sawEnd)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["type"] as? String == "rate_limit_error")
        #expect((error["message"] as? String)?.localizedCaseInsensitiveContains("quota") == true)
        // No retry: exactly one relay request.
        #expect(relay.requestCount == 1)
        finishChannel(client)
    }

    @Test func forwardRiskControlAnswersClear502() async throws {
        let relay = MockRelayServer(scripts: [.json(
            ["code": 3012, "msg": "risk control triggered"], status: 400)])
        let port = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let (context, _) = try makeRelayContext(control: control, directoryLabel: "fwd502risk")
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
        #expect((error["message"] as? String)?.localizedCaseInsensitiveContains("risk control") == true)
        #expect(relay.requestCount == 1)  // no retry
        finishChannel(client)
    }

    @Test func forwardConcurrencyLimitedAfterRetriesFallsBackToBackupVendor() async throws {
        let limited = MockRelayServer.Script.json(
            ["code": 3009, "msg": "concurrent limit"], status: 429)
        let relay = MockRelayServer(scripts: [limited, limited, limited])
        let relayPort = try await relay.start()
        let backup = MockRelayServer(scripts: [.json(["id": "msg_backup_conc"])])
        let backupPort = try await backup.start()
        defer {
            Task { await relay.shutdown() }
            Task { await backup.shutdown() }
        }
        let control = SigningControl()
        let (context, _) = try makeRelayContext(control: control, directoryLabel: "fwdconc")
        let sleeper = SleepRecorder()
        context.concurrencySleeper = { delay in sleeper.record(delay) }
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
        #expect(json["id"] as? String == "msg_backup_conc")
        // Initial send + both in-place retries on the relay; backup serves.
        #expect(relay.requestCount == 3)
        #expect(backup.requestCount == 1)
        #expect(sleeper.delays.count == 2)
        finishChannel(client)
    }

    // MARK: - ProxyForwarder + Task 7 (degraded machine, fallback edge)

    /// Lock-guarded mutable clock for RelayHealth injection.
    private final class HealthClock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = Date()

        func advance(_ seconds: TimeInterval) {
            lock.lock(); instant = instant.addingTimeInterval(seconds); lock.unlock()
        }

        var now: Date {
            lock.lock(); defer { lock.unlock() }
            return instant
        }
    }

    /// The full mint chain served in-memory (info → list → copy) with an
    /// incrementing secret per run, so a forced re-mint mints a NEW key.
    /// `fixedSecret` pins every run to secret-1 (the re-mint-returns-same-
    /// key case).
    private final class EdgeMintStub: @unchecked Sendable {
        private let lock = NSLock()
        private var _runs = 0
        private var _secretIndex = 0
        var fixedSecret = false

        var runs: Int {
            lock.lock(); defer { lock.unlock() }
            return _runs
        }

        func respond(path: String) throws -> (Int, Data) {
            func json(_ object: [String: Any]) -> Data {
                (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            }
            if path.contains("getCustomerInfo") {
                lock.lock(); _runs += 1; lock.unlock()
                return (200, json(["code": 0, "data": ["organizations": [
                    ["id": "org-1", "name": "默认机构", "projects": [["id": "proj-1", "name": "默认项目"]]],
                ]]]))
            }
            if path.contains("/copy/") {
                lock.lock()
                _secretIndex += 1
                let secret = fixedSecret ? "secret-1" : "secret-\(_secretIndex)"
                lock.unlock()
                return (200, json(["code": 0, "data": ["secretKey": secret]]))
            }
            if path.hasSuffix("/api_keys") {
                return (200, json(["code": 0, "data": ["list": [["id": "apiKey-1", "name": "zcode-api-key"]]]]))
            }
            throw NSError(domain: "EdgeMintStub", code: 1)
        }
    }

    /// A RelayHealth whose fallback edge is the fixture's stub edge.
    private func makeEdgeHealth(
        edgePort: Int, clock: HealthClock = HealthClock(), stub: EdgeMintStub
    ) -> (RelayHealth, HealthClock) {
        var minterConfiguration = ApiKeyMinter.Configuration()
        minterConfiguration.bizJWTProvider = { "biz-jwt" }
        minterConfiguration.execute = { request in
            try stub.respond(path: request.url?.path ?? "")
        }
        var configuration = RelayHealth.Configuration()
        configuration.fallbackEdgeBaseURL = "http://127.0.0.1:\(edgePort)/api/anthropic"
        configuration.minter = ApiKeyMinter(configuration: minterConfiguration)
        configuration.now = { clock.now }
        return (RelayHealth(configuration: configuration), clock)
    }

    @Test func forwardSigningFailureServesViaFallbackEdge() async throws {
        let relay = MockRelayServer(scripts: [])
        let relayPort = try await relay.start()
        let edge = MockRelayServer(scripts: [.json(["id": "msg_edge_1"])])
        let edgePort = try await edge.start()
        defer {
            Task { await relay.shutdown() }
            Task { await edge.shutdown() }
        }
        let control = SigningControl()
        control.failHandshakeFromCount = 0  // every handshake fails
        let stub = EdgeMintStub()
        let (health, _) = makeEdgeHealth(edgePort: edgePort, stub: stub)
        let (context, _) = try makeRelayContext(
            control: control, directoryLabel: "fwdedge", relayHealth: health)
        let fixture = try makeForwardFixture(relayPort: relayPort, backupPort: nil, fallbackEdgePort: edgePort)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let client = EmbeddedChannel()
        await forward(fixture, httpClient: httpClient, context: context, channel: client)
        let (head, body, sawEnd) = try drainClientResponse(client)
        #expect(head.status == .ok)
        #expect(sawEnd)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["id"] as? String == "msg_edge_1")

        // Nothing reached the relay; the edge served with the minted
        // credential on x-api-key (no authorization), GLM-canonical model.
        #expect(relay.requestCount == 0)
        #expect(stub.runs == 1)
        let edgeRequest = try #require(edge.requests.first)
        #expect(edgeRequest.headers["x-api-key"] == "apiKey-1.secret-1")
        #expect(edgeRequest.headers["authorization"] == nil)
        let sentJSON = try #require(try JSONSerialization.jsonObject(with: edgeRequest.body) as? [String: Any])
        #expect(sentJSON["model"] as? String == "GLM-5.3")  // glm-5.3 → canonical

        // The machine entered degraded with the base probe interval.
        let state = await health.currentState()
        guard case .degradedSigning(_, let backoff) = state else {
            Issue.record("expected degradedSigning, got \(state)"); return
        }
        #expect(backoff == 60)
        finishChannel(client)
    }

    @Test func forwardDegradedServesFallbackUntilProbeRecovers() async throws {
        let relay = MockRelayServer(scripts: [.json(["id": "msg_relay_ok"])])
        let relayPort = try await relay.start()
        let edge = MockRelayServer(scripts: [
            .json(["id": "msg_edge_1"]), .json(["id": "msg_edge_2"]),
        ])
        let edgePort = try await edge.start()
        defer {
            Task { await relay.shutdown() }
            Task { await edge.shutdown() }
        }
        let control = SigningControl()
        control.failHandshakeFromCount = 0  // handshake fails (nothing reaches the relay)
        let stub = EdgeMintStub()
        let (health, clock) = makeEdgeHealth(edgePort: edgePort, stub: stub)
        let (context, _) = try makeRelayContext(
            control: control, directoryLabel: "fwdprobe", relayHealth: health)
        let fixture = try makeForwardFixture(relayPort: relayPort, backupPort: nil, fallbackEdgePort: edgePort)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        // Request 1 (healthy → attempt): handshake fails → degraded, edge serves.
        let client1 = EmbeddedChannel()
        await forward(fixture, httpClient: httpClient, context: context, channel: client1)
        let (head1, body1, _) = try drainClientResponse(client1)
        #expect(head1.status == .ok)
        #expect(try JSONSerialization.jsonObject(with: body1) as? [String: Any] != nil)
        finishChannel(client1)

        // Request 2 (degraded, probe not due): edge serves with NO relay work.
        let client2 = EmbeddedChannel()
        await forward(fixture, httpClient: httpClient, context: context, channel: client2)
        let (head2, _, _) = try drainClientResponse(client2)
        #expect(head2.status == .ok)
        #expect(relay.requestCount == 0)
        #expect(edge.requestCount == 2)
        finishChannel(client2)

        // Request 3 (probe due after the base interval): the chain recovered
        // (handshakes succeed again) — the relay serves and health resets.
        control.failHandshakeFromCount = nil
        clock.advance(61)
        let client3 = EmbeddedChannel()
        await forward(fixture, httpClient: httpClient, context: context, channel: client3)
        let (head3, body3, _) = try drainClientResponse(client3)
        #expect(head3.status == .ok)
        let json3 = try #require(try JSONSerialization.jsonObject(with: body3) as? [String: Any])
        #expect(json3["id"] as? String == "msg_relay_ok")
        #expect(relay.requestCount == 1)
        #expect(edge.requestCount == 2)  // unchanged — the probe served from the relay
        #expect(await health.currentState() == .healthy)
        finishChannel(client3)
    }

    @Test func forwardCredentialsExpiredServesFallbackWithoutDegrading() async throws {
        let relay = MockRelayServer(scripts: [])
        let relayPort = try await relay.start()
        let edge = MockRelayServer(scripts: [.json(["id": "msg_edge_expired"])])
        let edgePort = try await edge.start()
        defer {
            Task { await relay.shutdown() }
            Task { await edge.shutdown() }
        }
        // Cold cache + no store + a location: the chain can only answer
        // reloginRequired — the credentialsExpired outcome.
        let control = SigningControl()
        let stub = EdgeMintStub()
        let (health, _) = makeEdgeHealth(edgePort: edgePort, stub: stub)
        let events = CredentialEventChannel()
        let (context, _) = try makeRelayContext(
            control: control, events: events, directoryLabel: "fwdcredexp",
            relayHealth: health, seedCache: false)
        let fixture = try makeForwardFixture(relayPort: relayPort, backupPort: nil, fallbackEdgePort: edgePort)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let client = EmbeddedChannel()
        await forward(fixture, httpClient: httpClient, context: context, channel: client)
        let (head, body, sawEnd) = try drainClientResponse(client)
        #expect(head.status == .ok)
        #expect(sawEnd)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["id"] as? String == "msg_edge_expired")
        #expect(relay.requestCount == 0)

        // No probe state was entered (recovery = re-login) and the re-login
        // event surfaced.
        #expect(await health.currentState() == .healthy)
        #expect(events.events.contains { event in
            if case .expired = event { return true }
            return false
        })
        finishChannel(client)
    }

    @Test func forwardRiskControlServesFallbackThenBlocksRelayAttempts() async throws {
        let riskBody = MockRelayServer.Script.json(
            ["code": 3012, "msg": "risk control triggered"], status: 400)
        let relay = MockRelayServer(scripts: [riskBody])
        let relayPort = try await relay.start()
        let edge = MockRelayServer(scripts: [
            .json(["id": "msg_edge_risk_1"]), .json(["id": "msg_edge_risk_2"]),
        ])
        let edgePort = try await edge.start()
        defer {
            Task { await relay.shutdown() }
            Task { await edge.shutdown() }
        }
        let control = SigningControl()
        let stub = EdgeMintStub()
        let (health, _) = makeEdgeHealth(edgePort: edgePort, stub: stub)
        let (context, _) = try makeRelayContext(
            control: control, directoryLabel: "fwdrisk7", relayHealth: health)
        let fixture = try makeForwardFixture(relayPort: relayPort, backupPort: nil, fallbackEdgePort: edgePort)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        // Request 1: the relay's risk answer starts the cooldown; the edge serves.
        let client1 = EmbeddedChannel()
        await forward(fixture, httpClient: httpClient, context: context, channel: client1)
        let (head1, body1, _) = try drainClientResponse(client1)
        #expect(head1.status == .ok)
        let json1 = try #require(try JSONSerialization.jsonObject(with: body1) as? [String: Any])
        #expect(json1["id"] as? String == "msg_edge_risk_1")
        #expect(relay.requestCount == 1)

        // Request 2 (cooldown active): the relay attempt is BLOCKED — the
        // edge serves again without any relay work.
        let client2 = EmbeddedChannel()
        await forward(fixture, httpClient: httpClient, context: context, channel: client2)
        let (head2, body2, _) = try drainClientResponse(client2)
        #expect(head2.status == .ok)
        let json2 = try #require(try JSONSerialization.jsonObject(with: body2) as? [String: Any])
        #expect(json2["id"] as? String == "msg_edge_risk_2")
        #expect(relay.requestCount == 1)
        #expect(edge.requestCount == 2)
        finishChannel(client1)
        finishChannel(client2)
    }

    @Test func forwardRiskCooldownWithoutFallbackAnswersClear502() async throws {
        let riskBody = MockRelayServer.Script.json(
            ["code": 3012, "msg": "risk control triggered"], status: 400)
        let relay = MockRelayServer(scripts: [riskBody])
        let relayPort = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        let (health, _) = makeEdgeHealth(edgePort: 1, stub: EdgeMintStub())
        let (context, _) = try makeRelayContext(
            control: control, directoryLabel: "fwdrisk502", relayHealth: health)
        let fixture = try makeForwardFixture(relayPort: relayPort, backupPort: nil)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        // Request 1 surfaces the risk 502 and starts the cooldown.
        let client1 = EmbeddedChannel()
        await forward(fixture, httpClient: httpClient, context: context, channel: client1)
        let (head1, body1, sawEnd1) = try drainClientResponse(client1)
        #expect(head1.status == .badGateway)
        #expect(sawEnd1)
        let error1 = try #require(
            (try JSONSerialization.jsonObject(with: body1) as? [String: Any])?["error"] as? [String: Any])
        #expect((error1["message"] as? String)?.localizedCaseInsensitiveContains("risk") == true)

        // Request 2: cooldown + no fallback → the clear blocked-502, and
        // the relay is never touched again.
        let client2 = EmbeddedChannel()
        await forward(fixture, httpClient: httpClient, context: context, channel: client2)
        let (head2, body2, _) = try drainClientResponse(client2)
        #expect(head2.status == .badGateway)
        let error2 = try #require(
            (try JSONSerialization.jsonObject(with: body2) as? [String: Any])?["error"] as? [String: Any])
        #expect((error2["message"] as? String)?.localizedCaseInsensitiveContains("cooldown") == true)
        #expect(relay.requestCount == 1)
        finishChannel(client1)
        finishChannel(client2)
    }

    @Test func forwardFallback401RemintsOnceAndRetries() async throws {
        let relay = MockRelayServer(scripts: [])
        let relayPort = try await relay.start()
        let edge = MockRelayServer(scripts: [
            .json(["error": ["type": "authentication_error", "message": "bad key"]], status: 401),
            .json(["id": "msg_edge_after_remint"]),
        ])
        let edgePort = try await edge.start()
        defer {
            Task { await relay.shutdown() }
            Task { await edge.shutdown() }
        }
        let control = SigningControl()
        control.failHandshakeFromCount = 0
        let stub = EdgeMintStub()
        let (health, _) = makeEdgeHealth(edgePort: edgePort, stub: stub)
        let (context, _) = try makeRelayContext(
            control: control, directoryLabel: "fwd401", relayHealth: health)
        let fixture = try makeForwardFixture(relayPort: relayPort, backupPort: nil, fallbackEdgePort: edgePort)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let client = EmbeddedChannel()
        await forward(fixture, httpClient: httpClient, context: context, channel: client)
        let (head, body, sawEnd) = try drainClientResponse(client)
        #expect(head.status == .ok)
        #expect(sawEnd)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["id"] as? String == "msg_edge_after_remint")

        // Exactly two edge exchanges (401 → re-mint → retry) and two mint
        // chain runs (initial + forced); the retry carried the NEW key.
        #expect(edge.requestCount == 2)
        #expect(stub.runs == 2)
        let retry = try #require(edge.requests.last)
        #expect(retry.headers["x-api-key"] == "apiKey-1.secret-2")
        finishChannel(client)
    }

    @Test func forwardFallback401SurfacesWhenRemintReturnsSameKey() async throws {
        let relay = MockRelayServer(scripts: [])
        let relayPort = try await relay.start()
        let unauthorized = MockRelayServer.Script.json(
            ["error": ["type": "authentication_error", "message": "bad key"]], status: 401)
        let edge = MockRelayServer(scripts: [unauthorized, unauthorized])
        let edgePort = try await edge.start()
        defer {
            Task { await relay.shutdown() }
            Task { await edge.shutdown() }
        }
        let control = SigningControl()
        control.failHandshakeFromCount = 0
        let stub = EdgeMintStub()
        stub.fixedSecret = true
        let (health, _) = makeEdgeHealth(edgePort: edgePort, stub: stub)
        let (context, _) = try makeRelayContext(
            control: control, directoryLabel: "fwd401same", relayHealth: health)
        let fixture = try makeForwardFixture(relayPort: relayPort, backupPort: nil, fallbackEdgePort: edgePort)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let client = EmbeddedChannel()
        await forward(fixture, httpClient: httpClient, context: context, channel: client)
        let (head, _, sawEnd) = try drainClientResponse(client)
        // One forced re-mint that yielded the same key: the 401 surfaces,
        // no retry loop.
        #expect(head.status == .unauthorized)
        #expect(sawEnd)
        #expect(edge.requestCount == 1)
        #expect(stub.runs == 2)
        finishChannel(client)
    }

    @Test func forwardFallbackNoBalanceSurfacesAndCoolsTheKey() async throws {
        // A HEALTHY relay (rate-limited after retry) still falls back — and
        // the fallback's no-balance answer must NOT launder relay state.
        let limited = MockRelayServer.Script.json(
            ["type": "error", "error": ["type": "rate_limit_error", "message": "rate limited"]],
            status: 429)
        let relay = MockRelayServer(scripts: [limited, limited, limited, limited, limited, limited])
        let relayPort = try await relay.start()
        let noBalance = MockRelayServer.Script.json(
            ["code": 1113, "msg": "insufficient quota"], status: 429)
        let edge = MockRelayServer(scripts: [noBalance, noBalance])
        let edgePort = try await edge.start()
        defer {
            Task { await relay.shutdown() }
            Task { await edge.shutdown() }
        }
        let control = SigningControl()
        let stub = EdgeMintStub()
        let (health, clock) = makeEdgeHealth(edgePort: edgePort, clock: HealthClock(), stub: stub)
        let (context, _) = try makeRelayContext(
            control: control, directoryLabel: "fwd1113", relayHealth: health)
        context.rateLimitBackoff = 0.05
        let fixture = try makeForwardFixture(relayPort: relayPort, backupPort: nil, fallbackEdgePort: edgePort)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        // Request 1: relay rate-limited after retry → fallback answers 1113;
        // the response surfaces and the KEY cools — the relay machine stays
        // healthy (never launder).
        let client1 = EmbeddedChannel()
        await forward(fixture, httpClient: httpClient, context: context, channel: client1)
        let (head1, body1, _) = try drainClientResponse(client1)
        #expect(head1.status == .tooManyRequests)
        let json1 = try #require(try JSONSerialization.jsonObject(with: body1) as? [String: Any])
        #expect((json1["code"] as? Int) == 1113)
        #expect(await health.currentState() == .healthy)
        #expect(await health.isFallbackKeyCooling() == true)
        finishChannel(client1)

        // Request 2 (within the 1 h key cooldown): the edge cannot serve, so
        // the configured-but-unserveable backup answers the 502-unreachable
        // terminal — the same shape the pre-Task-7 backup path produced.
        let client2 = EmbeddedChannel()
        await forward(fixture, httpClient: httpClient, context: context, channel: client2)
        let (head2, body2, _) = try drainClientResponse(client2)
        #expect(head2.status == .badGateway)
        let error2 = try #require(
            (try JSONSerialization.jsonObject(with: body2) as? [String: Any])?["error"] as? [String: Any])
        #expect((error2["message"] as? String)?.localizedCaseInsensitiveContains("unreachable") == true)
        #expect(relay.requestCount == 4)
        #expect(edge.requestCount == 1)  // the edge was never re-asked
        finishChannel(client2)

        // After the cooldown lifts the cached key serves again.
        clock.advance(3601)
        let client3 = EmbeddedChannel()
        await forward(fixture, httpClient: httpClient, context: context, channel: client3)
        let (head3, _, _) = try drainClientResponse(client3)
        #expect(head3.status == .tooManyRequests)  // the 1113 surfaces again, key re-cools
        #expect(relay.requestCount == 6)
        #expect(edge.requestCount == 2)
        finishChannel(client3)
    }

    @Test func forwardQuotaExhaustedDoesNotServeTheFallbackEdge() async throws {
        // The fallback edge bills the SAME weekly quota — a quota-exhausted
        // relay must answer its 429-shaped terminal, never the edge.
        let relay = MockRelayServer(scripts: [.json(
            ["code": 1113, "msg": "insufficient quota"], status: 429)])
        let relayPort = try await relay.start()
        let edge = MockRelayServer(scripts: [.json(["id": "should_not_serve"])])
        let edgePort = try await edge.start()
        defer {
            Task { await relay.shutdown() }
            Task { await edge.shutdown() }
        }
        let control = SigningControl()
        let (health, _) = makeEdgeHealth(edgePort: edgePort, stub: EdgeMintStub())
        let (context, _) = try makeRelayContext(
            control: control, directoryLabel: "fwdquota7", relayHealth: health)
        let fixture = try makeForwardFixture(relayPort: relayPort, backupPort: nil, fallbackEdgePort: edgePort)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let client = EmbeddedChannel()
        await forward(fixture, httpClient: httpClient, context: context, channel: client)
        let (head, body, _) = try drainClientResponse(client)
        #expect(head.status == .tooManyRequests)
        let error = try #require(
            (try JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? [String: Any])
        #expect(error["type"] as? String == "rate_limit_error")
        #expect(relay.requestCount == 1)
        #expect(edge.requestCount == 0)
        finishChannel(client)
    }

    // MARK: - Fix round 1, ruling 1 (direct edge serve for class rules)

    /// The route target ProxyServer pushes for the direct degraded serve.
    private func edgeRouteTarget(port: Int) -> RoutingSnapshot.RouteTarget {
        RoutingSnapshot.RouteTarget(
            baseURL: "http://127.0.0.1:\(port)/api/anthropic",
            apiKey: "",
            vendorName: "z.ai API key (fallback)",
            vendorID: UUID(),
            targetModel: nil,
            isPassthrough: false,
            connectTimeoutSeconds: 5,
            readTimeoutSeconds: 10,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly,
            supportsThinkingBlocks: true,
            stripsClaudeOnlyRequestFields: true,
            applyGLMCanonicalization: true)
    }

    @Test func forwardSigningFailureOnClassRuleServesEdgeDirectly() async throws {
        // Ruling 1: class rules carry no rule backup — a signing outage on
        // class-routed primary traffic must degrade to the edge DIRECTLY,
        // not terminal-502.
        let relay = MockRelayServer(scripts: [])
        let relayPort = try await relay.start()
        let edge = MockRelayServer(scripts: [.json(["id": "msg_edge_direct"])])
        let edgePort = try await edge.start()
        defer {
            Task { await relay.shutdown() }
            Task { await edge.shutdown() }
        }
        let control = SigningControl()
        control.failHandshakeFromCount = 0
        let stub = EdgeMintStub()
        let (health, _) = makeEdgeHealth(edgePort: edgePort, stub: stub)
        await health.configureFallbackEdgeTarget(edgeRouteTarget(port: edgePort))
        let (context, _) = try makeRelayContext(
            control: control, directoryLabel: "fwddirect", relayHealth: health)
        // A CLASS rule (opus), NO backup — the default matrix's tier shape.
        let fixture = try makeForwardFixture(relayPort: relayPort, backupPort: nil, matchClass: .opus)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let client = EmbeddedChannel()
        await forward(fixture, httpClient: httpClient, context: context, channel: client, model: "glm-5.3")
        let (head, body, sawEnd) = try drainClientResponse(client)
        #expect(head.status == .ok)
        #expect(sawEnd)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["id"] as? String == "msg_edge_direct")

        // The relay was never reached; the edge served the direct degrade
        // with the minted credential and the rule's tier model,
        // GLM-canonicalized.
        #expect(relay.requestCount == 0)
        #expect(stub.runs == 1)
        let edgeRequest = try #require(edge.requests.first)
        #expect(edgeRequest.headers["x-api-key"] == "apiKey-1.secret-1")
        #expect(edgeRequest.headers["authorization"] == nil)
        let sentJSON = try #require(try JSONSerialization.jsonObject(with: edgeRequest.body) as? [String: Any])
        #expect(sentJSON["model"] as? String == "GLM-5.3")  // rule target glm-5.3 → canonical
        finishChannel(client)
    }

    @Test func forwardQuotaExhaustedOnClassRuleNeverServesEdgeDirectly() async throws {
        // Quota stays excluded from the direct degrade (same weekly quota
        // pool): the 429-shaped terminal answers even with the edge
        // configured.
        let relay = MockRelayServer(scripts: [.json(
            ["code": 1113, "msg": "insufficient quota"], status: 429)])
        let relayPort = try await relay.start()
        let edge = MockRelayServer(scripts: [.json(["id": "never_served"])])
        let edgePort = try await edge.start()
        defer {
            Task { await relay.shutdown() }
            Task { await edge.shutdown() }
        }
        let control = SigningControl()
        let (health, _) = makeEdgeHealth(edgePort: edgePort, stub: EdgeMintStub())
        await health.configureFallbackEdgeTarget(edgeRouteTarget(port: edgePort))
        let (context, _) = try makeRelayContext(
            control: control, directoryLabel: "fwddirectq", relayHealth: health)
        let fixture = try makeForwardFixture(relayPort: relayPort, backupPort: nil, matchClass: .opus)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let client = EmbeddedChannel()
        await forward(fixture, httpClient: httpClient, context: context, channel: client, model: "glm-5.3")
        let (head, _, _) = try drainClientResponse(client)
        #expect(head.status == .tooManyRequests)
        #expect(relay.requestCount == 1)
        #expect(edge.requestCount == 0)
        finishChannel(client)
    }

    @Test func forwardDegradedWithoutConfiguredEdgeKeepsTodayTerminal() async throws {
        // No edge vendor configured (user removed it; migration 10 no longer
        // resurrects it): degraded admission finds no direct serve and the
        // signed-ladder terminal answers — today's behavior.
        let relay = MockRelayServer(scripts: [])
        let relayPort = try await relay.start()
        defer { Task { await relay.shutdown() } }
        let control = SigningControl()
        control.failHandshakeFromCount = 0
        let (health, _) = makeEdgeHealth(edgePort: 1, stub: EdgeMintStub())
        // fallbackEdgeTarget deliberately NOT configured (nil).
        let (context, _) = try makeRelayContext(
            control: control, directoryLabel: "fwddirectno", relayHealth: health)
        let fixture = try makeForwardFixture(relayPort: relayPort, backupPort: nil, matchClass: .opus)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let client = EmbeddedChannel()
        await forward(fixture, httpClient: httpClient, context: context, channel: client, model: "glm-5.3")
        let (head, body, sawEnd) = try drainClientResponse(client)
        #expect(head.status == .badGateway)
        #expect(sawEnd)
        let error = try #require(
            (try JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? [String: Any])
        #expect((error["message"] as? String)?.localizedCaseInsensitiveContains("signing") == true)
        #expect(relay.requestCount == 0)
        finishChannel(client)
    }
}

// MARK: - Regex helper

/// Minimal `=~` for the few shape asserts (no Foundation NSRegularExpression noise).
infix operator =~ : ComparisonPrecedence
private func =~ (lhs: String, rhs: String) -> Bool {
    lhs.range(of: rhs, options: .regularExpression) != nil
}

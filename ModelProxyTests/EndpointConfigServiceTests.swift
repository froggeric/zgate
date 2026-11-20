import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing
@testable import ZGate

/// Offline tests for `EndpointConfigService` — the lazy `agent/configs`
/// routing refresh. The endpoint is a local SwiftNIO stub on 127.0.0.1 and
/// the fetch runs through a real AsyncHTTPClient pointed at it, so TTL
/// cadence, single-flight, the 3 s timeout, and fail-open are exercised on
/// the production code path (only the origin is redirected). The clock is
/// injected for deterministic TTL/cooldown assertions.
struct EndpointConfigServiceTests {

    // MARK: - Fixtures

    private static let preRouting = "https://zcode.z.ai/api/v1/zcode-plan/anthropic"
    private static let ultraTarget = "https://zcode.z.ai/api/v1/ultra-zai/anthropic"
    private static let otherTarget = "https://zcode.z.ai/api/v1/ultra/anthropic"
    private static let requestURL = Self.preRouting + "/v1/messages"

    /// A one-entry flagged mapping envelope rewriting preRouting → `to`.
    private func mappingBody(to: String) -> Data {
        let entry: [String: Any] = [
            "from": Self.preRouting, "to": to, "zcodeAuthorizationHeader": "X-ZCode-Authorization"]
        let envelope: [String: Any] = [
            "code": 0, "data": ["proxyEndpoint": ["mapping": [entry]]]]
        return (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
    }

    // MARK: - Injected clock

    /// Lock-guarded mutable clock injected as `Configuration.now`.
    private final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant: Date
        init(_ date: Date) { instant = date }
        var now: Date {
            lock.lock(); defer { lock.unlock() }
            return instant
        }
        func advance(_ seconds: TimeInterval) {
            lock.lock(); instant = instant.addingTimeInterval(seconds); lock.unlock()
        }
    }

    // MARK: - Stub config endpoint (SwiftNIO, 127.0.0.1)

    /// Serves the config endpoint: records each request (path + headers),
    /// responds with scripted entries — popped in order — or a default
    /// 200 + `defaultBody` once the script queue runs dry.
    private final class ConfigStubServer: @unchecked Sendable {
        struct Recorded {
            let path: String
            let headers: [String: String]
        }

        /// One scripted response. `delayMs` holds the HEAD back (pre-head
        /// stall); `trickleHoldMs` sends the head + FIRST BYTE immediately,
        /// then holds the remainder — the head-then-stall/trickling body
        /// shape that a head-only deadline cannot catch.
        struct Script {
            var status = 200
            var body: Data
            var delayMs = 0
            var trickleHoldMs = 0
        }

        private let lock = NSLock()
        private var _requests: [Recorded] = []
        private var _scripts: [Script] = []
        var defaultBody: Data

        init(defaultBody: Data) { self.defaultBody = defaultBody }

        var requests: [Recorded] {
            lock.lock(); defer { lock.unlock() }
            return _requests
        }
        var requestCount: Int {
            lock.lock(); defer { lock.unlock() }
            return _requests.count
        }
        func queue(_ script: Script) {
            lock.lock(); _scripts.append(script); lock.unlock()
        }

        fileprivate func record(_ request: Recorded) {
            lock.lock(); _requests.append(request); lock.unlock()
        }
        fileprivate func takeScript() -> Script {
            lock.lock(); defer { lock.unlock() }
            if !_scripts.isEmpty { return _scripts.removeFirst() }
            return Script(body: defaultBody)
        }

        private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        private var serverChannel: (any Channel)?

        func start() async throws -> Int {
            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                        channel.pipeline.addHandler(ConfigStubHandler(server: self))
                    }
                }
            let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
            lock.lock(); serverChannel = channel; lock.unlock()
            return channel.localAddress?.port ?? 0
        }

        func shutdown() async {
            lock.lock()
            let channel = serverChannel
            serverChannel = nil
            lock.unlock()
            try? await channel?.close().get()
            try? await group.shutdownGracefully()
        }
    }

    private final class ConfigStubHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private let server: ConfigStubServer
        private var requestHead: HTTPRequestHead?

        init(server: ConfigStubServer) { self.server = server }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let head):
                requestHead = head
                var headers: [String: String] = [:]
                for (name, value) in head.headers {
                    headers[name.lowercased()] = value
                }
                server.record(ConfigStubServer.Recorded(path: head.uri, headers: headers))
            case .body: break  // GET — no body expected
            case .end:
                let script = server.takeScript()
                let head = requestHead
                requestHead = nil
                respond(context: context, script: script, requestURI: head?.uri ?? "/")
            }
        }

        private func respond(
            context: ChannelHandlerContext, script: ConfigStubServer.Script, requestURI: String
        ) {
            let channel = context.channel
            Task {
                if script.delayMs > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(script.delayMs) * 1_000_000)
                }
                var head = HTTPResponseHead(
                    version: .http1_1, status: HTTPResponseStatus(statusCode: script.status))
                head.headers.add(name: "content-type", value: "application/json")
                head.headers.add(name: "content-length", value: String(script.body.count))
                channel.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
                if script.trickleHoldMs > 0, !script.body.isEmpty {
                    // Head + first byte now; the remainder (and end) after
                    // the hold — the body stalls while the head arrived.
                    var first = channel.allocator.buffer(capacity: 1)
                    first.writeBytes(script.body.prefix(1))
                    channel.writeAndFlush(
                        NIOAny(HTTPServerResponsePart.body(.byteBuffer(first))), promise: nil)
                    try? await Task.sleep(nanoseconds: UInt64(script.trickleHoldMs) * 1_000_000)
                    var rest = channel.allocator.buffer(capacity: max(0, script.body.count - 1))
                    rest.writeBytes(script.body.dropFirst())
                    channel.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(rest))), promise: nil)
                } else {
                    var buffer = channel.allocator.buffer(capacity: script.body.count)
                    buffer.writeBytes(script.body)
                    channel.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
                }
                channel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: nil)
            }
        }
    }

    // MARK: - Helpers

    private func makeHTTPClient() -> HTTPClient {
        HTTPClient(eventLoopGroupProvider: .createNew)
    }

    private func makeService(
        clock: ManualClock,
        origin: String,
        client: HTTPClient,
        apiKeyId: String? = "synthetic-api-key-id",
        zcodeToken: String? = "synthetic-zcode-jwt"
    ) -> EndpointConfigService {
        var configuration = EndpointConfigService.Configuration()
        configuration.origin = origin
        configuration.client = client
        configuration.now = { clock.now }
        configuration.apiKeyIdProvider = apiKeyId.map { value in { value } }
        configuration.zcodeTokenProvider = zcodeToken.map { value in { value } }
        return EndpointConfigService(configuration: configuration)
    }

    /// A port that is (almost certainly) closed: bind, read the port, close.
    private func closedLoopbackPort() async throws -> Int {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let bootstrap = ServerBootstrap(group: group)
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        let port = channel.localAddress?.port ?? 0
        try await channel.close()
        return port
    }

    // MARK: - Lazy refresh + TTL

    @Test func firstResolveFetchesAndCacheServesWithinTTL() async throws {
        let stub = ConfigStubServer(defaultBody: mappingBody(to: Self.ultraTarget))
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }
        let clock = ManualClock(Date(timeIntervalSince1970: 1_763_000_000))
        let service = makeService(clock: clock, origin: "http://127.0.0.1:\(port)", client: httpClient)

        let first = await service.resolve(Self.requestURL)
        #expect(first.url == Self.ultraTarget + "/v1/messages")
        #expect(first.addZcodeAuthorization)
        #expect(stub.requestCount == 1)

        // Within 300 s: cache serves, no second fetch.
        clock.advance(299)
        let second = await service.resolve(Self.requestURL)
        #expect(second.url == Self.ultraTarget + "/v1/messages")
        #expect(stub.requestCount == 1)

        // Past 300 s: refetch — and the refreshed table's new target serves.
        stub.defaultBody = mappingBody(to: Self.otherTarget)
        clock.advance(2)
        let third = await service.resolve(Self.requestURL)
        #expect(third.url == Self.otherTarget + "/v1/messages")
        #expect(stub.requestCount == 2)
    }

    @Test func nonMatchingURLSkipsRewriteAfterFetch() async throws {
        // The fetch still happens (lazy first resolve), but a URL outside the
        // table comes back unchanged — per-request fail-open resolution.
        let stub = ConfigStubServer(defaultBody: mappingBody(to: Self.ultraTarget))
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }
        let clock = ManualClock(Date(timeIntervalSince1970: 1_763_000_000))
        let service = makeService(clock: clock, origin: "http://127.0.0.1:\(port)", client: httpClient)

        let resolved = await service.resolve("https://other.example/v1/messages?x=1")
        #expect(resolved.url == "https://other.example/v1/messages?x=1")
        #expect(!resolved.addZcodeAuthorization)
        #expect(stub.requestCount == 1)
    }

    // MARK: - Failure policy

    @Test func fetchFailureKeepsLastSnapshotAndCoolsDown30s() async throws {
        let stub = ConfigStubServer(defaultBody: mappingBody(to: Self.ultraTarget))
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }
        let clock = ManualClock(Date(timeIntervalSince1970: 1_763_000_000))
        let service = makeService(clock: clock, origin: "http://127.0.0.1:\(port)", client: httpClient)

        _ = await service.resolve(Self.requestURL)  // healthy snapshot
        #expect(stub.requestCount == 1)

        // TTL expired, stub fails: the last snapshot keeps serving.
        stub.queue(.init(status: 500, body: Data("{}".utf8)))
        clock.advance(301)
        let served = await service.resolve(Self.requestURL)
        #expect(served.url == Self.ultraTarget + "/v1/messages")
        #expect(stub.requestCount == 2)

        // 10 s later: still cooling down — no retry, snapshot still serves.
        clock.advance(10)
        let cooled = await service.resolve(Self.requestURL)
        #expect(cooled.url == Self.ultraTarget + "/v1/messages")
        #expect(stub.requestCount == 2)

        // Cooldown over (31 s since the failure): one retry.
        clock.advance(21)
        let retried = await service.resolve(Self.requestURL)
        #expect(retried.url == Self.ultraTarget + "/v1/messages")
        #expect(stub.requestCount == 3)
    }

    @Test func invalidPayloadIsAFailedRefresh() async throws {
        // A hostile/malformed body (parse nil) is a failure, not an empty
        // table: the last snapshot survives and the cooldown applies.
        let stub = ConfigStubServer(defaultBody: mappingBody(to: Self.ultraTarget))
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }
        let clock = ManualClock(Date(timeIntervalSince1970: 1_763_000_000))
        let service = makeService(clock: clock, origin: "http://127.0.0.1:\(port)", client: httpClient)

        _ = await service.resolve(Self.requestURL)
        stub.queue(.init(body: Data("{\"code\":0,\"data\":{}}".utf8)))  // no proxyEndpoint
        clock.advance(301)
        let served = await service.resolve(Self.requestURL)
        #expect(served.url == Self.ultraTarget + "/v1/messages")
        #expect(stub.requestCount == 2)

        // Within the 30 s cooldown: no third fetch.
        clock.advance(10)
        _ = await service.resolve(Self.requestURL)
        #expect(stub.requestCount == 2)
    }

    @Test func slowFetchTimesOutAndFailsOpen() async throws {
        let stub = ConfigStubServer(defaultBody: mappingBody(to: Self.ultraTarget))
        stub.queue(.init(body: mappingBody(to: Self.ultraTarget), delayMs: 5_000))  // 5 s — past the 3 s bound
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }
        let clock = ManualClock(Date(timeIntervalSince1970: 1_763_000_000))
        let service = makeService(clock: clock, origin: "http://127.0.0.1:\(port)", client: httpClient)

        let wallClock = ContinuousClock()
        let start = wallClock.now
        let resolved = await service.resolve(Self.requestURL)
        let elapsed = wallClock.now - start
        // Fail-open to the original URL, never blocking past the 3 s bound.
        #expect(resolved.url == Self.requestURL)
        #expect(!resolved.addZcodeAuthorization)
        #expect(elapsed < .seconds(4))
    }

    /// Regression (fix round 1): the execute deadline covers only the
    /// response HEAD — a head-then-stall body used to hang the body read
    /// (and the single-flight slot) indefinitely. The whole-exchange bound
    /// must cut it: fail-open within the bound AND the slot must be
    /// released so a later resolve can fetch again.
    @Test func trickledBodyTimesOutFailsOpenAndReleasesSingleFlight() async throws {
        let stub = ConfigStubServer(defaultBody: mappingBody(to: Self.ultraTarget))
        stub.queue(.init(body: mappingBody(to: Self.ultraTarget), trickleHoldMs: 8_000))
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }
        let clock = ManualClock(Date(timeIntervalSince1970: 1_763_000_000))
        let service = makeService(clock: clock, origin: "http://127.0.0.1:\(port)", client: httpClient)

        // Head + one byte arrive instantly; the body then stalls.
        let wallClock = ContinuousClock()
        let start = wallClock.now
        let resolved = await service.resolve(Self.requestURL)
        let elapsed = wallClock.now - start
        #expect(resolved.url == Self.requestURL)
        #expect(!resolved.addZcodeAuthorization)
        #expect(elapsed < .seconds(4))

        // The single-flight slot was freed: past the failure cooldown a
        // subsequent resolve CAN fetch again (and commits a fresh snapshot)
        // — impossible while a hung fetch still owned the slot.
        clock.advance(31)
        stub.defaultBody = mappingBody(to: Self.otherTarget)
        let recovered = await service.resolve(Self.requestURL)
        #expect(stub.requestCount == 2)
        #expect(recovered.url == Self.otherTarget + "/v1/messages")
    }

    @Test func noSnapshotFailsOpenAndNeverThrows() async throws {
        // Fresh install, offline: the endpoint is unreachable; resolve
        // returns the original URL.
        let port = try await closedLoopbackPort()
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }
        let clock = ManualClock(Date(timeIntervalSince1970: 1_763_000_000))
        let service = makeService(clock: clock, origin: "http://127.0.0.1:\(port)", client: httpClient)

        let resolved = await service.resolve(Self.requestURL)
        #expect(resolved.url == Self.requestURL)
        #expect(!resolved.addZcodeAuthorization)
    }

    // MARK: - Single-flight

    @Test func concurrentResolvesShareOneFetch() async throws {
        let stub = ConfigStubServer(defaultBody: mappingBody(to: Self.ultraTarget))
        stub.queue(.init(body: mappingBody(to: Self.ultraTarget), delayMs: 400))  // slow enough to overlap
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }
        let clock = ManualClock(Date(timeIntervalSince1970: 1_763_000_000))
        let service = makeService(clock: clock, origin: "http://127.0.0.1:\(port)", client: httpClient)

        await withTaskGroup(of: (String, Bool).self) { group in
            for _ in 0..<5 {
                group.addTask { await service.resolve(Self.requestURL) }
            }
            for await resolved in group {
                #expect(resolved.0 == Self.ultraTarget + "/v1/messages")
            }
        }
        #expect(stub.requestCount == 1)
    }

    // MARK: - Config-request shape

    @Test func configFetchCarriesCLIHeaders() async throws {
        let stub = ConfigStubServer(defaultBody: mappingBody(to: Self.ultraTarget))
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }
        let clock = ManualClock(Date(timeIntervalSince1970: 1_763_000_000))
        let service = makeService(clock: clock, origin: "http://127.0.0.1:\(port)", client: httpClient)

        _ = await service.resolve(Self.requestURL)
        let request = try #require(stub.requests.first)
        #expect(request.path == "/agent/configs")
        #expect(request.headers["user-agent"] == "ZCode/0.17.1")
        #expect(request.headers["x-zcode-app-version"] == "0.17.1")
        #expect(request.headers["x-api-key-id"] == "synthetic-api-key-id")
        #expect(request.headers["accept"] == "application/json")

        // No signing session yet → the apiKeyId header is omitted when the
        // provider has nothing (the production wiring consults SigningClient).
        let stub2 = ConfigStubServer(defaultBody: mappingBody(to: Self.ultraTarget))
        let port2 = try await stub2.start()
        defer { Task { await stub2.shutdown() } }
        let service2 = makeService(
            clock: clock, origin: "http://127.0.0.1:\(port2)", client: httpClient, apiKeyId: nil)
        _ = await service2.resolve(Self.requestURL)
        #expect(try #require(stub2.requests.first).headers["x-api-key-id"] == nil)
    }

    // MARK: - zcode JWT material

    @Test func tokenProviderServesZcodeJwtAndOmitsWhenAbsent() async throws {
        let stub = ConfigStubServer(defaultBody: mappingBody(to: Self.ultraTarget))
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }
        let clock = ManualClock(Date(timeIntervalSince1970: 1_763_000_000))
        let service = makeService(clock: clock, origin: "http://127.0.0.1:\(port)", client: httpClient)

        #expect(await service.zcodeAuthorizationToken() == "synthetic-zcode-jwt")

        let bare = makeService(
            clock: clock, origin: "http://127.0.0.1:\(port)", client: httpClient, zcodeToken: nil)
        #expect(await bare.zcodeAuthorizationToken() == nil)
    }
}

import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing
@testable import ZGate

/// Offline tests for `VersionPinService` — the server-driven relay
/// client-version pin. The endpoint is a local SwiftNIO stub on 127.0.0.1
/// and the poll runs through a real AsyncHTTPClient pointed at it (only the
/// origin is redirected), so the request shape (query + optional Bearer),
/// the greater-only bump, the 6 h cadence, and the silent-failure policy
/// are exercised on the production code path. The clock is injected for
/// deterministic cadence assertions.
struct VersionPinServiceTests {

    // MARK: - Fixtures

    /// A `client/configs` envelope carrying `data.configs.forceUpdate.minimalVersion`.
    private func configsBody(minimalVersion: String?) -> Data {
        var forceUpdate: [String: Any] = [:]
        if let minimalVersion {
            forceUpdate["minimalVersion"] = minimalVersion
        }
        let envelope: [String: Any] = [
            "code": 0, "msg": "success",
            "data": ["configs": ["forceUpdate": forceUpdate]],
        ]
        return (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
    }

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

    /// Lock-guarded recorder for `onBump` (called from the actor's poll).
    private final class BumpRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _bumps: [String] = []
        func record(_ version: String) {
            lock.lock(); _bumps.append(version); lock.unlock()
        }
        var bumps: [String] {
            lock.lock(); defer { lock.unlock() }
            return _bumps
        }
    }

    // MARK: - Stub config endpoint (SwiftNIO, 127.0.0.1)

    /// Serves the client/configs endpoint: records each request (path +
    /// headers), responds with scripted entries — popped in order — or a
    /// default 200 + `defaultBody` once the script queue runs dry.
    private final class ConfigsStubServer: @unchecked Sendable {
        struct Recorded {
            let path: String
            let headers: [String: String]
        }

        struct Script {
            var status = 200
            var body: Data
            /// Holds the HEAD + first byte back, then trickles the rest after
            /// the hold — the head-then-stall shape that only a
            /// whole-exchange bound can cut.
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
                        channel.pipeline.addHandler(ConfigsStubHandler(server: self))
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

    private final class ConfigsStubHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private let server: ConfigsStubServer
        private var requestHead: HTTPRequestHead?

        init(server: ConfigsStubServer) { self.server = server }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let head):
                requestHead = head
                var headers: [String: String] = [:]
                for (name, value) in head.headers {
                    headers[name.lowercased()] = value
                }
                server.record(ConfigsStubServer.Recorded(path: head.uri, headers: headers))
            case .body: break  // GET — no body expected
            case .end:
                let script = server.takeScript()
                requestHead = nil
                respond(context: context, script: script)
            }
        }

        private func respond(context: ChannelHandlerContext, script: ConfigsStubServer.Script) {
            let channel = context.channel
            Task {
                var head = HTTPResponseHead(
                    version: .http1_1, status: HTTPResponseStatus(statusCode: script.status))
                head.headers.add(name: "content-type", value: "application/json")
                head.headers.add(name: "content-length", value: String(script.body.count))
                channel.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
                if script.trickleHoldMs > 0, !script.body.isEmpty {
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
        initialVersion: String = RelayTarget.clientVersion,
        zcodeToken: String? = "synthetic-zcode-jwt",
        requestTimeout: TimeInterval = 20,
        recorder: BumpRecorder = BumpRecorder()
    ) -> VersionPinService {
        var configuration = VersionPinService.Configuration()
        configuration.origin = origin
        configuration.client = client
        configuration.now = { clock.now }
        configuration.initialVersion = initialVersion
        configuration.requestTimeout = requestTimeout
        configuration.zcodeTokenProvider = zcodeToken.map { value in { value } }
        configuration.onBump = { recorder.record($0) }
        return VersionPinService(configuration: configuration)
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

    // MARK: - SemVer (AC: 0.17.1 < 0.18.0, equal not greater, 1.0.0 > 0.99.99)

    @Test func semverComparisonTable() {
        // The three pinned AC cases.
        #expect(VersionPinService.SemVer("0.17.1")! < VersionPinService.SemVer("0.18.0")!)
        #expect(!(VersionPinService.SemVer("0.17.1")! < VersionPinService.SemVer("0.17.1")!))
        #expect(VersionPinService.SemVer("0.17.1")! == VersionPinService.SemVer("0.17.1")!)
        #expect(VersionPinService.SemVer("1.0.0")! > VersionPinService.SemVer("0.99.99")!)

        // Numeric (not lexicographic) components.
        #expect(VersionPinService.SemVer("0.9.0")! < VersionPinService.SemVer("0.10.0")!)
        // Missing components count as zero.
        #expect(VersionPinService.SemVer("0.17")! < VersionPinService.SemVer("0.17.1")!)
        #expect(VersionPinService.SemVer("0.17.0")! == VersionPinService.SemVer("0.17")!)
        // Major boundary.
        #expect(VersionPinService.SemVer("0.99.99")! < VersionPinService.SemVer("1.0.0")!)

        // Non-parseable values are nil (never comparable → never a bump).
        #expect(VersionPinService.SemVer("0.18.0-beta") == nil)
        #expect(VersionPinService.SemVer("dev") == nil)
        #expect(VersionPinService.SemVer("") == nil)
        #expect(VersionPinService.SemVer("0..1") == nil)
        #expect(VersionPinService.SemVer("0.18.0.1-x") == nil)
    }

    // MARK: - Bump policy (AC: greater-only bump, request shape)

    @Test func pollBumpsPinWhenServerMinimumRises() async throws {
        let stub = ConfigsStubServer(defaultBody: configsBody(minimalVersion: "0.18.0"))
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }
        let clock = ManualClock(Date(timeIntervalSince1970: 1_763_000_000))
        let recorder = BumpRecorder()
        let service = makeService(
            clock: clock, origin: "http://127.0.0.1:\(port)", client: httpClient, recorder: recorder)

        await service.pollNow()
        #expect(await service.currentVersion() == "0.18.0")
        #expect(recorder.bumps == ["0.18.0"])

        // Request shape: the pinned query pair, the optional Bearer material.
        let request = try #require(stub.requests.first)
        #expect(request.path == "/client/configs?app_version=0.17.1&platform=darwin-arm64")
        #expect(request.headers["authorization"] == "Bearer synthetic-zcode-jwt")
        #expect(request.headers["accept"] == "application/json")

        // The very same minimum again (6 h later): no second bump, and the
        // follow-up poll's query already carries the LIVE pin.
        clock.advance(6 * 3600)
        await service.pollIfDue()
        #expect(stub.requestCount == 2)
        #expect(await service.currentVersion() == "0.18.0")
        #expect(recorder.bumps == ["0.18.0"])
        #expect(try #require(stub.requests.last).path
            == "/client/configs?app_version=0.18.0&platform=darwin-arm64")
    }

    @Test func equalOrLowerMinimumNeverBumps() async throws {
        let stub = ConfigsStubServer(defaultBody: configsBody(minimalVersion: "0.17.1"))
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }
        let clock = ManualClock(Date(timeIntervalSince1970: 1_763_000_000))
        let recorder = BumpRecorder()
        let service = makeService(
            clock: clock, origin: "http://127.0.0.1:\(port)", client: httpClient, recorder: recorder)

        // Equal: no change.
        await service.pollNow()
        #expect(await service.currentVersion() == "0.17.1")
        #expect(recorder.bumps.isEmpty)

        // Lower: still no change (greater-only).
        stub.defaultBody = configsBody(minimalVersion: "0.16.2")
        clock.advance(6 * 3600)
        await service.pollIfDue()
        #expect(await service.currentVersion() == "0.17.1")
        #expect(recorder.bumps.isEmpty)
        #expect(stub.requestCount == 2)
    }

    @Test func missingTokenOmitsAuthorizationHeader() async throws {
        let stub = ConfigsStubServer(defaultBody: configsBody(minimalVersion: "0.18.0"))
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }
        let clock = ManualClock(Date(timeIntervalSince1970: 1_763_000_000))
        let service = makeService(
            clock: clock, origin: "http://127.0.0.1:\(port)", client: httpClient, zcodeToken: nil)

        await service.pollNow()
        #expect(await service.currentVersion() == "0.18.0")
        #expect(try #require(stub.requests.first).headers["authorization"] == nil)
    }

    // MARK: - Failure policy (AC: failure keeps the pin, silent)

    @Test func httpFailureKeepsPinSilently() async throws {
        let stub = ConfigsStubServer(defaultBody: configsBody(minimalVersion: "0.18.0"))
        stub.queue(.init(status: 503, body: Data("{}".utf8)))
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }
        let clock = ManualClock(Date(timeIntervalSince1970: 1_763_000_000))
        let recorder = BumpRecorder()
        let service = makeService(
            clock: clock, origin: "http://127.0.0.1:\(port)", client: httpClient, recorder: recorder)

        // pollNow does not throw and leaves everything untouched.
        await service.pollNow()
        #expect(await service.currentVersion() == "0.17.1")
        #expect(recorder.bumps.isEmpty)
    }

    @Test func unreachableEndpointKeepsPinSilently() async throws {
        let port = try await closedLoopbackPort()
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }
        let clock = ManualClock(Date(timeIntervalSince1970: 1_763_000_000))
        let recorder = BumpRecorder()
        // Short bound: an unreachable endpoint must fall to the
        // whole-exchange bound, not the transport's own connect timeout.
        let service = makeService(
            clock: clock, origin: "http://127.0.0.1:\(port)", client: httpClient,
            requestTimeout: 1, recorder: recorder)

        await service.pollNow()
        #expect(await service.currentVersion() == "0.17.1")
        #expect(recorder.bumps.isEmpty)
    }

    @Test func unusablePayloadKeepsPin() async throws {
        let stub = ConfigsStubServer(defaultBody: configsBody(minimalVersion: nil))
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }
        let clock = ManualClock(Date(timeIntervalSince1970: 1_763_000_000))
        let recorder = BumpRecorder()
        let service = makeService(
            clock: clock, origin: "http://127.0.0.1:\(port)", client: httpClient, recorder: recorder)

        // No minimalVersion at all: no bump.
        await service.pollNow()
        #expect(await service.currentVersion() == "0.17.1")
        #expect(recorder.bumps.isEmpty)

        // A minimalVersion that is not a semver is equally inert.
        stub.defaultBody = configsBody(minimalVersion: "0.18.x-beta")
        clock.advance(6 * 3600)
        await service.pollIfDue()
        #expect(await service.currentVersion() == "0.17.1")
        #expect(recorder.bumps.isEmpty)
        #expect(stub.requestCount == 2)
    }

    /// The whole-exchange bound: a head-then-stall body must not hang the
    /// poll past `requestTimeout` (the EndpointConfigService lesson — an
    /// execute-deadline alone leaves the body read unbounded).
    @Test func trickledBodyTimesOutAndKeepsPin() async throws {
        let stub = ConfigsStubServer(defaultBody: configsBody(minimalVersion: "0.18.0"))
        stub.queue(.init(body: configsBody(minimalVersion: "0.18.0"), trickleHoldMs: 8_000))
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }
        let clock = ManualClock(Date(timeIntervalSince1970: 1_763_000_000))
        let recorder = BumpRecorder()
        let service = makeService(
            clock: clock, origin: "http://127.0.0.1:\(port)", client: httpClient,
            requestTimeout: 1, recorder: recorder)

        let wallClock = ContinuousClock()
        let start = wallClock.now
        await service.pollNow()
        let elapsed = wallClock.now - start
        #expect(await service.currentVersion() == "0.17.1")
        #expect(recorder.bumps.isEmpty)
        #expect(elapsed < .seconds(2))
    }

    // MARK: - Cadence (AC: launch poll, then every 6 h)

    @Test func cadenceIsDueAtLaunchThenEverySixHours() async throws {
        let stub = ConfigsStubServer(defaultBody: configsBody(minimalVersion: "0.18.0"))
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }
        let clock = ManualClock(Date(timeIntervalSince1970: 1_763_000_000))
        let service = makeService(clock: clock, origin: "http://127.0.0.1:\(port)", client: httpClient)

        // Launch: due immediately (no attempt yet).
        await service.pollIfDue()
        #expect(stub.requestCount == 1)

        // 5 h 59 min later: not due.
        clock.advance(6 * 3600 - 60)
        await service.pollIfDue()
        #expect(stub.requestCount == 1)

        // Past the 6 h mark: due again.
        clock.advance(120)
        await service.pollIfDue()
        #expect(stub.requestCount == 2)
    }

    // MARK: - Config persistence surface (AC: relayClientVersion field)

    @Test func appConfigRoundTripsRelayClientVersionWithDefaultedDecode() throws {
        // A bumped pin round-trips through config.json.
        var config = AppConfig()
        config.relayClientVersion = "0.18.0"
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.relayClientVersion == "0.18.0")

        // Pre-wave configs (no key) decode to the bundled default — existing
        // installs are not disturbed.
        let legacy = try JSONDecoder().decode(
            AppConfig.self,
            from: Data("{\"vendors\":[],\"clients\":[]}".utf8))
        #expect(legacy.relayClientVersion == RelayTarget.clientVersion)

        // A hand-emptied value falls back to the default too.
        let emptied = try JSONDecoder().decode(
            AppConfig.self,
            from: Data("{\"vendors\":[],\"clients\":[],\"relayClientVersion\":\"\"}".utf8))
        #expect(emptied.relayClientVersion == RelayTarget.clientVersion)

        // The default encodes WITHOUT the key: byte-identical configs for
        // existing installs until a real bump writes it.
        let defaultedData = try JSONEncoder().encode(AppConfig())
        let defaultedJSON = try #require(
            try JSONSerialization.jsonObject(with: defaultedData) as? [String: Any])
        #expect(defaultedJSON["relayClientVersion"] == nil)
    }
}

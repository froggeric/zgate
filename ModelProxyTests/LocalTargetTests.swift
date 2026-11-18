import AsyncHTTPClient
import Foundation
import NIOCore
import NIOEmbedded
import NIOFoundationCompat
import NIOHTTP1
import NIOPosix
import Testing
@testable import ZGate

/// Offline tests for `LocalTarget` — the Splash local route.
///
/// Splash is a local SwiftNIO HTTP server (127.0.0.1, ephemeral port)
/// serving scripted responses, including a 5xx script for the fallback
/// ladder and an abrupt mid-stream cut. All credentials and thinking
/// signatures in fixtures are synthetic — no real key or signature material
/// appears anywhere.
@MainActor
@Suite struct LocalTargetTests {

    // MARK: - Mock splash server (SwiftNIO, 127.0.0.1)

    private final class MockSplashServer: @unchecked Sendable {
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
            var cutAfterChunks = false

            static func json(_ object: [String: Any], status: Int = 200) -> Script {
                let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
                return Script(status: status, chunks: [data])
            }
        }

        private let lock = NSRecursiveLock()
        private var scripts: [Script]
        private var _requests: [RecordedRequest] = []
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

        func start() async throws -> Int {
            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                        channel.pipeline.addHandler(MockSplashHandler(server: self))
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
    }

    private final class MockSplashHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private let server: MockSplashServer
        private var requestHead: HTTPRequestHead?
        private var body = Data()

        init(server: MockSplashServer) {
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
                server.record(MockSplashServer.RecordedRequest(
                    method: head.method.rawValue,
                    path: head.uri,
                    headers: headers,
                    body: body))
                respond(context: context, script: server.takeScript())
                requestHead = nil
                body = Data()
            }
        }

        private func respond(context: ChannelHandlerContext, script: MockSplashServer.Script) {
            let channel = context.channel
            Task {
                var head = HTTPResponseHead(
                    version: .http1_1,
                    status: HTTPResponseStatus(statusCode: script.status))
                for (name, value) in script.headers {
                    head.headers.add(name: name, value: value)
                }
                let total = script.chunks.reduce(0) { $0 + $1.count }
                if script.cutAfterChunks {
                    // Promise more bytes than will be delivered, then close:
                    // the client sees a body cut short of its content-length.
                    head.headers.replaceOrAdd(name: "content-length", value: String(total + 1024))
                } else if script.chunks.count <= 1 {
                    head.headers.replaceOrAdd(name: "content-length", value: String(total))
                }
                channel.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
                for chunk in script.chunks {
                    var buffer = channel.allocator.buffer(capacity: chunk.count)
                    buffer.writeBytes(chunk)
                    channel.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
                    channel.flush()
                }
                if script.cutAfterChunks {
                    channel.flush()
                    channel.close(promise: nil)
                } else {
                    channel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: nil)
                }
            }
        }
    }

    // MARK: - Helpers

    /// Thread-safe boolean for assertions made from child tasks.
    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() {
            lock.lock(); defer { lock.unlock() }
            value = true
        }
        var isSet: Bool {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    @Test func isLocalTargetExcludesPassthroughTargets() {
        // Baseline: the splash shape (loopback, non-relay) is local.
        #expect(LocalTarget.isLocalTarget(localRouteTarget(port: 8000)))
        // A passthrough target that happens to point at loopback (e.g. a
        // defaultUpstream override) must NOT take the local path —
        // passthrough means the proxy does not touch headers, key, or body.
        let passthrough = RoutingSnapshot.RouteTarget(
            baseURL: "http://127.0.0.1:9999",
            apiKey: "",
            vendorName: "loopback upstream",
            vendorID: nil,
            targetModel: nil,
            isPassthrough: true,
            connectTimeoutSeconds: 5,
            readTimeoutSeconds: 10,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly)
        #expect(!LocalTarget.isLocalTarget(passthrough))
    }

    private func localRouteTarget(port: Int, targetModel: String? = LocalTarget.defaultModel) -> RoutingSnapshot.RouteTarget {
        RoutingSnapshot.RouteTarget(
            baseURL: "http://127.0.0.1:\(port)",
            apiKey: "",
            vendorName: "splash (local)",
            vendorID: UUID(),
            targetModel: targetModel,
            isPassthrough: false,
            connectTimeoutSeconds: 5,
            readTimeoutSeconds: 10,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly)
    }

    private func relayRouteTarget() -> RoutingSnapshot.RouteTarget {
        RoutingSnapshot.RouteTarget(
            baseURL: "https://zcode.z.ai/api/v1/ultra-zai/anthropic",
            apiKey: "",
            vendorName: "zcode relay",
            vendorID: UUID(),
            targetModel: "GLM-5.3-Flash",
            isPassthrough: false,
            connectTimeoutSeconds: 5,
            readTimeoutSeconds: 10,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .transparent,
            vendorKind: .relay)
    }

    private func postHead() -> HTTPRequestHead {
        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/messages")
        // Synthetic credentials — assert they never leave the machine.
        head.headers.add(name: "x-api-key", value: "client-key-synthetic")
        head.headers.add(name: "authorization", value: "Bearer client-key-synthetic")
        head.headers.add(name: "anthropic-version", value: "2023-06-01")
        head.headers.add(name: "content-type", value: "application/json")
        head.headers.add(name: "user-agent", value: "claude-cli/2.1.282 (test)")
        head.headers.add(name: "x-claude-code-session-id", value: "session-1")
        return head
    }

    /// Handcrafted so byte-parity after the model splice is assertable.
    private func passthroughBody() -> String {
        #"{"model":"glm-5.3-flash","max_tokens":128,"stream":true,"system":"You are helpful.","messages":[{"role":"user","content":"héllo"}]}"#
    }

    /// A CC-style replay transcript: an assistant turn carrying a signed
    /// `thinking` block (synthetic signature — never real material).
    private func transcriptBodyText() -> String {
        #"{"model":"glm-5.3-flash","max_tokens":128,"messages":[{"role":"user","content":"hi"},{"role":"assistant","content":[{"type":"thinking","thinking":"prior reasoning","signature":"fake-signature-synthetic-0001"},{"type":"text","text":"answer"}]}]}"#
    }

    private func transcriptBody() -> Data {
        Data(transcriptBodyText().utf8)
    }

    private func makeHTTPClient() -> HTTPClient {
        // Short connect deadline: a refused loopback port otherwise retried
        // by AsyncHTTPClient until the full default timeout, slowing the
        // unreachable-target test by 10 s for no diagnostic value.
        HTTPClient(
            eventLoopGroupProvider: .createNew,
            configuration: HTTPClient.Configuration(timeout: .init(connect: .seconds(1))))
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

    // MARK: - Thinking-block contract (splash strips, relay keeps)

    @Test func foreignThinkingBlocksStrippedOnSplashRouteKeptOnRelayRoute() throws {
        let body = transcriptBody()
        let projector = TranscriptProjector()
        let fingerprint = ConversationFingerprint()

        // Splash shape (.portableOnly, thinking not accepted): the projector's
        // vendor-ready projection drops thinking-like blocks — a signature
        // minted by a non-splash model can never reach Splash.
        let splashPrepared = try projector.prepareRequest(
            bodyData: body, clientName: "test", sessionScopeKey: nil,
            coordinationScopeKey: nil, target: localRouteTarget(port: 8000),
            existingBranches: [], fingerprint: fingerprint)
        let splashJSON = try #require(
            try JSONSerialization.jsonObject(with: splashPrepared.bodyData) as? [String: Any])
        let splashMessages = try #require(splashJSON["messages"] as? [[String: Any]])
        let assistant = try #require(splashMessages.last)
        let blocks = try #require(assistant["content"] as? [[String: Any]])
        #expect(blocks.contains { ($0["type"] as? String) == "thinking" } == false)
        #expect(blocks.contains { ($0["type"] as? String) == "text" } == true)
        #expect(splashPrepared.bodyData.range(of: Data("signature".utf8)) == nil)

        // Relay shape (.transparent): the identical request is byte-unchanged.
        let relayPrepared = try projector.prepareRequest(
            bodyData: body, clientName: "test", sessionScopeKey: nil,
            coordinationScopeKey: nil, target: relayRouteTarget(),
            existingBranches: [], fingerprint: fingerprint)
        #expect(relayPrepared.bodyData == body)
    }

    // MARK: - Passthrough (headers + body)

    @Test func passthroughPreservesBodyExceptModelRewriteAndStripsCredentials() async throws {
        let splash = MockSplashServer(scripts: [.json(["ok": true])])
        let port = try await splash.start()
        defer { Task { await splash.shutdown() } }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let outcome = await LocalTarget.execute(
            head: postHead(), bodyData: Data(passthroughBody().utf8),
            target: localRouteTarget(port: port), httpClient: httpClient,
            requestID: "t-passthrough")
        guard case .responded(let response) = outcome else {
            Issue.record("expected responded, got \(outcome)")
            return
        }
        #expect(response.status == .ok)

        let request = try #require(splash.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/v1/messages")

        // Body: byte-identical except the model splice — same primitive the
        // relay path uses, no canonicalization of the splash model name.
        let expected = passthroughBody().replacingOccurrences(
            of: "glm-5.3-flash", with: LocalTarget.defaultModel)
        #expect(request.body == Data(expected.utf8))

        // Headers: CC's credentials and gateway identifiers stripped, nothing
        // added in their place; the client's protocol headers ride along.
        let headers = request.headers
        #expect(headers["authorization"] == nil)
        #expect(headers["x-api-key"] == nil)
        #expect(headers["x-claude-code-session-id"] == nil)
        #expect(headers["anthropic-version"] == "2023-06-01")
        #expect(headers["content-type"] == "application/json")
        #expect(headers["user-agent"] == "claude-cli/2.1.282 (test)")
    }

    @Test func wireBodyForwardsUnchangedWithoutTargetModel() throws {
        let body = Data(passthroughBody().utf8)
        let target = localRouteTarget(port: 8000, targetModel: nil)
        #expect(LocalTarget.wireBody(bodyData: body, target: target) == body)
    }

    @Test func loopbackClassification() {
        #expect(LocalTarget.isLocalTarget(localRouteTarget(port: 8000)) == true)
        #expect(LocalTarget.isLocalTarget(relayRouteTarget()) == false)
        let remote = RoutingSnapshot.RouteTarget(
            baseURL: "https://api.example.com", apiKey: "k", vendorName: "remote",
            vendorID: UUID(), targetModel: "m", isPassthrough: false,
            connectTimeoutSeconds: 5, readTimeoutSeconds: 10,
            signingDomain: .compatibleThirdParty, replayPolicy: .portableOnly)
        #expect(LocalTarget.isLocalTarget(remote) == false)
        #expect(LocalTarget.isLoopbackBaseURL("http://localhost:9000") == true)
        #expect(LocalTarget.isLoopbackBaseURL("http://127.0.0.1:8000/v1") == true)
        #expect(LocalTarget.isLoopbackBaseURL("https://api.example.com") == false)
    }

    // MARK: - Wire-level health note

    @Test func localExchangeSuccessNotedOnHealthMonitor() async throws {
        let splash = MockSplashServer(scripts: [.json(["ok": true])])
        let port = try await splash.start()
        defer { Task { await splash.shutdown() } }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let monitor = LocalHealthMonitor()
        defer { Task { await monitor.stopProbing() } }
        let target = localRouteTarget(port: port)
        #expect(monitor.lastSuccess(forVendor: target.vendorID!) == nil)

        let outcome = await LocalTarget.execute(
            head: postHead(), bodyData: Data(passthroughBody().utf8),
            target: target, httpClient: httpClient, requestID: "t-wire-health",
            health: monitor)
        guard case .responded = outcome else {
            Issue.record("expected responded, got \(outcome)")
            return
        }
        #expect(monitor.lastSuccess(forVendor: target.vendorID!) != nil)
    }

    // MARK: - Health probe (ephemeral listener)

    @Test func probeRecordsSuccessWhenListenerUp() async throws {
        let listener = MockSplashServer(scripts: [])
        let port = try await listener.start()
        defer { Task { await listener.shutdown() } }

        let monitor = LocalHealthMonitor()
        defer { Task { await monitor.stopProbing() } }
        let vendor = Vendor(name: "splash (local)", baseURL: "http://127.0.0.1:\(port)", apiKey: "")
        monitor.configure(vendors: [vendor])
        await monitor.probeOnce(force: true)

        let success = try #require(monitor.lastSuccess(forVendor: vendor.id))
        #expect(abs(success.timeIntervalSinceNow) < 5)
    }

    @Test func probeRecordsNothingWhenListenerDown() async throws {
        // Bind, note the port, shut down: a certainly-refused local port.
        let listener = MockSplashServer(scripts: [])
        let port = try await listener.start()
        await listener.shutdown()

        let monitor = LocalHealthMonitor()
        defer { Task { await monitor.stopProbing() } }
        let vendor = Vendor(name: "splash (local)", baseURL: "http://127.0.0.1:\(port)", apiKey: "")
        monitor.configure(vendors: [vendor])
        await monitor.probeOnce(force: true)

        #expect(monitor.lastSuccess(forVendor: vendor.id) == nil)
    }

    @Test func failedProbeLeavesStaleSuccessUntouched() async throws {
        let listener = MockSplashServer(scripts: [])
        let port = try await listener.start()

        let monitor = LocalHealthMonitor()
        let vendor = Vendor(name: "splash (local)", baseURL: "http://127.0.0.1:\(port)", apiKey: "")
        monitor.configure(vendors: [vendor])
        await monitor.probeOnce(force: true)
        let firstSuccess = try #require(monitor.lastSuccess(forVendor: vendor.id))

        await listener.shutdown()
        await monitor.probeOnce(force: true)

        // Down is recorded as absence of a fresh success, never by mutating
        // history: the old entry stays and ages out for the router to judge.
        let stillFirst = try #require(monitor.lastSuccess(forVendor: vendor.id))
        #expect(stillFirst == firstSuccess)
        try? await monitor.stopProbing()
    }

    // MARK: - Fallback ladder

    /// Builds the spec §2-style rule (haiku → splash, loopback backup) and
    /// resolves its target array through RoutingSnapshot — the same array
    /// the router's failover machinery hands the forwarder.
    private func makeFallbackFixture(splashPort: Int, backupPort: Int) throws
        -> (targets: [RoutingSnapshot.RouteTarget], splashVendor: Vendor, backupVendor: Vendor)
    {
        let splashVendor = Vendor(
            name: "splash (local)", baseURL: "http://127.0.0.1:\(splashPort)",
            apiKey: "", replayPolicy: .portableOnly)
        let backupVendor = Vendor(
            name: "backup vendor", baseURL: "http://127.0.0.1:\(backupPort)",
            apiKey: "backup-key-synthetic")
        let mapping = ModelMapping(
            sourceModel: "haiku", targetModel: "Qwen3.8-27B-4bit",
            targetVendorID: splashVendor.id,
            backupTargetModel: "GLM-5.3-Flash", backupTargetVendorID: backupVendor.id,
            matchClass: .haiku)
        let client = ClientConfig(
            clientName: "Claude Code", port: 0,
            defaultUpstream: "https://api.anthropic.com", unmappedPolicy: .passthrough)
        let config = AppConfig(
            vendors: [splashVendor, backupVendor], clients: [client], modelMappings: [mapping])
        let snapshot = RoutingSnapshot(from: config, for: client)
        let targets = try #require(snapshot.targets(for: "glm-5.3-flash"))
        #expect(targets.count == 2)
        return (targets, splashVendor, backupVendor)
    }

    @Test func splash5xxFallsBackToRuleBackup() async throws {
        let splash = MockSplashServer(scripts: [
            .json(["type": "error", "error": ["type": "api_error", "message": "boom"]], status: 500),
        ])
        let backup = MockSplashServer(scripts: [.json(["servedBy": "backup-marker"])])
        let splashPort = try await splash.start()
        let backupPort = try await backup.start()
        defer {
            Task { await splash.shutdown() }
            Task { await backup.shutdown() }
        }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let fixture = try makeFallbackFixture(splashPort: splashPort, backupPort: backupPort)
        let outcome = await LocalTarget.executeWithFallback(
            head: postHead(), bodyData: Data(passthroughBody().utf8),
            targets: fixture.targets, httpClient: httpClient, requestID: "t-fallback")

        guard case .served(let response, let servedTarget) = outcome else {
            Issue.record("expected served, got \(outcome)")
            return
        }
        #expect(response.status == .ok)
        #expect(servedTarget.vendorID == fixture.backupVendor.id)
        #expect(splash.requests.count == 1)
        #expect(backup.requests.count == 1)

        // The client receives the fallback's response.
        let channel = EmbeddedChannel()
        await LocalTarget.relayStream(upstreamResponse: response, to: channel, requestID: "t-fallback")
        let (head, body, sawEnd) = try drainClientResponse(channel)
        #expect(head.status == .ok)
        #expect(String(data: body, encoding: .utf8)?.contains("backup-marker") == true)
        #expect(sawEnd)
    }

    @Test func splash5xxWithoutBackupPassesErrorThrough() async throws {
        let splash = MockSplashServer(scripts: [
            .json(["type": "error", "error": ["type": "api_error", "message": "boom"]], status: 500),
        ])
        let splashPort = try await splash.start()
        defer { Task { await splash.shutdown() } }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let outcome = await LocalTarget.executeWithFallback(
            head: postHead(), bodyData: Data(passthroughBody().utf8),
            targets: [localRouteTarget(port: splashPort)], httpClient: httpClient,
            requestID: "t-no-backup")

        guard case .primaryError(let response, let target) = outcome else {
            Issue.record("expected primaryError, got \(outcome)")
            return
        }
        #expect(response.status == .internalServerError)
        let channel = EmbeddedChannel()
        await LocalTarget.relayStream(upstreamResponse: response, to: channel, requestID: "t-no-backup")
        let (head, _, sawEnd) = try drainClientResponse(channel)
        #expect(head.status == .internalServerError)
        #expect(sawEnd)
        _ = target
    }

    @Test func splashUnreachableFallsBackToBackup() async throws {
        // A port with nothing listening: the splash exchange cannot connect.
        let gone = MockSplashServer(scripts: [])
        let splashPort = try await gone.start()
        await gone.shutdown()

        let backup = MockSplashServer(scripts: [.json(["servedBy": "backup-marker"])])
        let backupPort = try await backup.start()
        defer { Task { await backup.shutdown() } }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let fixture = try makeFallbackFixture(splashPort: splashPort, backupPort: backupPort)
        let outcome = await LocalTarget.executeWithFallback(
            head: postHead(), bodyData: Data(passthroughBody().utf8),
            targets: fixture.targets, httpClient: httpClient, requestID: "t-unreachable")

        guard case .served(let response, let servedTarget) = outcome else {
            Issue.record("expected served, got \(outcome)")
            return
        }
        #expect(response.status == .ok)
        #expect(servedTarget.vendorID == fixture.backupVendor.id)
        #expect(backup.requests.count == 1)
    }

    // MARK: - Stream cut mid-response

    @Test func streamCutMidResponseYieldsCleanErrorEventNotHang() async throws {
        let firstEvent = "event: message_start\ndata: {\"type\":\"message_start\"}\n\n"
        let cutEvent = "event: content_block_delta\ndata: {\"type\":\"content_block_"
        let splash = MockSplashServer(scripts: [
            MockSplashServer.Script(
                status: 200,
                headers: ["content-type": "text/event-stream"],
                chunks: [Data(firstEvent.utf8), Data(cutEvent.utf8)],
                cutAfterChunks: true),
        ])
        let port = try await splash.start()
        defer { Task { await splash.shutdown() } }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let outcome = await LocalTarget.execute(
            head: postHead(), bodyData: Data(passthroughBody().utf8),
            target: localRouteTarget(port: port), httpClient: httpClient,
            requestID: "t-cut")
        guard case .responded(let response) = outcome else {
            Issue.record("expected responded, got \(outcome)")
            return
        }
        #expect(response.status == .ok)

        // Bounded completion: the relay must terminate (here within 5 s)
        // even though the upstream body never finishes.
        let channel = EmbeddedChannel()
        let done = LockedFlag()
        let relayTask = Task {
            await LocalTarget.relayStream(upstreamResponse: response, to: channel, requestID: "t-cut")
            done.set()
        }
        let finished = await waitUntil(timeout: 5) { done.isSet }
        #expect(finished)
        relayTask.cancel()

        let (head, body, sawEnd) = try drainClientResponse(channel)
        let bodyText = String(data: body, encoding: .utf8) ?? ""
        #expect(head.status == .ok)
        #expect(bodyText.contains("message_start"))  // early events were delivered
        #expect(bodyText.contains("event: error"))  // clean terminal error event
        #expect(bodyText.contains("Local model stream ended unexpectedly"))
        #expect(sawEnd)
    }

    @Test func streamCutErrorEventIsWellFormedSSE() throws {
        // Exactly one blank-line-terminated event; JSON payload parses.
        #expect(LocalTarget.streamCutErrorEvent.hasSuffix("\n\n"))
        #expect(LocalTarget.streamCutErrorEvent.hasPrefix("event: error\ndata: "))
        let payload = LocalTarget.streamCutErrorEvent
            .dropFirst("event: error\ndata: ".count)
            .dropLast(2)
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        #expect(json["type"] as? String == "error")
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["type"] as? String == "api_error")
        #expect((error["message"] as? String)?.isEmpty == false)
    }

    // MARK: - Forward-path wiring (end-to-end through ProxyForwarder)

    private struct ForwardFixture {
        let router: RequestRouter
        let trafficLog: TrafficLog
        let tokenStatsStore: TokenStatsStore
        let lineageBroker: SessionLineageBroker
        let portableNormalizer: PortableContentNormalizer
        let requestCoordinator: BranchRequestCoordinator
        let splashVendorID: UUID
        let backupVendorID: UUID?
        let directory: URL
    }

    /// Exact-match mapping `glm-5.3-flash` → splash (+ optional loopback
    /// backup), the same routing table shape ProxyServer builds per client.
    private func makeForwardFixture(splashPort: Int, backupPort: Int?) throws -> ForwardFixture {
        let splashVendorID = UUID()
        var vendors = [Vendor(
            id: splashVendorID, name: "splash (local)",
            baseURL: "http://127.0.0.1:\(splashPort)", apiKey: "",
            readTimeoutSeconds: 10, replayPolicy: .portableOnly)]
        var mapping = ModelMapping(
            sourceModel: "glm-5.3-flash", targetModel: "Qwen3.8-27B-4bit",
            targetVendorID: splashVendorID, isEnabled: true)
        var backupVendorID: UUID?
        if let backupPort {
            let backupVendor = Vendor(
                id: UUID(), name: "Backup Vendor",
                baseURL: "http://127.0.0.1:\(backupPort)",
                apiKey: "backup-key-synthetic", readTimeoutSeconds: 10)
            vendors.append(backupVendor)
            backupVendorID = backupVendor.id
            mapping.backupTargetVendorID = backupVendor.id
            mapping.backupTargetModel = "glm-4.7"
        }
        let clientConfig = ClientConfig(
            clientName: "Claude Code", port: 0,
            defaultUpstream: "https://api.anthropic.com", unmappedPolicy: .block)
        let config = AppConfig(vendors: vendors, clients: [clientConfig], modelMappings: [mapping])
        let snapshot = RoutingSnapshot(from: config, for: clientConfig)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zgate-localtarget-fwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lineageBroker = SessionLineageBroker(
            store: FileLineageStore(fileURL: directory.appendingPathComponent("lineages.json")))
        return ForwardFixture(
            router: RequestRouter(snapshot: snapshot),
            trafficLog: TrafficLog(),
            tokenStatsStore: TokenStatsStore(),
            lineageBroker: lineageBroker,
            portableNormalizer: PortableContentNormalizer(),
            requestCoordinator: BranchRequestCoordinator(),
            splashVendorID: splashVendorID,
            backupVendorID: backupVendorID,
            directory: directory)
    }

    @discardableResult
    private func forward(
        _ fixture: ForwardFixture, httpClient: HTTPClient, channel: any Channel,
        bodyText: String, localHealth: LocalHealthMonitor? = nil,
        webSearchProvider: (any WebSearchBridgeProviding)? = nil
    ) async -> Void {
        var body = ByteBufferAllocator().buffer(capacity: 0)
        body.writeData(Data(bodyText.utf8))
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
            webSearchProvider: webSearchProvider,
            webSearchForwardAsIs: false,
            relayContext: nil,
            localHealth: localHealth)
    }

    @Test func forwardLocal5xxFallsBackToRuleBackup() async throws {
        let splash = MockSplashServer(scripts: [
            .json(["type": "error", "error": ["type": "api_error", "message": "boom"]], status: 500),
        ])
        let backup = MockSplashServer(scripts: [.json(["servedBy": "backup-marker"])])
        let splashPort = try await splash.start()
        let backupPort = try await backup.start()
        defer {
            Task { await splash.shutdown() }
            Task { await backup.shutdown() }
        }
        let fixture = try makeForwardFixture(splashPort: splashPort, backupPort: backupPort)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let client = EmbeddedChannel()
        await forward(fixture, httpClient: httpClient, channel: client, bodyText: passthroughBody())
        let (head, body, sawEnd) = try drainClientResponse(client)
        #expect(head.status == .ok)
        #expect(sawEnd)
        #expect(String(data: body, encoding: .utf8)?.contains("backup-marker") == true)

        // The fallback request rode the rule's backup target and its model.
        #expect(splash.requests.count == 1)
        #expect(backup.requests.count == 1)
        let sent = try #require(
            try JSONSerialization.jsonObject(with: backup.requests[0].body) as? [String: Any])
        #expect(sent["model"] as? String == "glm-4.7")
        finishChannel(client)
    }

    @Test func forwardLocalRouteStripsThinkingCredentialsAndRewritesModel() async throws {
        let splash = MockSplashServer(scripts: [.json(["id": "msg_local", "role": "assistant"])])
        let splashPort = try await splash.start()
        defer { Task { await splash.shutdown() } }
        let fixture = try makeForwardFixture(splashPort: splashPort, backupPort: nil)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }
        let monitor = LocalHealthMonitor()
        defer { Task { await monitor.stopProbing() } }

        let client = EmbeddedChannel()
        await forward(
            fixture, httpClient: httpClient, channel: client,
            bodyText: transcriptBodyText(), localHealth: monitor)

        // Client got the local response.
        let (head, body, sawEnd) = try drainClientResponse(client)
        #expect(head.status == .ok)
        #expect(sawEnd)
        #expect(String(data: body, encoding: .utf8)?.contains("msg_local") == true)

        // The splash request: foreign-signature thinking stripped by the
        // live projection path, credentials stripped, model rewritten.
        let request = try #require(splash.requests.first)
        #expect(request.headers["authorization"] == nil)
        #expect(request.headers["x-api-key"] == nil)
        #expect(request.body.range(of: Data("signature".utf8)) == nil)
        let sent = try #require(
            try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(sent["model"] as? String == "Qwen3.8-27B-4bit")
        let messages = try #require(sent["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        // The user message's string content rides along untouched; every
        // block-bearing message has its thinking blocks stripped.
        #expect(messages[0]["content"] as? String == "hi")
        for message in messages {
            guard let blocks = message["content"] as? [[String: Any]] else { continue }
            #expect(blocks.contains { ($0["type"] as? String) == "thinking" } == false)
        }
        let assistantBlocks = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(assistantBlocks.contains { ($0["type"] as? String) == "text" } == true)

        // A 2xx local exchange keeps the vendor healthy on the wire.
        #expect(monitor.lastSuccess(forVendor: fixture.splashVendorID) != nil)
        finishChannel(client)
    }

    @Test func forwardLocalStreamCutAnswersCleanErrorEventNotHang() async throws {
        let firstEvent = "event: message_start\ndata: {\"type\":\"message_start\"}\n\n"
        let cutEvent = "event: content_block_delta\ndata: {\"type\":\"content_block_"
        let splash = MockSplashServer(scripts: [
            MockSplashServer.Script(
                status: 200,
                headers: ["content-type": "text/event-stream"],
                chunks: [Data(firstEvent.utf8), Data(cutEvent.utf8)],
                cutAfterChunks: true),
        ])
        let splashPort = try await splash.start()
        defer { Task { await splash.shutdown() } }
        let fixture = try makeForwardFixture(splashPort: splashPort, backupPort: nil)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        // Bounded completion through the whole forward path: the cut must not
        // hang the request.
        let client = EmbeddedChannel()
        let done = LockedFlag()
        let forwardTask = Task {
            await forward(fixture, httpClient: httpClient, channel: client, bodyText: passthroughBody())
            done.set()
        }
        let finished = await waitUntil(timeout: 5) { done.isSet }
        #expect(finished)
        forwardTask.cancel()

        let (head, body, sawEnd) = try drainClientResponse(client)
        let bodyText = String(data: body, encoding: .utf8) ?? ""
        #expect(head.status == .ok)
        #expect(bodyText.contains("message_start"))  // early events delivered
        #expect(bodyText.contains("event: error"))  // clean terminal error event
        #expect(bodyText.contains("Local model stream ended unexpectedly"))
        #expect(sawEnd)
        finishChannel(client)
    }

    @Test func forwardLocalUnreachableWithoutBackupAnswers502() async throws {
        let gone = MockSplashServer(scripts: [])
        let splashPort = try await gone.start()
        await gone.shutdown()
        let fixture = try makeForwardFixture(splashPort: splashPort, backupPort: nil)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let client = EmbeddedChannel()
        await forward(fixture, httpClient: httpClient, channel: client, bodyText: passthroughBody())
        let (head, body, sawEnd) = try drainClientResponse(client)
        #expect(head.status == .badGateway)
        #expect(sawEnd)
        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["type"] as? String == "api_error")
        #expect((error["message"] as? String)?.localizedCaseInsensitiveContains("local target unreachable") == true)
        finishChannel(client)
    }

    @Test func forwardLocal5xxWithFailingBackupReturnsSplashError() async throws {
        // Splash 500s AND the backup is unreachable: the client gets splash's
        // own error body — drained + rewrapped on the live path (the
        // single-iterator workaround; a regression here crashes the process).
        let splash = MockSplashServer(scripts: [
            .json(["type": "error", "error": ["type": "api_error", "message": "splash-failed-marker"]], status: 500),
        ])
        let splashPort = try await splash.start()
        defer { Task { await splash.shutdown() } }
        let goneBackup = MockSplashServer(scripts: [])
        let backupPort = try await goneBackup.start()
        await goneBackup.shutdown()

        let fixture = try makeForwardFixture(splashPort: splashPort, backupPort: backupPort)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let client = EmbeddedChannel()
        await forward(fixture, httpClient: httpClient, channel: client, bodyText: passthroughBody())
        let (head, body, sawEnd) = try drainClientResponse(client)
        #expect(head.status == .internalServerError)
        #expect(sawEnd)
        #expect(String(data: body, encoding: .utf8)?.contains("splash-failed-marker") == true)
        finishChannel(client)
    }

    // MARK: - Fix round 1 (web-search traffic rides the local ladder)

    /// A provider that records every search call — the bridge must never
    /// reach it for splash-routed requests.
    private final class RecordingSearchProvider: WebSearchBridgeProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }
        func search(
            query: String, maxResults: Int, httpClient: HTTPClient
        ) async throws -> [WebSearchResult] {
            lock.lock(); _calls += 1; lock.unlock()
            return []
        }
    }

    private func webSearchBodyText() -> String {
        #"{"model":"glm-5.3-flash","max_tokens":128,"stream":true,"tools":[{"type":"web_search_20250305","max_uses":3}],"messages":[{"role":"user","content":"search the web"}]}"#
    }

    @Test func webSearchBridgeDoesNotClaimLocalTargets() throws {
        let body = Data(webSearchBodyText().utf8)
        // Splash shape: the bridge must not claim it (would bypass the local
        // ladder and its credential-free headers).
        #expect(WebSearchBridge.shouldHandle(
            bodyData: body, target: localRouteTarget(port: 8000),
            requestKind: .generation) == false)
        // The identical body still claims an ordinary mapped vendor — the
        // exclusion is scoped to local targets, not the tool set.
        let mappedRemote = RoutingSnapshot.RouteTarget(
            baseURL: "https://api.example.com", apiKey: "k", vendorName: "remote",
            vendorID: UUID(), targetModel: "m", isPassthrough: false,
            connectTimeoutSeconds: 5, readTimeoutSeconds: 10,
            signingDomain: .compatibleThirdParty, replayPolicy: .portableOnly)
        #expect(WebSearchBridge.shouldHandle(
            bodyData: body, target: mappedRemote,
            requestKind: .generation) == true)
    }

    @Test func forwardLocalWebSearchRequestRidesLocalLadderNotBridge() async throws {
        let splash = MockSplashServer(scripts: [.json(["id": "msg_local_search"])])
        let splashPort = try await splash.start()
        defer { Task { await splash.shutdown() } }
        let fixture = try makeForwardFixture(splashPort: splashPort, backupPort: nil)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }
        let provider = RecordingSearchProvider()

        let client = EmbeddedChannel()
        await forward(
            fixture, httpClient: httpClient, channel: client,
            bodyText: webSearchBodyText(), webSearchProvider: provider)

        // Client got the local response; the bridge never ran.
        let (head, body, sawEnd) = try drainClientResponse(client)
        #expect(head.status == .ok)
        #expect(sawEnd)
        #expect(String(data: body, encoding: .utf8)?.contains("msg_local_search") == true)
        #expect(provider.calls == 0)

        // The splash request rode the local ladder: no credentials added,
        // model rewritten, and the server-side search tool dropped by the
        // mapped-path tool sanitizer (splash can't execute it).
        let request = try #require(splash.requests.first)
        #expect(request.headers["authorization"] == nil)
        #expect(request.headers["x-api-key"] == nil)
        let sent = try #require(
            try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(sent["model"] as? String == "Qwen3.8-27B-4bit")
        #expect(sent["tools"] == nil)
        finishChannel(client)
    }

    // MARK: - App-defect fixes (post-E2E)

    @Test func forwardLocalFallbackServeRecordsUsageInTokenStats() async throws {
        // Splash 5xx, backup serves with a usage-bearing body: the local
        // ladder's stream must still meter the answer — attributed to the
        // serving vendor with its rule model (defect: relay-via-local-fallback
        // previously bypassed token stats entirely).
        let splash = MockSplashServer(scripts: [
            .json(["type": "error", "error": ["type": "api_error", "message": "boom"]], status: 500),
        ])
        let backup = MockSplashServer(scripts: [
            .json(["id": "msg_backup", "usage": ["input_tokens": 111, "output_tokens": 222]]),
        ])
        let splashPort = try await splash.start()
        let backupPort = try await backup.start()
        defer {
            Task { await splash.shutdown() }
            Task { await backup.shutdown() }
        }
        let fixture = try makeForwardFixture(splashPort: splashPort, backupPort: backupPort)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }
        let backupVendorID = try #require(fixture.backupVendorID)

        let client = EmbeddedChannel()
        await forward(fixture, httpClient: httpClient, channel: client, bodyText: passthroughBody())
        let (head, body, sawEnd) = try drainClientResponse(client)
        #expect(head.status == .ok)
        #expect(sawEnd)
        #expect(String(data: body, encoding: .utf8)?.contains("msg_backup") == true)

        // The usage callback lands in the store via a MainActor task — wait
        // for the backup vendor's row.
        let recorded = await waitUntil(timeout: 5) {
            fixture.tokenStatsStore.tableRows.contains { row in
                row.vendorID == backupVendorID && row.record.inputTokens == 111
            }
        }
        #expect(recorded)
        let row = try #require(
            fixture.tokenStatsStore.tableRows.first { $0.vendorID == backupVendorID })
        #expect(row.record.inputTokens == 111)
        #expect(row.record.outputTokens == 222)
        // Attributed to the serving target's rule model, not splash's.
        #expect(row.model == "glm-4.7")
        // Nothing metered against the (failed) splash vendor.
        #expect(fixture.tokenStatsStore.tableRows.contains { $0.vendorID == fixture.splashVendorID } == false)
        finishChannel(client)
    }

    /// Records usage-callback invocations from @Sendable callbacks.
    private final class UsageRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(input: Int, output: Int)] = []
        func record(_ input: Int, _ output: Int) {
            lock.lock(); _calls.append((input, output)); lock.unlock()
        }
        var calls: [(input: Int, output: Int)] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }
    }

    @Test func relayStreamExtractsSSEUsageAcrossEvents() async throws {
        // Module-level pin of the SSE accumulation rules: input from
        // message_start, output from message_delta, one callback at end.
        let events = [
            "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":31}}}\n\n",
            "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}\n\n",
            "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{},\"usage\":{\"output_tokens\":47}}\n\n",
            "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
        ].joined()
        var head = HTTPResponseHead(version: .http1_1, status: .ok)
        head.headers.add(name: "content-type", value: "text/event-stream")
        var buffer = ByteBufferAllocator().buffer(capacity: events.utf8.count)
        buffer.writeString(events)
        var response = HTTPClientResponse(version: .http1_1, status: .ok, headers: head.headers)
        response.body = .bytes(buffer)

        let recorder = UsageRecorder()
        let channel = EmbeddedChannel()
        await LocalTarget.relayStream(
            upstreamResponse: response, to: channel, requestID: "t-sse-usage"
        ) { input, output, _ in
            recorder.record(input, output)
        }
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.input == 31)
        #expect(recorder.calls.first?.output == 47)
        finishChannel(channel)
    }

    @Test func debugConfigPartialDecodeKeepsSpecifiedKeysAndDefaultsOthers() throws {
        // Defect: a partial debug object made the synthesized decoder throw,
        // and AppConfig's try? swallowed it into a fully-defaulted config —
        // disabling file logging despite isEnabled: true.
        let partial = try JSONDecoder().decode(
            DebugConfig.self, from: Data(#"{"isEnabled": true}"#.utf8))
        #expect(partial.isEnabled == true)
        #expect(partial.minimumLogLevel == .info)
        #expect(partial.autoCleanupEnabled == true)
        #expect(partial.cleanupAfterDays == 7)
        #expect(partial.compressAfterDays == 3)

        // Through the AppConfig container path with the same partial object.
        let appJSON = Data(
            #"{"vendors":[],"clients":[],"debug":{"isEnabled":true}}"#.utf8)
        let appConfig = try JSONDecoder().decode(AppConfig.self, from: appJSON)
        #expect(appConfig.debug.isEnabled == true)
        #expect(appConfig.debug.cleanupAfterDays == 7)

        // Round-trip still encodes every key (full writes stay complete).
        let reencoded = try JSONEncoder().encode(partial)
        let roundTripped = try JSONDecoder().decode(DebugConfig.self, from: reencoded)
        #expect(roundTripped == partial)
    }
}

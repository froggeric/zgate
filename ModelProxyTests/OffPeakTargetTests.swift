import AsyncHTTPClient
import Foundation
import NIOCore
import NIOEmbedded
import NIOFoundationCompat
import NIOHTTP1
import NIOPosix
import Testing
@testable import ZGate

/// Relay fidelity Task 10: the opt-in, default-OFF async relay surface
/// (`/async/v1/messages` + orchestrator).
///
/// Three harness layers, mirroring the wave's established patterns:
/// - `OffPeakStubServer` — one local SwiftNIO server (127.0.0.1, ephemeral
///   port) scripting BOTH the ticket control plane and the data plane (they
///   share an origin in production). The ticket client runs its DEFAULT
///   execute (real AsyncHTTPClient) against it.
/// - `ManualClock` — virtual clock + cancellation-aware sleeper: the
///   orchestrator's injected `now`/`sleep` move on test-driven time only,
///   so keepalive cadences, poll intervals, and backoffs are asserted
///   exactly, with zero real waiting.
/// - `EmbeddedChannel` — the downstream client channel; drained byte-wise
///   to pin keepalive bytes, SSE frames, and their ordering.
///
/// No real network beyond loopback; all credentials are synthetic.
struct OffPeakTargetTests {

    private typealias Script = OffPeakStubServer.Script

    // MARK: - Stub server (ticket control plane + data plane, one origin)

    private final class OffPeakStubServer: @unchecked Sendable {
        struct Recorded {
            let method: String
            let path: String
            let headers: [String: String]
            let body: Data?

            var jsonBody: [String: Any]? {
                body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            }

            func header(_ name: String) -> String? { headers[name.lowercased()] }
        }

        struct Script {
            var status: Int = 200
            var headers: [String: String] = ["content-type": "application/json"]
            var chunks: [Data] = []
            var hold: Gate?

            static func envelope(_ json: String) -> Script {
                Script(chunks: [Data(json.utf8)])
            }
        }

        private let lock = NSRecursiveLock()
        private var _recorded: [Recorded] = []
        private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        private var serverChannel: (any Channel)?
        private var channels: [any Channel] = []
        var respond: ((Recorded) -> Script)?
        /// FIXED ports below the ephemeral range, NOT `:0` (the
        /// ConnectRetryTests lesson): macOS hands out ephemeral ports
        /// near-sequentially, so a `:0` bind can steal exactly the
        /// takenPort+N a concurrently-running RouterTests port scan expects
        /// free. Out here the stubs cannot collide with any `:0` allocation.
        private static let portBase = 24_210

        var recorded: [Recorded] {
            lock.lock(); defer { lock.unlock() }
            return _recorded
        }

        var paths: [String] { recorded.map(\.path) }

        func requests(at path: String) -> [Recorded] {
            recorded.filter { $0.path == path }
        }

        func start() async throws -> Int {
            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                        channel.pipeline.addHandler(StubHandler(server: self))
                    }
                }
            var lastError: Error?
            for offset in 0..<64 {
                do {
                    let channel = try await bootstrap.bind(
                        host: "127.0.0.1", port: Self.portBase + offset
                    ).get()
                    lock.lock()
                    serverChannel = channel
                    lock.unlock()
                    return channel.localAddress?.port ?? 0
                } catch {
                    lastError = error
                }
            }
            throw lastError ?? NSError(domain: "OffPeakStubServer", code: 1)
        }

        func shutdown() async {
            lock.lock()
            let all = channels + [serverChannel].compactMap { $0 }
            serverChannel = nil
            channels = []
            lock.unlock()
            for channel in all {
                try? await channel.close().get()
            }
            try? await group.shutdownGracefully()
        }

        fileprivate func record(_ request: Recorded) {
            lock.lock(); _recorded.append(request); lock.unlock()
        }

        fileprivate func answer(for request: Recorded) -> Script {
            lock.lock(); defer { lock.unlock() }
            return respond?(request) ?? Script(status: 404, chunks: [Data(#"{"code":404}"#.utf8)])
        }

        fileprivate func track(_ channel: any Channel) {
            lock.lock(); channels.append(channel); lock.unlock()
        }
    }

    private final class StubHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private let server: OffPeakStubServer
        private var head: HTTPRequestHead?
        private var body = Data()

        init(server: OffPeakStubServer) { self.server = server }

        func handlerAdded(context: ChannelHandlerContext) {
            server.track(context.channel)
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let h):
                head = h
                body = Data()
            case .body(let buffer):
                if let bytes = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes) {
                    body.append(bytes)
                }
            case .end:
                guard let head else {
                    context.close(promise: nil)
                    return
                }
                var headers: [String: String] = [:]
                for (name, value) in head.headers {
                    headers[name.lowercased()] = value
                }
                let recorded = OffPeakStubServer.Recorded(
                    method: head.method.rawValue,
                    path: head.uri,
                    headers: headers,
                    body: body.isEmpty ? nil : body)
                server.record(recorded)
                respond(context: context, script: server.answer(for: recorded))
                self.head = nil
                body = Data()
            }
        }

        private func respond(context: ChannelHandlerContext, script: OffPeakStubServer.Script) {
            let channel = context.channel
            Task {
                if let hold = script.hold {
                    await hold.wait()
                }
                var responseHead = HTTPResponseHead(
                    version: .http1_1, status: HTTPResponseStatus(statusCode: script.status))
                var isSSE = false
                for (name, value) in script.headers {
                    if name.lowercased() == "content-type",
                        value.lowercased().contains("text/event-stream")
                    {
                        isSSE = true
                    }
                    responseHead.headers.add(name: name, value: value)
                }
                let total = script.chunks.reduce(0) { $0 + $1.count }
                if !isSSE {
                    responseHead.headers.replaceOrAdd(
                        name: "content-length", value: String(total))
                }
                channel.write(NIOAny(HTTPServerResponsePart.head(responseHead)), promise: nil)
                for chunk in script.chunks {
                    var buffer = channel.allocator.buffer(capacity: chunk.count)
                    buffer.writeBytes(chunk)
                    channel.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
                    channel.flush()
                }
                channel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: nil)
            }
        }
    }

    // MARK: - Virtual clock

    /// Manual clock: `now`/`sleep` on virtual time. A parked sleeper
    /// resumes when `advance` reaches its deadline, or with a
    /// CancellationError when its task is cancelled. Sleep requests are
    /// recorded so cadences are asserted exactly.
    private final class ManualClock: @unchecked Sendable {
        private final class Parked {
            let deadlineMs: Int64
            var continuation: CheckedContinuation<Void, Error>?
            var resumed = false
            init(deadlineMs: Int64) { self.deadlineMs = deadlineMs }
        }

        private let lock = NSLock()
        private var nowMilliseconds: Int64
        private var parkedSleepers: [Parked] = []
        private var _requestedDelays: [TimeInterval] = []

        init(epochSeconds: Int64 = 1_700_000_000) {
            nowMilliseconds = epochSeconds * 1000
        }

        var now: Date {
            Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000)
        }

        var requestedDelays: [TimeInterval] {
            lock.lock(); defer { lock.unlock() }
            return _requestedDelays
        }

        var nowMs: Int64 {
            lock.lock(); defer { lock.unlock() }
            return nowMilliseconds
        }

        func sleep(_ delay: TimeInterval) async throws {
            lock.lock()
            let deadlineMs = nowMilliseconds + Int64(max(0, delay) * 1000)
            _requestedDelays.append(delay)
            lock.unlock()
            let entry = Parked(deadlineMs: deadlineMs)
            try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    self.lock.lock()
                    // Cancelled before the park was registered: resume
                    // immediately (the onCancel handler saw no continuation).
                    if Task.isCancelled {
                        self.lock.unlock()
                        cont.resume(throwing: CancellationError())
                        return
                    }
                    let dueNow = self.nowMilliseconds >= entry.deadlineMs
                    entry.continuation = cont
                    if !dueNow {
                        self.parkedSleepers.append(entry)
                    }
                    self.lock.unlock()
                    if dueNow {
                        cont.resume()
                    }
                }
            }, onCancel: {
                let continuation: CheckedContinuation<Void, Error>? = self.lock.withLock {
                    guard !entry.resumed else { return nil }
                    entry.resumed = true
                    self.parkedSleepers.removeAll { $0 === entry }
                    let cont = entry.continuation
                    entry.continuation = nil
                    return cont
                }
                continuation?.resume(throwing: CancellationError())
            })
        }

        func advance(by seconds: TimeInterval) {
            advance(toMs: nowMilliseconds + Int64(seconds * 1000))
        }

        func advance(toMs target: Int64) {
            lock.lock()
            let capped = max(nowMilliseconds, target)
            nowMilliseconds = capped
            let due = parkedSleepers.filter { $0.deadlineMs <= capped }
            parkedSleepers.removeAll { $0.deadlineMs <= capped }
            for entry in due { entry.resumed = true }
            lock.unlock()
            for entry in due {
                let cont = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                    let cont = entry.continuation
                    entry.continuation = nil
                    return cont
                }
                cont?.resume()
            }
        }

        private var earliestParkedDeadlineMs: Int64? {
            lock.lock(); defer { lock.unlock() }
            return parkedSleepers.map(\.deadlineMs).min()
        }

        /// Drives virtual time forward only to exact parked sleeper
        /// deadlines (never blindly), yielding before every advance so real
        /// work (stub HTTP exchanges, recorded seam calls) is observed
        /// first. Returns true when `condition` held within the timeout.
        func runUntil(timeout: TimeInterval = 5, _ condition: @Sendable () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() {
                if Date() > deadline {
                    return condition()
                }
                try? await Task.sleep(nanoseconds: 2_000_000)
                if condition() { break }
                if let next = earliestParkedDeadlineMs {
                    advance(toMs: next)
                }
            }
            return true
        }
    }

    // MARK: - Small recorders / gates

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                lock.lock()
                if opened {
                    lock.unlock()
                    cont.resume()
                } else {
                    waiters.append(cont)
                    lock.unlock()
                }
            }
        }

        func open() {
            lock.lock()
            opened = true
            let toResume = waiters
            waiters = []
            lock.unlock()
            toResume.forEach { $0.resume() }
        }
    }

    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); defer { lock.unlock() }; value = true }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private final class StringRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [String] = []
        func record(_ value: String) { lock.lock(); defer { lock.unlock() }; _values.append(value) }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return _values }
    }

    private final class StateRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _states: [OffPeakTarget.State] = []
        func record(_ state: OffPeakTarget.State) {
            lock.lock(); defer { lock.unlock() }; _states.append(state)
        }
        var states: [OffPeakTarget.State] { lock.lock(); defer { lock.unlock() }; return _states }
    }

    private final class UsageRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [(Int, Int, Int)] = []
        func record(_ value: (Int, Int, Int)) {
            lock.lock(); defer { lock.unlock() }; _values.append(value)
        }
        var values: [(Int, Int, Int)] { lock.lock(); defer { lock.unlock() }; return _values }
    }

    /// Records every data-plane request the orchestrator issues.
    private final class DataPlaneRecorder: @unchecked Sendable {
        struct Entry {
            let url: String
            let method: String
            let headers: [String: String]
            let timeoutSeconds: Int64
        }

        private let lock = NSLock()
        private var _entries: [Entry] = []
        private let _invoked = LockedFlag()

        var entries: [Entry] { lock.lock(); defer { lock.unlock() }; return _entries }
        var invoked: LockedFlag { _invoked }

        func record(_ entry: Entry) {
            lock.lock(); defer { lock.unlock() }
            _entries.append(entry)
            _invoked.set()
        }

        var first: Entry? { entries.first }
    }

    // MARK: - Fixtures

    private static let availabilityTrue = #"{"code":0,"data":{"can_take_number":true}}"#
    private static func availabilityFalse(nextTakeAt: Int64) -> String {
        #"{"code":0,"data":{"can_take_number":false,"next_take_at":\#(nextTakeAt)}}"#
    }
    private static func takeTicket(id: String, state: String, nextPollAfter: Int? = nil) -> String {
        let hint = nextPollAfter.map { #","next_poll_after":\#($0)"# } ?? ""
        return #"{"code":0,"data":{"ticket_id":"\#(id)","state":"\#(state)"\#(hint)}}"#
    }
    private static func statusRows(
        _ rows: [(id: String, state: String)], nextPollAfter: Int? = nil
    ) -> String {
        let list = rows
            .map { #"{"ticket_id":"\#($0.id)","state":"\#($0.state)"}"# }
            .joined(separator: ",")
        let hint = nextPollAfter.map { #","next_poll_after":\#($0)"# } ?? ""
        return #"{"code":0,"data":{"tickets":[\#(list)]\#(hint)}}"#
    }

    private static let frameStart =
        "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":100}}}\n\n"
    private static let frameDelta =
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":\"héllo\"}\n\n"
    private static let frameUsage =
        "event: message_delta\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":7}}\n\n"
    private static let frameStop = "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
    private static var sseFrames: String { frameStart + frameDelta + frameUsage + frameStop }

    private static func requestBody(model: String = "zai/GLM-5.3[1m]", stream: Bool = true) -> Data {
        let json: [String: Any] = [
            "model": model,
            "max_tokens": 64,
            "stream": stream,
            "messages": [["role": "user", "content": "héllo"]],
        ]
        return (try! JSONSerialization.data(withJSONObject: json))
    }

    // MARK: - Harness builders

    private func makeHTTPClient() -> HTTPClient {
        HTTPClient(eventLoopGroupProvider: .createNew)
    }

    private func makeContext(
        config: OffPeakConfig, httpClient: HTTPClient
    ) -> OffPeakTarget.Context {
        OffPeakTarget.Context(
            config: config,
            httpClient: httpClient,
            jwtProvider: { "offpeak-plan-jwt" },
            credentialProvider: { "ak-1.sk-2" })
    }

    private func enabledConfig(origin: String) -> OffPeakConfig {
        OffPeakConfig(enabled: true, origin: origin)
    }

    /// Reads every outbound part of an EmbeddedChannel.
    private func drain(_ channel: EmbeddedChannel) throws -> (HTTPResponseHead, Data, Bool) {
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
            case .body(.fileRegion): break
            case .end: sawEnd = true
            }
        }
        return (try #require(head), body, sawEnd)
    }

    private func asyncMessagesHead(
        method: HTTPMethod = .POST, uri: String = OffPeakTarget.messagesPath
    ) -> HTTPRequestHead {
        var head = HTTPRequestHead(version: .http1_1, method: method, uri: uri)
        head.headers.add(name: "x-api-key", value: "client-key")
        head.headers.add(name: "anthropic-version", value: "2023-06-01")
        return head
    }

    private func bodyBuffer(_ data: Data) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        return buffer
    }

    private static func sseScriptResponse(frames: String, status: Int = 200) -> HTTPClientResponse {
        var response = HTTPClientResponse(
            status: HTTPResponseStatus(statusCode: status),
            headers: ["content-type": "text/event-stream"])
        let bytes = Data(frames.utf8)
        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        response.body = .bytes(buffer)
        return response
    }

    /// Orchestrator-level harness: real ticket stub + virtual clock +
    /// scripted data-plane seam + EmbeddedChannel sink. Returns the
    /// dependency bag plus the recorders the assertions read.
    private func makeOrchestration(
        config: OffPeakConfig,
        dataPlane: @escaping @Sendable (HTTPClientRequest, Int64) async throws -> HTTPClientResponse,
        transitions: StateRecorder? = nil,
        usage: UsageRecorder? = nil
    ) -> (
        deps: OffPeakTarget.Dependencies, clock: ManualClock, channel: EmbeddedChannel,
        settle: StringRecorder
    ) {
        let clock = ManualClock()
        let channel = EmbeddedChannel()
        let settle = StringRecorder()
        let ticketClient = OffPeakTicketClient(
            origin: config.origin,
            jwtProvider: { "offpeak-plan-jwt" },
            credentialProvider: { "ak-1.sk-2" })
        let deps = OffPeakTarget.Dependencies(
            config: config,
            ticketClient: ticketClient,
            wireBody: Self.requestBody(),
            requestID: "t",
            now: { clock.now },
            sleep: { try await clock.sleep($0) },
            sink: OffPeakTarget.KeepaliveBridge(channel: channel, requestID: "t"),
            dataPlaneExecute: dataPlane,
            settle: { settle.record($0) },
            onUsage: usage.map { recorder in { input, output, cacheRead in
                recorder.record((input, output, cacheRead))
            } },
            onTransition: transitions.map { recorder in { recorder.record($0) } })
        return (deps, clock, channel, settle)
    }

    private func waitUntil(
        timeout: TimeInterval = 5, _ condition: @Sendable () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// Structural check: after exactly `keepaliveCount` keepalive comments,
    /// the body ends with ONE well-formed terminal SSE error event whose
    /// `error.type` matches and whose message is present.
    private func isErrorEventAfterKeepalives(
        _ body: Data, keepaliveCount: Int, type: String
    ) -> Bool {
        var bytes = body
        let keepalive = Data(OffPeakTarget.keepaliveEvent.utf8)
        for _ in 0..<keepaliveCount {
            guard bytes.count >= keepalive.count, bytes.prefix(keepalive.count) == keepalive else {
                return false
            }
            bytes.removeFirst(keepalive.count)
        }
        guard let text = String(data: bytes, encoding: .utf8),
            text.hasPrefix("event: error\ndata: "),
            text.hasSuffix("\n\n")
        else { return false }
        let payload = String(text.dropFirst("event: error\ndata: ".count).dropLast(2))
        guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8))
            as? [String: Any],
            let error = json["error"] as? [String: Any],
            error["type"] as? String == type,
            let message = error["message"] as? String, !message.isEmpty
        else { return false }
        return true
    }

    // MARK: - Route surface (handle level)

    @Test func routePrefixAndByteConstants() {
        #expect(OffPeakTarget.isAsyncRoute("/async/v1/messages"))
        #expect(OffPeakTarget.isAsyncRoute("/async/anything"))
        #expect(!OffPeakTarget.isAsyncRoute("/v1/messages"))
        #expect(!OffPeakTarget.isAsyncRoute("/asyncx"))
        #expect(OffPeakTarget.messagesPath == "/async/v1/messages")
        #expect(OffPeakTarget.healthPath == "/async/v1/health")
        #expect(OffPeakTarget.dataPlanePath == "/api/v1/off-peak/anthropic/v1/messages")
        #expect(OffPeakTarget.keepaliveEvent == ": keepalive\n\n")
        #expect(OffPeakTarget.maxBodyBytes == 4 * 1024 * 1024)
        // Long-wait tolerance: the async data plane's read timeout is
        // maxWaitMinutes + 30 min, NOT the 300 s relay default.
        #expect(OffPeakTarget.dataPlaneReadTimeoutSeconds(for: OffPeakConfig()) == 5400)
        #expect(
            OffPeakTarget.dataPlaneReadTimeoutSeconds(
                for: OffPeakConfig(maxWaitMinutes: 10)) == 2400)
    }

    @Test func healthEndpointReportsEnabledStateWithoutContact() async throws {
        let stub = OffPeakStubServer()
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        stub.respond = { _ in .envelope(Self.availabilityTrue) }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        // Disabled config: {"enabled":false}
        let disabledChannel = EmbeddedChannel()
        _ = await OffPeakTarget.handle(
            head: asyncMessagesHead(method: .GET, uri: OffPeakTarget.healthPath),
            body: bodyBuffer(Data()),
            channel: disabledChannel,
            context: makeContext(
                config: OffPeakConfig(enabled: false, origin: "http://127.0.0.1:\(port)"),
                httpClient: httpClient),
            requestID: "t-health")
        let (disabledHead, disabledBody, _) = try drain(disabledChannel)
        #expect(disabledHead.status == .ok)
        let disabledJSON = try #require(
            try JSONSerialization.jsonObject(with: disabledBody) as? [String: Any])
        #expect(disabledJSON["enabled"] as? Bool == false)

        // Enabled config: {"enabled":true}
        let enabledChannel = EmbeddedChannel()
        _ = await OffPeakTarget.handle(
            head: asyncMessagesHead(method: .GET, uri: OffPeakTarget.healthPath),
            body: bodyBuffer(Data()),
            channel: enabledChannel,
            context: makeContext(
                config: enabledConfig(origin: "http://127.0.0.1:\(port)"), httpClient: httpClient),
            requestID: "t-health")
        let (_, enabledBody, _) = try drain(enabledChannel)
        let enabledJSON = try #require(
            try JSONSerialization.jsonObject(with: enabledBody) as? [String: Any])
        #expect(enabledJSON["enabled"] as? Bool == true)

        // Health never contacts the ticket plane.
        #expect(stub.recorded.isEmpty)
    }

    @Test func healthAnswersWithoutAnyContext() async throws {
        let channel = EmbeddedChannel()
        _ = await OffPeakTarget.handle(
            head: asyncMessagesHead(method: .GET, uri: OffPeakTarget.healthPath),
            body: bodyBuffer(Data()), channel: channel, context: nil, requestID: "t")
        let (head, body, _) = try drain(channel)
        #expect(head.status == .ok)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["enabled"] as? Bool == false)
    }

    @Test func disabledMessagesRouteAnswersAnthropic404WithoutContact() async throws {
        let stub = OffPeakStubServer()
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        // Disabled via config…
        let channel = EmbeddedChannel()
        let state = await OffPeakTarget.handle(
            head: asyncMessagesHead(),
            body: bodyBuffer(Self.requestBody()),
            channel: channel,
            context: makeContext(
                config: OffPeakConfig(enabled: false, origin: "http://127.0.0.1:\(port)"),
                httpClient: httpClient),
            requestID: "t")
        let (head, body, sawEnd) = try drain(channel)
        #expect(head.status == .notFound)
        #expect(sawEnd)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["type"] as? String == "error")
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["type"] as? String == "not_found_error")
        #expect(state == nil)

        // …and with no context at all.
        let nilChannel = EmbeddedChannel()
        _ = await OffPeakTarget.handle(
            head: asyncMessagesHead(), body: bodyBuffer(Self.requestBody()),
            channel: nilChannel, context: nil, requestID: "t")
        let (nilHead, _, _) = try drain(nilChannel)
        #expect(nilHead.status == .notFound)

        // Default-OFF means ZERO contact with anything upstream.
        #expect(stub.recorded.isEmpty)
    }

    @Test func unknownAsyncRouteAnswersAnthropic404() async throws {
        let stub = OffPeakStubServer()
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }
        let context = makeContext(
            config: enabledConfig(origin: "http://127.0.0.1:\(port)"), httpClient: httpClient)

        for (method, uri) in [
            (HTTPMethod.POST, "/async/v1/other"), (HTTPMethod.GET, "/async/v1/messages"),
            (HTTPMethod.POST, "/async/"),
        ] {
            let channel = EmbeddedChannel()
            _ = await OffPeakTarget.handle(
                head: asyncMessagesHead(method: method, uri: uri),
                body: bodyBuffer(Self.requestBody()), channel: channel, context: context,
                requestID: "t")
            let (head, body, _) = try drain(channel)
            #expect(head.status == .notFound, "\(uri) must 404")
            let json = try #require(
                try JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect((json["error"] as? [String: Any])?["type"] as? String == "not_found_error")
        }
        #expect(stub.recorded.isEmpty)
    }

    // MARK: - Pre-flight (zero ticket-server contact on rejection)

    @Test func nonStreamRequestRejectedWithAsyncStreamRequiredAndZeroTicketCalls() async throws {
        let stub = OffPeakStubServer()
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let channel = EmbeddedChannel()
        _ = await OffPeakTarget.handle(
            head: asyncMessagesHead(),
            body: bodyBuffer(Self.requestBody(stream: false)),
            channel: channel,
            context: makeContext(
                config: enabledConfig(origin: "http://127.0.0.1:\(port)"), httpClient: httpClient),
            requestID: "t")
        let (head, body, _) = try drain(channel)
        #expect(head.status == .badRequest)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["type"] as? String == "async_stream_required")
        // Never leak a ticket on a malformed request.
        #expect(stub.recorded.isEmpty)
    }

    @Test func unparseableBodyRejectedPreTake() async throws {
        let stub = OffPeakStubServer()
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        let channel = EmbeddedChannel()
        _ = await OffPeakTarget.handle(
            head: asyncMessagesHead(),
            body: bodyBuffer(Data("not json at all".utf8)),
            channel: channel,
            context: makeContext(
                config: enabledConfig(origin: "http://127.0.0.1:\(port)"), httpClient: httpClient),
            requestID: "t")
        let (head, body, _) = try drain(channel)
        #expect(head.status == .badRequest)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect((json["error"] as? [String: Any])?["type"] as? String == "invalid_request_error")
        #expect(stub.recorded.isEmpty)
    }

    @Test func oversizedBodyRejectedPreTake() async throws {
        let stub = OffPeakStubServer()
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }

        var huge = Self.requestBody()
        huge.append(Data(repeating: 0x20, count: OffPeakTarget.maxBodyBytes))
        #expect(huge.count > OffPeakTarget.maxBodyBytes)

        let channel = EmbeddedChannel()
        _ = await OffPeakTarget.handle(
            head: asyncMessagesHead(),
            body: bodyBuffer(huge),
            channel: channel,
            context: makeContext(
                config: enabledConfig(origin: "http://127.0.0.1:\(port)"), httpClient: httpClient),
            requestID: "t")
        let (head, _, _) = try drain(channel)
        #expect(head.status == .payloadTooLarge)
        #expect(stub.recorded.isEmpty)
    }

    // MARK: - Happy path, handle level (real wire both planes)

    @Test func handleImmediateReadyRelaysSSEUntouchedCanonicalizesModelAndSettles()
        async throws
    {
        let stub = OffPeakStubServer()
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }
        stub.respond = { request in
            switch request.path {
            case "/api/v1/off-peak/ticket/availability":
                return .envelope(Self.availabilityTrue)
            case "/api/v1/off-peak/ticket":
                return .envelope(Self.takeTicket(id: "tkt-h", state: "ready"))
            case OffPeakTarget.dataPlanePath:
                return Script(
                    status: 200,
                    headers: ["content-type": "text/event-stream"],
                    chunks: [Data(Self.sseFrames.utf8)])
            default:
                return Script(status: 404, chunks: [Data(#"{"code":404}"#.utf8)])
            }
        }

        let channel = EmbeddedChannel()
        let trafficLog = await MainActor.run { TrafficLog() }
        let state = await OffPeakTarget.handle(
            head: asyncMessagesHead(),
            body: bodyBuffer(Self.requestBody(model: "zai/GLM-5.3[1m]")),
            channel: channel,
            context: makeContext(
                config: enabledConfig(origin: "http://127.0.0.1:\(port)"), httpClient: httpClient),
            trafficLog: trafficLog,
            requestID: "t-happy")
        #expect(state == .done)

        let (head, body, sawEnd) = try drain(channel)
        #expect(head.status == .ok)
        #expect(
            (head.headers.first(name: "content-type") ?? "").lowercased()
                .contains("text/event-stream"))
        #expect(sawEnd)
        // Immediate ready: zero keepalives, SSE bytes byte-for-byte untouched.
        #expect(body == Data(Self.sseFrames.utf8))

        // Data-plane request on the wire: unsigned identity + ticket header.
        let dataPlane = try #require(stub.requests(at: OffPeakTarget.dataPlanePath).first)
        #expect(dataPlane.method == "POST")
        #expect(dataPlane.header("authorization") == "Bearer offpeak-plan-jwt")
        #expect(dataPlane.header("x-coding-plan-api-key") == "ak-1.sk-2")
        #expect(dataPlane.header("x-off-peak-ticket-id") == "tkt-h")
        #expect(dataPlane.header("anthropic-version") == "2023-06-01")
        #expect(
            dataPlane.header("user-agent")
                == RelayTarget.userAgent(for: RelayTarget.clientVersion))
        for unsigned in [
            "x-client-ts", "x-client-sig", "x-client-nonce", "x-client-pow", "x-app-id",
        ] {
            #expect(dataPlane.header(unsigned) == nil, "data plane must not carry \(unsigned)")
        }
        // Model canonicalized (Task 5), body otherwise preserved.
        let sentJSON = try #require(dataPlane.jsonBody)
        #expect(sentJSON["model"] as? String == "GLM-5.3")
        #expect((sentJSON["messages"] as? [[String: Any]])?.first?["content"] as? String == "héllo")
        // task_id shape on the take call.
        let take = try #require(stub.requests(at: "/api/v1/off-peak/ticket").first)
        #expect((take.jsonBody?["task_id"] as? String)?.hasPrefix("zgate-") == true)

        // Settle fired exactly once for the held ticket (fire-and-forget on
        // the real wire — poll the stub for it).
        let settled = await waitUntil {
            !stub.requests(at: "/api/v1/off-peak/ticket/tkt-h/settle").isEmpty
        }
        #expect(settled)

        // One traffic row for the surface.
        let entries = await MainActor.run { trafficLog.entries }
        #expect(entries.count == 1)
        #expect(entries.first?.httpStatus == 200)
        #expect(entries.first?.model == "GLM-5.3")
    }

    // MARK: - Token stats (serve level, Task 3)

    /// Day formatter matching TokenStatsStore's file name (yyyy-MM-dd).
    private nonisolated(unsafe) static let statsDayFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    /// Today's on-disk token-stats snapshot, or nil when not (yet) written
    /// (the add rides a fire-and-forget MainActor task, the persist a
    /// detached background write — poll for it).
    private static func todayStatsSnapshot() -> DailyTokenSnapshot? {
        let url = AppPaths.appSupport
            .appendingPathComponent("token-stats-\(statsDayFormatter.string(from: Date())).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DailyTokenSnapshot.self, from: data)
    }

    /// A vendor-keyed serve records usage in the day's stats file with the
    /// forwarder's convention (Task 4's routed configuration): stats model =
    /// canonical wire model, source model = the RAW request model. The
    /// vendorless /async face (`handle`) passes vendorID nil and mirrors the
    /// passthrough path: no stats row.
    @Test("served async request records token usage")
    func asyncServeRecordsTokenStats() async throws {
        let stub = OffPeakStubServer()
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        let httpClient = makeHTTPClient()
        defer { Task { try? await httpClient.shutdown() } }
        stub.respond = { request in
            switch request.path {
            case "/api/v1/off-peak/ticket/availability":
                return .envelope(Self.availabilityTrue)
            case "/api/v1/off-peak/ticket":
                return .envelope(Self.takeTicket(id: "tkt-stats", state: "ready"))
            case OffPeakTarget.dataPlanePath:
                return Script(
                    status: 200,
                    headers: ["content-type": "text/event-stream"],
                    chunks: [Data(Self.sseFrames.utf8)])
            default:
                return Script(status: 404, chunks: [Data(#"{"code":404}"#.utf8)])
            }
        }

        let tokenStatsStore = await MainActor.run { TokenStatsStore() }
        let vendorID = UUID()
        let channel = EmbeddedChannel()
        let state = await OffPeakTarget.serve(
            head: asyncMessagesHead(),
            body: bodyBuffer(Self.requestBody(model: "zai/GLM-5.3[1m]")),
            channel: channel,
            context: makeContext(
                config: enabledConfig(origin: "http://127.0.0.1:\(port)"),
                httpClient: httpClient),
            targetModel: nil,
            trafficLog: nil,
            tokenStatsStore: tokenStatsStore,
            vendorID: vendorID,
            requestID: "t-stats")
        #expect(state == .done)

        // One row for the serving vendor under the CANONICAL model.
        let appeared = await waitUntil {
            Self.todayStatsSnapshot()?.usageByVendorAndModel[vendorID.uuidString]?["GLM-5.3"]
                != nil
        }
        #expect(appeared)
        let record = try #require(
            Self.todayStatsSnapshot()?.usageByVendorAndModel[vendorID.uuidString]?["GLM-5.3"])
        #expect(record.inputTokens > 0)
        #expect(record.outputTokens > 0)

        // Source-model attribution (mapped-route convention): the RAW
        // request model, not the canonical wire model.
        let sourceRecord = try #require(
            Self.todayStatsSnapshot()?.sourceModelUsage["zai/GLM-5.3[1m]"])
        #expect(sourceRecord.inputTokens > 0)
        #expect(sourceRecord.outputTokens > 0)
    }

    // MARK: - Orchestrator: availability wait + keepalives + happy stream

    @Test func orchestrateWaitsForAvailabilityWithKeepalivesThenRelaysUntouchedAndSettles()
        async throws
    {
        let stub = OffPeakStubServer()
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        let epoch = ManualClock().nowMs
        // next_take_at rides the wire as UNIX SECONDS (Task 9's contract).
        let epochSeconds = epoch / 1000
        stub.respond = { request in
            switch request.path {
            case "/api/v1/off-peak/ticket/availability":
                // Closed until T+10s, then open.
                return .envelope(
                    stub.requests(at: "/api/v1/off-peak/ticket/availability").count == 1
                        ? Self.availabilityFalse(nextTakeAt: epochSeconds + 10)
                        : Self.availabilityTrue)
            case "/api/v1/off-peak/ticket":
                return .envelope(Self.takeTicket(id: "tkt-1", state: "queued"))
            case "/api/v1/off-peak/ticket/status":
                return .envelope(Self.statusRows([(id: "tkt-1", state: "ready")]))
            default:
                return Script(status: 404, chunks: [Data(#"{"code":404}"#.utf8)])
            }
        }

        let recorder = DataPlaneRecorder()
        let gate = Gate()
        let transitions = StateRecorder()
        let usage = UsageRecorder()
        let (deps, clock, channel, settle) = makeOrchestration(
            config: enabledConfig(origin: "http://127.0.0.1:\(port)"),
            dataPlane: { request, timeout in
                recorder.record(DataPlaneRecorder.Entry(
                    url: request.url, method: request.method.rawValue,
                    headers: Dictionary(
                        uniqueKeysWithValues: request.headers.map { ($0.lowercased(), $1) }),
                    timeoutSeconds: timeout))
                await gate.wait()
                return Self.sseScriptResponse(frames: Self.sseFrames)
            },
            transitions: transitions,
            usage: usage)

        let done = LockedFlag()
        let task = Task {
            let state = await OffPeakTarget.orchestrate(deps)
            done.set()
            return state
        }
        // Availability wait T0→T10 (keepalives at 3, 6, 9), first poll
        // after 5 s (T10→T15, keepalive at T12) → ready. The gated
        // data-plane head holds; the bridge keepalive cadence fires at
        // T18; release the gate and let the stream run.
        let statusRecorded = await clock.runUntil {
            !stub.requests(at: "/api/v1/off-peak/ticket/status").isEmpty
        }
        #expect(statusRecorded)
        _ = await clock.runUntil { clock.nowMs >= epoch + 18_000 }
        try? await Task.sleep(nanoseconds: 50_000_000)  // let the T21 park record
        gate.open()
        _ = await clock.runUntil { done.isSet }
        let state = await task.value

        // Wait-phase cadence pinned exactly (virtual clock): availability
        // [3,3,3,1] + poll wait [2,3]. (The bridge parks one more 3 s sleep
        // that the data-plane head cancels.)
        #expect(Array(clock.requestedDelays.prefix(6)) == [3, 3, 3, 1, 2, 3])

        let (head, body, sawEnd) = try drain(channel)
        #expect(head.status == .ok)
        #expect(
            (head.headers.first(name: "content-type") ?? "").lowercased()
                .contains("text/event-stream"))
        #expect(sawEnd)
        // Five keepalive comments precede the stream (3, 6, 9, 12, 18);
        // frames relayed byte-for-byte untouched; never a keepalive after
        // the first frame byte.
        let keepalive = OffPeakTarget.keepaliveEvent
        var expected = Data(String(repeating: keepalive, count: 5).utf8)
        expected.append(Data(Self.sseFrames.utf8))
        #expect(body == expected)

        // State machine WAIT→READY→DONE.
        #expect(transitions.states.count == 3)
        #expect(transitions.states[0] == .wait)
        guard case .ready(let ticketID) = transitions.states[1] else {
            Issue.record("expected .ready, got \(transitions.states)")
            return
        }
        #expect(ticketID == "tkt-1")
        #expect(transitions.states[2] == .done)
        #expect(state == .done)

        // Data plane request: path, ticket header, unsigned, long timeout.
        let entry = try #require(recorder.first)
        #expect(entry.url == "http://127.0.0.1:\(port)\(OffPeakTarget.dataPlanePath)")
        #expect(entry.headers["x-off-peak-ticket-id"] == "tkt-1")
        #expect(entry.headers["authorization"] == "Bearer offpeak-plan-jwt")
        #expect(entry.headers["x-coding-plan-api-key"] == "ak-1.sk-2")
        #expect(entry.headers["anthropic-version"] == "2023-06-01")
        #expect(entry.headers["x-client-sig"] == nil)
        #expect(entry.timeoutSeconds == 5400)

        // Settle exactly once, for the held ticket.
        #expect(settle.values == ["tkt-1"])
        // Usage accounting: folded totals from the relayed events.
        #expect(usage.values.count == 1)
        #expect(usage.values.first?.0 == 100)
        #expect(usage.values.first?.1 == 7)
        #expect(usage.values.first?.2 == 0)
    }

    @Test func serverPollHintLargerThanIntervalWins() async throws {
        let stub = OffPeakStubServer()
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        stub.respond = { request in
            switch request.path {
            case "/api/v1/off-peak/ticket/availability":
                return .envelope(Self.availabilityTrue)
            case "/api/v1/off-peak/ticket":
                // Server hint 8 s > pollIntervalSeconds 5 s.
                return .envelope(Self.takeTicket(id: "tkt-h", state: "queued", nextPollAfter: 8))
            case "/api/v1/off-peak/ticket/status":
                return .envelope(Self.statusRows([(id: "tkt-h", state: "ready")]))
            default:
                return Script(status: 404, chunks: [Data(#"{"code":404}"#.utf8)])
            }
        }
        let transitions = StateRecorder()
        let (deps, clock, _, settle) = makeOrchestration(
            config: enabledConfig(origin: "http://127.0.0.1:\(port)"),
            dataPlane: { _, _ in Self.sseScriptResponse(frames: Self.frameStop) },
            transitions: transitions)
        let done = LockedFlag()
        let task = Task {
            let state = await OffPeakTarget.orchestrate(deps)
            done.set()
            return state
        }
        _ = await clock.runUntil { done.isSet }
        let state = await task.value

        // The 8 s server hint beats the 5 s floor: sleeps [3, 3, 2] with
        // keepalives at T+3 and T+6 before the T+8 poll.
        #expect(Array(clock.requestedDelays.prefix(3)) == [3, 3, 2])
        #expect(state == .done)
        #expect(settle.values == ["tkt-h"])
        #expect(transitions.states.last == .done)
    }

    @Test func statusBatchHintCarriesToNextPoll() async throws {
        let stub = OffPeakStubServer()
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        stub.respond = { request in
            switch request.path {
            case "/api/v1/off-peak/ticket/availability":
                return .envelope(Self.availabilityTrue)
            case "/api/v1/off-peak/ticket":
                return .envelope(Self.takeTicket(id: "tkt-h", state: "queued"))
            case "/api/v1/off-peak/ticket/status":
                // First poll still queued with a 9 s hint; second ready.
                let polls = stub.requests(at: "/api/v1/off-peak/ticket/status").count
                return .envelope(
                    polls == 1
                        ? Self.statusRows([(id: "tkt-h", state: "queued")], nextPollAfter: 9)
                        : Self.statusRows([(id: "tkt-h", state: "ready")]))
            default:
                return Script(status: 404, chunks: [Data(#"{"code":404}"#.utf8)])
            }
        }
        let (deps, clock, _, settle) = makeOrchestration(
            config: enabledConfig(origin: "http://127.0.0.1:\(port)"),
            dataPlane: { _, _ in Self.sseScriptResponse(frames: Self.frameStop) })
        let done = LockedFlag()
        let task = Task {
            let state = await OffPeakTarget.orchestrate(deps)
            done.set()
            return state
        }
        _ = await clock.runUntil { done.isSet }
        let state = await task.value

        // First poll waits pollIntervalSeconds (5): [3, 2]; the batch's 9 s
        // hint wins over 5 for the second wait: [1, 3, 3, 2].
        #expect(Array(clock.requestedDelays.prefix(6)) == [3, 2, 1, 3, 3, 2])
        #expect(state == .done)
        #expect(settle.values == ["tkt-h"])
    }

    // MARK: - Poll-failure tolerance

    @Test func threeControlFailuresToleratedThenFourthAborts() async throws {
        let stub = OffPeakStubServer()
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        stub.respond = { _ in .envelope(#"{"code":42,"msg":"plane down"}"#) }
        let transitions = StateRecorder()
        let (deps, clock, channel, settle) = makeOrchestration(
            config: enabledConfig(origin: "http://127.0.0.1:\(port)"),
            dataPlane: { _, _ in
                Issue.record("data plane must never be reached")
                return Self.sseScriptResponse(frames: Self.frameStop)
            },
            transitions: transitions)
        let done = LockedFlag()
        let task = Task {
            let state = await OffPeakTarget.orchestrate(deps)
            done.set()
            return state
        }
        _ = await clock.runUntil { done.isSet }
        let state = await task.value

        // Exactly 4 availability attempts (3 tolerated, 4th aborts).
        #expect(stub.requests(at: "/api/v1/off-peak/ticket/availability").count == 4)
        // Backoff = min(pollInterval, 2 s) between attempts.
        #expect(clock.requestedDelays == [2, 1, 1, 2])
        #expect(state == .aborted(.controlFailuresExceeded))
        #expect(transitions.states == [.wait, .aborted(.controlFailuresExceeded)])
        // One keepalive fired at T+3 (head opened) → the 529-shaped error
        // rides as a terminal SSE event, never a second HTTP head.
        let (head, body, sawEnd) = try drain(channel)
        #expect(head.status == .ok)
        #expect(sawEnd)
        #expect(isErrorEventAfterKeepalives(body, keepaliveCount: 1, type: "overloaded_error"))
        // No ticket was ever taken → no settle.
        #expect(settle.values.isEmpty)
        #expect(stub.requests(at: "/api/v1/off-peak/ticket").isEmpty)
    }

    @Test func vanishedTicketRowsAreTransientNotExpiry() async throws {
        let stub = OffPeakStubServer()
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        stub.respond = { request in
            switch request.path {
            case "/api/v1/off-peak/ticket/availability":
                return .envelope(Self.availabilityTrue)
            case "/api/v1/off-peak/ticket":
                return .envelope(Self.takeTicket(id: "tkt-1", state: "queued", nextPollAfter: 2))
            case "/api/v1/off-peak/ticket/status":
                // Three consecutive "all tickets vanished" batches (code 0,
                // absent tickets array — Task 9's suspicious-but-transient
                // shape), then ready.
                let polls = stub.requests(at: "/api/v1/off-peak/ticket/status").count
                if polls <= 3 {
                    return .envelope(#"{"code":0,"data":{}}"#)
                }
                return .envelope(Self.statusRows([(id: "tkt-1", state: "ready")]))
            default:
                return Script(status: 404, chunks: [Data(#"{"code":404}"#.utf8)])
            }
        }
        let transitions = StateRecorder()
        let (deps, clock, channel, settle) = makeOrchestration(
            config: enabledConfig(origin: "http://127.0.0.1:\(port)"),
            dataPlane: { _, _ in Self.sseScriptResponse(frames: Self.frameStop) },
            transitions: transitions)
        let done = LockedFlag()
        let task = Task {
            let state = await OffPeakTarget.orchestrate(deps)
            done.set()
            return state
        }
        _ = await clock.runUntil { done.isSet }
        let state = await task.value

        // Vanished rows consumed the tolerance budget but were NEVER expiry:
        // exactly one take, four status calls, happy end.
        #expect(state == .done)
        #expect(stub.requests(at: "/api/v1/off-peak/ticket").count == 1)
        #expect(stub.requests(at: "/api/v1/off-peak/ticket/status").count == 4)
        #expect(settle.values == ["tkt-1"])
        let (_, _, sawEnd) = try drain(channel)
        #expect(sawEnd)
    }

    // MARK: - Expiry + re-take

    @Test func expiredTicketRetakesExactlyOnceAndSucceeds() async throws {
        let stub = OffPeakStubServer()
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        stub.respond = { request in
            switch request.path {
            case "/api/v1/off-peak/ticket/availability":
                return .envelope(Self.availabilityTrue)
            case "/api/v1/off-peak/ticket":
                // The re-take (second POST) answers ready with a NEW id.
                let takes = stub.requests(at: "/api/v1/off-peak/ticket").count
                return .envelope(
                    takes == 1
                        ? Self.takeTicket(id: "tkt-1", state: "queued", nextPollAfter: 5)
                        : Self.takeTicket(id: "tkt-2", state: "ready"))
            case "/api/v1/off-peak/ticket/status":
                return .envelope(Self.statusRows([(id: "tkt-1", state: "expired")]))
            default:
                return Script(status: 404, chunks: [Data(#"{"code":404}"#.utf8)])
            }
        }
        let recorder = DataPlaneRecorder()
        let transitions = StateRecorder()
        let (deps, clock, _, settle) = makeOrchestration(
            config: enabledConfig(origin: "http://127.0.0.1:\(port)"),
            dataPlane: { request, timeout in
                recorder.record(DataPlaneRecorder.Entry(
                    url: request.url, method: "POST", headers: [:], timeoutSeconds: timeout))
                return Self.sseScriptResponse(frames: Self.frameStop)
            },
            transitions: transitions)
        let done = LockedFlag()
        let task = Task {
            let state = await OffPeakTarget.orchestrate(deps)
            done.set()
            return state
        }
        _ = await clock.runUntil { done.isSet }
        let state = await task.value

        #expect(state == .done)
        #expect(stub.requests(at: "/api/v1/off-peak/ticket").count == 2)
        #expect(transitions.states.last == .done)
        // The data plane rode the RETAKEN ticket.
        let readyStates = transitions.states.filter {
            if case .ready = $0 { return true }
            return false
        }
        guard case .ready(let ticketID)? = readyStates.first else {
            Issue.record("expected a .ready transition, got \(transitions.states)")
            return
        }
        #expect(ticketID == "tkt-2")
        #expect(recorder.first?.url.contains(OffPeakTarget.dataPlanePath) == true)
        // Settle once, for the ticket held at completion.
        #expect(settle.values == ["tkt-2"])
    }

    @Test func expiredTwiceAnswers529ShapedErrorAndSettlesHeldTicket() async throws {
        let stub = OffPeakStubServer()
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        stub.respond = { request in
            switch request.path {
            case "/api/v1/off-peak/ticket/availability":
                return .envelope(Self.availabilityTrue)
            case "/api/v1/off-peak/ticket":
                let takes = stub.requests(at: "/api/v1/off-peak/ticket").count
                return .envelope(
                    Self.takeTicket(id: "tkt-\(takes)", state: "queued", nextPollAfter: 5))
            case "/api/v1/off-peak/ticket/status":
                let takes = stub.requests(at: "/api/v1/off-peak/ticket").count
                return .envelope(Self.statusRows([(id: "tkt-\(takes)", state: "expired")]))
            default:
                return Script(status: 404, chunks: [Data(#"{"code":404}"#.utf8)])
            }
        }
        let transitions = StateRecorder()
        let (deps, clock, channel, settle) = makeOrchestration(
            config: enabledConfig(origin: "http://127.0.0.1:\(port)"),
            dataPlane: { _, _ in
                Issue.record("data plane must never be reached")
                return Self.sseScriptResponse(frames: Self.frameStop)
            },
            transitions: transitions)
        let done = LockedFlag()
        let task = Task {
            let state = await OffPeakTarget.orchestrate(deps)
            done.set()
            return state
        }
        _ = await clock.runUntil { done.isSet }
        let state = await task.value

        // Two takes (initial + the one allowed re-take), two expiry polls —
        // the second death reacts IMMEDIATELY (no idle poll interval).
        #expect(stub.requests(at: "/api/v1/off-peak/ticket").count == 2)
        #expect(stub.requests(at: "/api/v1/off-peak/ticket/status").count == 2)
        #expect(state == .expired)
        #expect(transitions.states.last == .expired)
        // Keepalives at T+3, T+6, T+9 opened the head → the 529-shaped
        // error rides as a terminal SSE event.
        let (head, body, sawEnd) = try drain(channel)
        #expect(head.status == .ok)
        #expect(sawEnd)
        #expect(isErrorEventAfterKeepalives(body, keepaliveCount: 3, type: "overloaded_error"))
        // The ticket held at exit (the re-take) is settled.
        #expect(settle.values == ["tkt-2"])
    }

    // MARK: - Max wait

    @Test func maxWaitExceededAborts529WithoutTake() async throws {
        let stub = OffPeakStubServer()
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        let epochSeconds = ManualClock().nowMs / 1000
        stub.respond = { request in
            if request.path == "/api/v1/off-peak/ticket/availability" {
                // next_take_at (unix seconds) far beyond the 60 s deadline.
                return .envelope(Self.availabilityFalse(nextTakeAt: epochSeconds + 3600))
            }
            return Script(status: 404, chunks: [Data(#"{"code":404}"#.utf8)])
        }
        let transitions = StateRecorder()
        let config = OffPeakConfig(
            enabled: true, origin: "http://127.0.0.1:\(port)",
            maxWaitMinutes: 1, pollIntervalSeconds: 5, keepaliveSeconds: 10)
        let (deps, clock, channel, settle) = makeOrchestration(
            config: config,
            dataPlane: { _, _ in
                Issue.record("data plane must never be reached")
                return Self.sseScriptResponse(frames: Self.frameStop)
            },
            transitions: transitions)
        let done = LockedFlag()
        let task = Task {
            let state = await OffPeakTarget.orchestrate(deps)
            done.set()
            return state
        }
        _ = await clock.runUntil { done.isSet }
        let state = await task.value

        // Bounded by maxWaitMinutes (1 min): keepalives at 10..50, abort at 60.
        #expect(state == .aborted(.maxWaitExceeded))
        #expect(stub.requests(at: "/api/v1/off-peak/ticket/availability").count == 1)
        #expect(stub.requests(at: "/api/v1/off-peak/ticket").isEmpty)
        #expect(settle.values.isEmpty)
        let (head, body, sawEnd) = try drain(channel)
        #expect(head.status == .ok)
        #expect(sawEnd)
        #expect(isErrorEventAfterKeepalives(body, keepaliveCount: 5, type: "overloaded_error"))
    }

    // MARK: - Client disconnect

    @Test func clientDisconnectDuringWaitAbortsAndSettles() async throws {
        let stub = OffPeakStubServer()
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        stub.respond = { request in
            switch request.path {
            case "/api/v1/off-peak/ticket/availability":
                return .envelope(Self.availabilityTrue)
            case "/api/v1/off-peak/ticket":
                return .envelope(Self.takeTicket(id: "tkt-gone", state: "queued", nextPollAfter: 5))
            default:
                return Script(status: 404, chunks: [Data(#"{"code":404}"#.utf8)])
            }
        }
        let (deps, clock, _, settle) = makeOrchestration(
            config: enabledConfig(origin: "http://127.0.0.1:\(port)"),
            dataPlane: { _, _ in
                Issue.record("data plane must never be reached")
                return Self.sseScriptResponse(frames: Self.frameStop)
            })
        let done = LockedFlag()
        let task = Task {
            let state = await OffPeakTarget.orchestrate(deps)
            done.set()
            return state
        }
        // The client's channel goes away mid-wait — the production wiring
        // (handle) cancels the orchestration on closeFuture. Cancel while
        // the first keepalive interval is parked: the sleep throws, the
        // settle defer fires, the ticket is released.
        let parked = await clock.runUntil { !clock.requestedDelays.isEmpty }
        #expect(parked)
        task.cancel()
        await clock.runUntil { done.isSet }
        let state = await task.value

        #expect(state == .aborted(.cancelled))
        #expect(settle.values == ["tkt-gone"])
        #expect(clock.requestedDelays == [3])
    }

    @Test func keepaliveBridgeOpensHeadLazilyOnFirstWrite() async throws {
        let channel = EmbeddedChannel()
        let bridge = OffPeakTarget.KeepaliveBridge(channel: channel, requestID: "t")

        #expect(bridge.responseHeadSent == false)
        try await bridge.writeKeepalive()
        #expect(bridge.responseHeadSent == true)
        try await bridge.writeKeepalive()
        try await bridge.finish()

        let (head, body, sawEnd) = try drain(channel)
        #expect(head.status == .ok)
        #expect(
            (head.headers.first(name: "content-type") ?? "").lowercased()
                .contains("text/event-stream"))
        #expect(sawEnd)
        #expect(
            body == Data(
                String(repeating: OffPeakTarget.keepaliveEvent, count: 2).utf8))
    }

    // MARK: - Data-plane failures

    @Test func dataPlaneTransportFailureAnswers502AndSettles() async throws {
        let stub = OffPeakStubServer()
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        stub.respond = { request in
            switch request.path {
            case "/api/v1/off-peak/ticket/availability":
                return .envelope(Self.availabilityTrue)
            case "/api/v1/off-peak/ticket":
                return .envelope(Self.takeTicket(id: "tkt-dp", state: "ready"))
            default:
                return Script(status: 404, chunks: [Data(#"{"code":404}"#.utf8)])
            }
        }
        let gate = Gate()
        let recorder = DataPlaneRecorder()
        let (deps, clock, channel, settle) = makeOrchestration(
            config: enabledConfig(origin: "http://127.0.0.1:\(port)"),
            dataPlane: { _, _ in
                recorder.record(DataPlaneRecorder.Entry(
                    url: "unused", method: "POST", headers: [:], timeoutSeconds: 0))
                await gate.wait()
                throw HTTPClientError.connectTimeout
            })
        let done = LockedFlag()
        let task = Task {
            let state = await OffPeakTarget.orchestrate(deps)
            done.set()
            return state
        }
        // Wait for the data plane to be INVOKED before releasing — real-time
        // polling only (no virtual advance), so no keepalive deadline is
        // ever reached and the head stays unopened: the client gets a real
        // HTTP 502.
        let invoked = await waitUntil { recorder.invoked.isSet }
        #expect(invoked)
        try? await Task.sleep(nanoseconds: 50_000_000)
        gate.open()
        _ = await clock.runUntil { done.isSet }
        let state = await task.value

        #expect(state == .aborted(.dataPlaneFailed))
        #expect(settle.values == ["tkt-dp"])
        let (head, body, sawEnd) = try drain(channel)
        #expect(head.status == .badGateway)
        #expect(sawEnd)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect((json["error"] as? [String: Any])?["type"] as? String == "api_error")
    }

    @Test func dataPlaneNon2xxIsDrainedAndAnsweredWithUpstreamShape() async throws {
        let stub = OffPeakStubServer()
        let port = try await stub.start()
        defer { Task { await stub.shutdown() } }
        stub.respond = { request in
            switch request.path {
            case "/api/v1/off-peak/ticket/availability":
                return .envelope(Self.availabilityTrue)
            case "/api/v1/off-peak/ticket":
                return .envelope(Self.takeTicket(id: "tkt-429", state: "ready"))
            default:
                return Script(status: 404, chunks: [Data(#"{"code":404}"#.utf8)])
            }
        }
        let gate = Gate()
        let recorder = DataPlaneRecorder()
        let (deps, clock, channel, settle) = makeOrchestration(
            config: enabledConfig(origin: "http://127.0.0.1:\(port)"),
            dataPlane: { _, _ in
                recorder.record(DataPlaneRecorder.Entry(
                    url: "unused", method: "POST", headers: [:], timeoutSeconds: 0))
                await gate.wait()
                var response = HTTPClientResponse(
                    status: .tooManyRequests,
                    headers: ["content-type": "application/json"])
                let errorBody = Data(
                    #"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#
                        .utf8)
                var buffer = ByteBufferAllocator().buffer(capacity: errorBody.count)
                buffer.writeBytes(errorBody)
                response.body = .bytes(buffer)
                return response
            })
        let done = LockedFlag()
        let task = Task {
            let state = await OffPeakTarget.orchestrate(deps)
            done.set()
            return state
        }
        let invoked = await waitUntil { recorder.invoked.isSet }
        #expect(invoked)
        try? await Task.sleep(nanoseconds: 50_000_000)
        gate.open()
        _ = await clock.runUntil { done.isSet }
        let state = await task.value

        // A drained error answer is a complete response: state .done, settle.
        #expect(state == .done)
        #expect(settle.values == ["tkt-429"])
        let (head, body, sawEnd) = try drain(channel)
        #expect(head.status == .tooManyRequests)
        #expect(sawEnd)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["type"] as? String == "rate_limit_error")
        #expect(error["message"] as? String == "slow down")
    }

    // MARK: - Config (decode-if-absent default, encode-if-changed)

    @Test func offPeakConfigDefaultsDecodeAndPersistOnlyWhenChanged() throws {
        // Absent section (every pre-wave install): defaults, byte-stable.
        let legacy = AppConfig.makeZGateDefaultRouting(AppConfig())
        let legacyData = try JSONEncoder.prettyForTests.encode(legacy)
        #expect(!String(data: legacyData, encoding: .utf8)!.contains("offPeak"))
        let decoded = try JSONDecoder().decode(AppConfig.self, from: legacyData)
        #expect(decoded.offPeak == OffPeakConfig())
        #expect(decoded.offPeak.enabled == false)
        #expect(decoded.offPeak.origin == "https://zcode.z.ai")
        #expect(decoded.offPeak.maxWaitMinutes == 60)
        #expect(decoded.offPeak.pollIntervalSeconds == 5)
        #expect(decoded.offPeak.keepaliveSeconds == 3)
        // The load→save cycle adds nothing to an untouched install.
        let resaved = try JSONEncoder.prettyForTests.encode(decoded)
        #expect(resaved == legacyData)

        // A real edit persists and round-trips.
        var edited = decoded
        edited.offPeak.enabled = true
        edited.offPeak.pollIntervalSeconds = 10
        let editedData = try JSONEncoder.prettyForTests.encode(edited)
        let redocoded = try JSONDecoder().decode(AppConfig.self, from: editedData)
        #expect(redocoded.offPeak.enabled == true)
        #expect(redocoded.offPeak.pollIntervalSeconds == 10)
        #expect(redocoded.offPeak.keepAliveSecondsRoundTrips)

        // Partial hand-edit keeps its keys (tolerant per-key decode).
        var partial = try JSONSerialization.jsonObject(with: legacyData) as! [String: Any]
        partial["offPeak"] = ["enabled": true]
        let partialData = try JSONSerialization.data(withJSONObject: partial)
        let partiallyDecoded = try JSONDecoder().decode(AppConfig.self, from: partialData)
        #expect(partiallyDecoded.offPeak.enabled == true)
        #expect(partiallyDecoded.offPeak.origin == "https://zcode.z.ai")

        // Fresh defaults ship disabled.
        #expect(AppConfig.makeDefault().offPeak.enabled == false)
    }
}

private extension OffPeakConfig {
    /// Test-only convenience: the field name is `keepaliveSeconds`.
    var keepAliveSecondsRoundTrips: Bool { keepaliveSeconds == 3 }
}

private extension JSONEncoder {
    nonisolated(unsafe) static let prettyForTests: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

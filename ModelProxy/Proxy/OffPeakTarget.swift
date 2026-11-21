import AsyncHTTPClient
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOHTTP1
import OSLog

/// The opt-in, default-OFF async relay surface (relay fidelity Task 10):
/// a local `/async/` route family a batch harness points at
/// (`ANTHROPIC_BASE_URL=http://localhost:<port>/async`) to run generation
/// through ZCode's Off-Peak / Idle Plan ticket queue.
///
/// One request walks this orchestration:
///
///     pre-flight → availability wait → take → poll (SSE keepalives
///     flowing) → unsigned data-plane POST with X-Off-Peak-Ticket-ID →
///     untouched SSE relay → settle
///
/// with the state machine WAIT→READY→DONE/EXPIRED/ABORT.
///
/// Wire discipline:
/// - Default-OFF: `offPeak.enabled == false` (or an unknown `/async/`
///   path) answers a standard Anthropic-shaped 404-style error locally —
///   ZERO contact with anything upstream.
/// - Pre-flight rejects (oversized > 4 MiB, unparseable JSON,
///   `stream != true` → `async_stream_required`) happen BEFORE any
///   ticket-server call — a malformed request never leaks a ticket.
/// - The data plane `POST {origin}/api/v1/off-peak/anthropic/v1/messages`
///   is UNSIGNED (never V4-signed): the Task 2/9 CLI identity set +
///   `Authorization: Bearer <zcode plan JWT>` + `X-Coding-Plan-Api-Key` +
///   `X-Off-Peak-Ticket-ID`, plus the `anthropic-version`/`anthropic-beta`
///   messages headers the control plane's face leaves to this plane.
/// - Downstream is a single SSE response: `": keepalive"` comments flow
///   every `keepaliveSeconds` while queued/waiting and STOP the moment the
///   data-plane stream starts — the keepalive child is cancelled AND
///   joined before the first body byte is written, so a keepalive can
///   never land inside an SSE frame. Data-plane chunks are relayed
///   byte-untouched (usage still extracted, ResponseRelay's accounting).
/// - Long-wait tolerance: the data-plane read timeout is
///   `maxWaitMinutes + 30 min` (NOT the 300 s relay default); downstream
///   heartbeats keep idle TCP alive while queued.
/// - Settle fires on completion, error, and client disconnect
///   (fire-and-forget — it never blocks the response).
enum OffPeakTarget {

    // MARK: - Routes and wire constants

    /// Route-family prefix intercepted in the channel-handler glue.
    static let routePrefix = "/async/"
    /// The Anthropic-passthrough messages route.
    static let messagesPath = "/async/v1/messages"
    /// The local health probe: `{"enabled": …}`, never contacts anything.
    static let healthPath = "/async/v1/health"
    /// The unsigned data-plane messages path (appended to the origin).
    static let dataPlanePath = "/api/v1/off-peak/anthropic/v1/messages"
    /// Pre-flight body bound.
    static let maxBodyBytes = 4 * 1024 * 1024
    /// The exact downstream heartbeat bytes (an SSE comment).
    static let keepaliveEvent = ": keepalive\n\n"
    /// Consecutive control-plane failures tolerated before aborting.
    static let maxConsecutiveControlFailures = 3
    /// Backoff between tolerated control-plane failures:
    /// `min(pollIntervalSeconds, 2 s)`.
    static let controlFailureBackoffCapSeconds: TimeInterval = 2
    /// The data-plane read-timeout headroom over the max wait.
    static let dataPlaneHeadroomSeconds: TimeInterval = 30 * 60

    static func isAsyncRoute(_ uri: String) -> Bool {
        uri.hasPrefix(routePrefix)
    }

    /// The async data plane's upstream read timeout: `maxWaitMinutes + 30
    /// min` — a queued off-peak answer may legitimately take that long to
    /// reach its first byte.
    static func dataPlaneReadTimeoutSeconds(for config: OffPeakConfig) -> Int64 {
        Int64(TimeInterval(max(1, config.maxWaitMinutes)) * 60 + dataPlaneHeadroomSeconds)
    }

    /// The unsigned data-plane request. The identity face is the Task 2/9
    /// CLI set (auth pair right after `authorization`); the messages
    /// headers and the ticket id are this plane's own additions. NEVER the
    /// V4 signing quartet, `x-app-id`, or `x-api-key`.
    static func dataPlaneRequest(
        config: OffPeakConfig,
        ticketID: String,
        wireBody: Data,
        authorization: String,
        codingPlanKey: String,
        clientVersion: String,
        sessionID: String
    ) throws -> HTTPClientRequest {
        let origin = config.origin.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard URL(string: origin + dataPlanePath) != nil else {
            throw Terminal.dataPlaneFailed(
                "off-peak origin does not form a URL: \(config.origin)")
        }
        var request = HTTPClientRequest(url: origin + dataPlanePath)
        request.method = .POST
        request.headers = OffPeakTicketClient.requestHeaders(
            authorization: authorization,
            codingPlanKey: codingPlanKey,
            clientVersion: clientVersion,
            sessionID: sessionID,
            jsonBody: true)
        request.headers.add(name: "anthropic-version", value: RelayTarget.anthropicVersion)
        if !RelayTarget.anthropicBeta.isEmpty {
            request.headers.add(name: "anthropic-beta", value: RelayTarget.anthropicBeta)
        }
        request.headers.add(name: "x-off-peak-ticket-id", value: ticketID)
        request.body = .bytes(ByteBuffer(data: wireBody))
        return request
    }

    // MARK: - Per-process context (built by ProxyServer)

    /// Per-process wiring handed to every channel handler, like the relay
    /// signing context: the shared server HTTP client (data plane), the
    /// credential providers, and the live off-peak config (hot-reloadable
    /// through `updateConfiguration`). No network happens at init.
    final class Context: @unchecked Sendable {
        private let lock = NSLock()
        private var configValue: OffPeakConfig
        let httpClient: HTTPClient
        let jwtProvider: @Sendable () async -> String?
        let credentialProvider: @Sendable () async -> String?
        let clientVersionProvider: @Sendable () -> String
        /// Data-plane execute over the shared server client; the long read
        /// timeout rides each call.
        let dataPlaneExecute: @Sendable (
            _ request: HTTPClientRequest, _ timeoutSeconds: Int64
        ) async throws -> HTTPClientResponse

        init(
            config: OffPeakConfig,
            httpClient: HTTPClient,
            jwtProvider: @escaping @Sendable () async -> String?,
            credentialProvider: @escaping @Sendable () async -> String?,
            clientVersionProvider: @escaping @Sendable () -> String = {
                RelayTarget.clientVersion
            }
        ) {
            self.configValue = config
            self.httpClient = httpClient
            self.jwtProvider = jwtProvider
            self.credentialProvider = credentialProvider
            self.clientVersionProvider = clientVersionProvider
            let client = httpClient
            self.dataPlaneExecute = { request, timeoutSeconds in
                try await client.execute(request, timeout: .seconds(timeoutSeconds))
            }
        }

        func configuration() -> OffPeakConfig {
            lock.lock(); defer { lock.unlock() }
            return configValue
        }

        /// Hot-reload hook (ProxyServer.updateRouting).
        func updateConfiguration(_ config: OffPeakConfig) {
            lock.lock(); defer { lock.unlock() }
            configValue = config
        }

        /// A ticket client for one request: fresh per request so the
        /// current origin is always in effect; same auth providers and
        /// impersonated CLI version as the data plane.
        func makeTicketClient() -> OffPeakTicketClient {
            OffPeakTicketClient(
                origin: configuration().origin,
                jwtProvider: jwtProvider,
                credentialProvider: credentialProvider,
                clientVersion: clientVersionProvider())
        }
    }

    // MARK: - State machine

    enum State: Equatable, Sendable {
        case wait
        case ready(ticketID: String)
        case done
        case expired
        case aborted(AbortReason)
    }

    enum AbortReason: Equatable, Sendable {
        case maxWaitExceeded
        case controlFailuresExceeded
        case clientDisconnected
        case dataPlaneFailed
        case cancelled
    }

    /// Internal terminal condition — always surfaced to the client (except
    /// client-gone) and always followed by a settle of the held ticket.
    private enum Terminal: Error {
        case maxWaitExceeded
        case controlFailuresExceeded(count: Int)
        case ticketExpired
        case clientDisconnected
        case dataPlaneFailed(String)
    }

    /// A transient control-plane anomaly that is not a typed transport
    /// error — e.g. the ticket absent from a `code:0` status batch (Task 9
    /// carry note: "all tickets vanished" parses as empty and is treated
    /// as suspicious/transient here, NEVER as terminal expiry).
    private struct ControlTransient: Error {
        let reason: String
    }

    // MARK: - Dependencies (everything injected — tests drive the clock)

    struct Dependencies: Sendable {
        let config: OffPeakConfig
        let ticketClient: OffPeakTicketClient
        /// The pre-flight-canonicalized request body (model already mapped
        /// through `RelayTarget.canonicalModel`).
        let wireBody: Data
        let requestID: String
        let now: @Sendable () -> Date
        let sleep: @Sendable (TimeInterval) async throws -> Void
        let sink: KeepaliveBridge
        let dataPlaneExecute: @Sendable (
            _ request: HTTPClientRequest, _ timeoutSeconds: Int64
        ) async throws -> HTTPClientResponse
        /// Fire-and-forget settle hook (never blocks the response).
        let settle: @Sendable (String) -> Void
        let onUsage: ResponseRelay.UsageCallback?
        let onTransition: (@Sendable (State) -> Void)?
    }

    /// Production clock: wall time + real sleeps.
    static let defaultNow: @Sendable () -> Date = { Date() }
    static let defaultSleep: @Sendable (TimeInterval) async throws -> Void = { delay in
        try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
    }

    // MARK: - Downstream keepalive bridge

    /// The downstream writer for the async surface. Single-writer
    /// contract: only the orchestrator task writes at any moment (the
    /// data-plane bridge's keepalive child is cancelled AND joined before
    /// the first body byte), so a keepalive can never interleave with an
    /// SSE frame. The 200 `text/event-stream` head opens LAZILY on the
    /// first write — a fast failure before the first keepalive therefore
    /// still gets a real HTTP error response, not a 200 stream.
    final class KeepaliveBridge: @unchecked Sendable {
        private let channel: any Channel
        private let requestID: String
        private let lock = NSLock()
        private var headSent = false
        private var closed = false
        private var firstChunkAtValue: Date?

        init(channel: any Channel, requestID: String) {
            self.channel = channel
            self.requestID = requestID
        }

        var responseHeadSent: Bool {
            lock.lock(); defer { lock.unlock() }
            return headSent
        }

        private func ensureHead() async throws {
            let shouldSend: Bool = lock.withLock {
                if headSent || closed { return false }
                headSent = true
                return true
            }
            guard shouldSend else { return }
            var head = HTTPResponseHead(version: .http1_1, status: .ok)
            head.headers.add(name: "content-type", value: "text/event-stream")
            head.headers.add(name: "connection", value: "close")
            try await channel.writeAndFlush(NIOAny(HTTPServerResponsePart.head(head))).get()
        }

        /// One SSE-comment heartbeat. Throws on a failed downstream write —
        /// the orchestrator reads that as the client disconnecting.
        func writeKeepalive() async throws {
            try await ensureHead()
            var buffer = channel.allocator.buffer(capacity: OffPeakTarget.keepaliveEvent.utf8.count)
            buffer.writeString(OffPeakTarget.keepaliveEvent)
            try await channel.writeAndFlush(
                NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer)))
            ).get()
        }

        /// One untouched data-plane body chunk. Throws on a failed
        /// downstream write (client disconnect).
        func writeChunk(_ chunk: ByteBuffer) async throws {
            guard chunk.readableBytes > 0 else { return }
            lock.withLock {
                if firstChunkAtValue == nil { firstChunkAtValue = Date.now }
            }
            try await ensureHead()
            try await channel.writeAndFlush(
                NIOAny(HTTPServerResponsePart.body(.byteBuffer(chunk)))
            ).get()
        }

        /// Time of the first DATA chunk written downstream (keepalives
        /// excluded) — the surface's TTFT, read after orchestration.
        var firstChunkAt: Date? {
            lock.lock(); defer { lock.unlock() }
            return firstChunkAtValue
        }

        /// Terminal failure, dual-mode: before the head it is a real
        /// Anthropic-shaped HTTP error (status honored); after the head the
        /// 200 status line is already out, so it rides as ONE terminal SSE
        /// error event before the stream end (the LocalTarget cut pattern).
        func fail(status: HTTPResponseStatus, anthropicType: String, message: String) async {
            let alreadySent: Bool = lock.withLock {
                let sent = headSent || closed
                headSent = true
                closed = true
                return sent
            }
            if !alreadySent {
                await ProxyForwarder.sendAnthropicError(
                    channel: channel, status: status, type: anthropicType, message: message)
                return
            }
            let body: [String: Any] = [
                "type": "error",
                "error": ["type": anthropicType, "message": message],
            ]
            let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
                ?? Data()
            let event = "event: error\ndata: \(String(data: data, encoding: .utf8) ?? "{}")\n\n"
            do {
                var buffer = channel.allocator.buffer(capacity: event.utf8.count)
                buffer.writeString(event)
                try await channel.writeAndFlush(
                    NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer)))
                ).get()
                try await channel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).get()
            } catch {
                AppLog.proxy.warning(
                    "[OffPeak] [\(requestID)] terminal error-event write failed (client may be gone): \(error)"
                )
            }
            try? await channel.close().get()
        }

        /// Success close: end + close. Opens an empty head if nothing was
        /// ever written so the client always receives a well-formed
        /// response.
        func finish() async {
            do { try await ensureHead() } catch { /* client gone; end write below is best-effort */ }
            _ = try? await channel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).get()
            try? await channel.close().get()
            lock.withLock { closed = true }
        }
    }

    // MARK: - Orchestration (the WAIT→READY→DONE/EXPIRED/ABORT machine)

    /// Runs the full ticket orchestration for one accepted request.
    /// Returns the terminal state; settle has fired for any held ticket on
    /// every exit path. The downstream sink always received a complete
    /// response (streamed frames, or an Anthropic-shaped error) unless the
    /// client disconnected.
    static func orchestrate(_ deps: Dependencies) async -> State {
        let config = deps.config
        let deadline = deps.now().addingTimeInterval(
            TimeInterval(max(1, config.maxWaitMinutes)) * 60)
        let taskID = "zgate-" + UUID().uuidString

        var state: State = .wait
        deps.onTransition?(state)

        var heldTicket: OffPeakTicket?
        var retakeUsed = false
        var consecutiveFailures = 0
        var lastKeepaliveAt = deps.now()
        var serverPollHint: Int?

        /// Fire-and-forget settle of whatever ticket we hold; idempotent.
        /// The defer below guarantees it on EVERY exit (completion, error,
        /// client disconnect, cancellation).
        func settleHeld() {
            guard let ticketID = heldTicket?.ticketID else { return }
            heldTicket = nil
            deps.settle(ticketID)
        }
        defer { settleHeld() }

        do {
            // WAIT phase: availability gate → take → poll until usable.
            acquireLoop: while true {
                try Task.checkCancellation()
                if deps.now() >= deadline { throw Terminal.maxWaitExceeded }

                guard let ticket = heldTicket else {
                    // Availability gate. False → wait to next_take_at
                    // (keepalives flowing), then re-check.
                    let availability = try await withControlRetry(
                        deps: deps, deadline: deadline,
                        consecutiveFailures: &consecutiveFailures,
                        lastKeepaliveAt: &lastKeepaliveAt
                    ) {
                        try await deps.ticketClient.availability()
                    }
                    if !availability.canTake {
                        let next = availability.nextTakeAtSeconds
                            .map { Date(timeIntervalSince1970: TimeInterval($0)) }
                            ?? deps.now().addingTimeInterval(
                                TimeInterval(max(1, config.pollIntervalSeconds)))
                        // Floored at 1 s: a stale/past next_take_at must not
                        // hot-loop the gate. Bounded by the deadline.
                        let target = min(
                            deadline, max(next, deps.now().addingTimeInterval(1)))
                        try await waitWithKeepalives(
                            until: target, deps: deps, deadline: deadline,
                            lastKeepaliveAt: &lastKeepaliveAt)
                        continue acquireLoop
                    }
                    let ticket = try await withControlRetry(
                        deps: deps, deadline: deadline,
                        consecutiveFailures: &consecutiveFailures,
                        lastKeepaliveAt: &lastKeepaliveAt
                    ) {
                        try await deps.ticketClient.takeTicket(taskID: taskID)
                    }
                    heldTicket = ticket
                    serverPollHint = ticket.nextPollAfterSeconds
                    if ticket.state == .ready || ticket.state == .active {
                        break acquireLoop
                    }
                    // queued: one effective interval before the first status
                    // poll, honoring the take's hint. A dead-on-arrival
                    // ticket (expired/not_found) skips the idle and reacts
                    // on the next iteration immediately.
                    if ticket.state == .queued {
                        try await waitWithKeepalives(
                            until: min(
                                deps.now().addingTimeInterval(
                                    effectivePollInterval(config: config, hint: serverPollHint)),
                                deadline),
                            deps: deps, deadline: deadline, lastKeepaliveAt: &lastKeepaliveAt)
                    }
                    continue acquireLoop
                }

                switch ticket.state {
                case .ready, .active:
                    break acquireLoop
                case .expired, .notFound, .settled:
                    // Exactly one re-take within the max-wait window; a
                    // second death is terminal (529-shaped). The server
                    // already reaped the dead ticket — no settle for it.
                    guard !retakeUsed else { throw Terminal.ticketExpired }
                    retakeUsed = true
                    AppLog.proxy.info(
                        "[OffPeak] [\(deps.requestID)] ticket \(ticket.ticketID) \(ticket.state.rawValue) mid-wait — re-taking once"
                    )
                    heldTicket = nil
                    serverPollHint = nil
                    continue acquireLoop
                case .queued:
                    var batchHint: Int?
                    let row = try await withControlRetry(
                        deps: deps, deadline: deadline,
                        consecutiveFailures: &consecutiveFailures,
                        lastKeepaliveAt: &lastKeepaliveAt
                    ) { () -> OffPeakTicket in
                        let (rows, hint) = try await deps.ticketClient.status(
                            ticketIDs: [ticket.ticketID])
                        batchHint = hint
                        guard let row = rows.first(where: { $0.ticketID == ticket.ticketID })
                        else {
                            throw ControlTransient(reason: "ticket absent from status batch")
                        }
                        return row
                    }
                    heldTicket = row
                    serverPollHint = batchHint ?? row.nextPollAfterSeconds
                    // Only a still-queued row idles one effective interval —
                    // a poll that reveals ready/active breaks on the next
                    // iteration immediately (no idle before the data plane)
                    // and a dead row (expired/not_found) reacts at once.
                    if row.state == .queued {
                        try await waitWithKeepalives(
                            until: min(
                                deps.now().addingTimeInterval(
                                    effectivePollInterval(config: config, hint: serverPollHint)),
                                deadline),
                            deps: deps, deadline: deadline, lastKeepaliveAt: &lastKeepaliveAt)
                    }
                    continue acquireLoop
                }
            }

            // READY phase: the unsigned data-plane call, keepalives
            // bridging until its head arrives.
            guard let ticket = heldTicket else {
                throw Terminal.dataPlaneFailed("internal: no ticket at data-plane phase")
            }
            state = .ready(ticketID: ticket.ticketID)
            deps.onTransition?(state)
            AppLog.proxy.info(
                "[OffPeak] [\(deps.requestID)] ticket \(ticket.ticketID) ready — data plane"
            )

            guard let authorization = await deps.ticketClient.jwtProvider(), !authorization.isEmpty,
                let codingPlanKey = await deps.ticketClient.credentialProvider(),
                !codingPlanKey.isEmpty
            else {
                throw Terminal.dataPlaneFailed("off-peak credentials unavailable")
            }
            let request = try dataPlaneRequest(
                config: config,
                ticketID: ticket.ticketID,
                wireBody: deps.wireBody,
                authorization: authorization,
                codingPlanKey: codingPlanKey,
                clientVersion: deps.ticketClient.clientVersion,
                sessionID: deps.ticketClient.sessionID)
            let timeoutSeconds = dataPlaneReadTimeoutSeconds(for: config)

            // The bridge: a keepalive child heartbeats downstream while a
            // head child performs the data-plane exchange. Whichever
            // finishes first wins; on head arrival the keepalive child is
            // cancelled AND joined (the group scope awaits it) BEFORE any
            // body byte is written — keepalives stop the moment the stream
            // starts and can never interleave with an SSE frame.
            let response: HTTPClientResponse
            do {
                response = try await withThrowingTaskGroup(
                    of: HTTPClientResponse?.self
                ) { group in
                    let kaInterval = TimeInterval(max(1, config.keepaliveSeconds))
                    group.addTask {
                        while true {
                            do {
                                try Task.checkCancellation()
                                try await deps.sleep(kaInterval)
                            } catch { return nil }  // cancelled: head arrived / ending
                            do { try Task.checkCancellation() } catch { return nil }
                            do { try await deps.sink.writeKeepalive() } catch {
                                throw Terminal.clientDisconnected
                            }
                        }
                    }
                    group.addTask {
                        try await deps.dataPlaneExecute(request, timeoutSeconds)
                    }
                    // `next()` returns HTTPClientResponse?? — flatten the
                    // group-result optional, then the child's own nil.
                    guard let headResponse = (try await group.next()) ?? nil else {
                        throw CancellationError()
                    }
                    group.cancelAll()
                    return headResponse
                }
            } catch let terminal as Terminal {
                throw terminal
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw Terminal.dataPlaneFailed(String(describing: error))
            }

            // DONE phase: relay the data-plane body untouched.
            let upstreamStatus = Int(response.status.code)
            if (200..<300).contains(upstreamStatus) {
                let contentType = response.headers.first(name: "content-type") ?? ""
                let isSSE = contentType.lowercased().contains("text/event-stream")
                var accumulatedInput = 0
                var accumulatedOutput = 0
                var accumulatedCacheRead = 0
                var jsonAccumulator = Data()
                do {
                    for try await chunk in response.body {
                        if deps.onUsage != nil {
                            if isSSE {
                                let (input, output, cacheRead) =
                                    ResponseRelay.extractUsageFromSSEChunk(chunk)
                                accumulatedInput += input
                                accumulatedOutput += output
                                accumulatedCacheRead += cacheRead
                            } else if let bytes = chunk.getData(
                                at: chunk.readerIndex, length: chunk.readableBytes)
                            {
                                jsonAccumulator.append(bytes)
                            }
                        }
                        do { try await deps.sink.writeChunk(chunk) } catch {
                            throw Terminal.clientDisconnected
                        }
                    }
                    try await deps.sink.finish()
                } catch let terminal as Terminal {
                    throw terminal
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw Terminal.dataPlaneFailed(
                        "stream ended unexpectedly: \(String(describing: error))")
                }
                if let onUsage = deps.onUsage {
                    if accumulatedInput > 0 || accumulatedOutput > 0 {
                        onUsage(accumulatedInput, accumulatedOutput, accumulatedCacheRead)
                    } else if !jsonAccumulator.isEmpty,
                        let (input, output, cacheRead) =
                            ResponseRelay.extractUsageFromJSONBody(jsonAccumulator)
                    {
                        onUsage(input, output, cacheRead)
                    }
                }
                state = .done
                deps.onTransition?(state)
                return state
            }

            // Non-2xx: bounded drain, parsed Anthropic-style error, settled
            // — a complete answer, so the state machine lands on DONE.
            let drained = await Self.drainCapped(response, cap: 8192)
            let parsed = RelayUpstreamError.parse(status: upstreamStatus, body: drained)
            let anthropicType = Self.embeddedAnthropicType(in: drained) ?? "api_error"
            await deps.sink.fail(
                status: HTTPResponseStatus(statusCode: upstreamStatus),
                anthropicType: anthropicType,
                message: parsed?.displayReason
                    ?? "off-peak data plane answered HTTP \(upstreamStatus)")
            state = .done
            deps.onTransition?(state)
            return state
        } catch let terminal as Terminal {
            settleHeld()
            switch terminal {
            case .ticketExpired:
                state = .expired
                deps.onTransition?(state)
                await deps.sink.fail(
                    status: HTTPResponseStatus(statusCode: 529),
                    anthropicType: "overloaded_error",
                    message:
                        "off-peak ticket expired and the single re-take did not yield a usable ticket"
                )
            case .maxWaitExceeded:
                state = .aborted(.maxWaitExceeded)
                deps.onTransition?(state)
                await deps.sink.fail(
                    status: HTTPResponseStatus(statusCode: 529),
                    anthropicType: "overloaded_error",
                    message:
                        "off-peak queue did not open within the max-wait window (\(max(1, config.maxWaitMinutes)) min)"
                )
            case .controlFailuresExceeded(let count):
                state = .aborted(.controlFailuresExceeded)
                deps.onTransition?(state)
                await deps.sink.fail(
                    status: HTTPResponseStatus(statusCode: 529),
                    anthropicType: "overloaded_error",
                    message: "off-peak ticket control plane failed \(count) consecutive times"
                )
            case .clientDisconnected:
                state = .aborted(.clientDisconnected)
                deps.onTransition?(state)
                // The client is gone — no downstream write.
            case .dataPlaneFailed(let reason):
                state = .aborted(.dataPlaneFailed)
                deps.onTransition?(state)
                await deps.sink.fail(
                    status: .badGateway,
                    anthropicType: "api_error",
                    message: "off-peak data plane failed: \(reason)"
                )
            }
            return state
        } catch is CancellationError {
            settleHeld()
            state = .aborted(.cancelled)
            deps.onTransition?(state)
            return state
        } catch {
            settleHeld()
            state = .aborted(.dataPlaneFailed)
            deps.onTransition?(state)
            await deps.sink.fail(
                status: .badGateway,
                anthropicType: "api_error",
                message: "off-peak orchestration failed: \(String(describing: error))")
            return state
        }
    }

    // MARK: - Route face (the channel-handler entry)

    /// Handles one `/async/` request. Returns the orchestrator's terminal
    /// state, or nil when answered purely locally (health, disabled /
    /// unknown route, pre-flight rejection) — in every nil case NOTHING
    /// upstream was contacted.
    static func handle(
        head: HTTPRequestHead,
        body: ByteBuffer,
        channel: any Channel,
        context: Context?,
        trafficLog: TrafficLog? = nil,
        tokenStatsStore: TokenStatsStore? = nil,
        requestID: String
    ) async -> State? {
        let config = context?.configuration() ?? OffPeakConfig()

        // Health: always answered locally, reports the toggle as-is.
        if head.method == .GET && head.uri == healthPath {
            let payload: [String: Any] = ["enabled": config.enabled]
            let data = (try? JSONSerialization.data(
                withJSONObject: payload, options: [.sortedKeys])) ?? Data()
            await ProxyForwarder.sendResponse(
                channel: channel, status: .ok, contentType: "application/json", body: data)
            return nil
        }

        // Default-OFF + unknown path: standard Anthropic-shaped 404-style
        // error, no upstream contact of any kind.
        guard config.enabled, head.method == .POST, head.uri == messagesPath else {
            AppLog.proxy.info(
                "[OffPeak] [\(requestID)] \(head.method.rawValue) \(head.uri) rejected (enabled=\(config.enabled))"
            )
            await ProxyForwarder.sendAnthropicError(
                channel: channel,
                status: .notFound,
                type: "not_found_error",
                message: config.enabled
                    ? "Unknown off-peak async route. Use POST \(messagesPath)."
                    : "The off-peak async surface is disabled (offPeak.enabled = false).")
            return nil
        }

        // No context = surface disabled, same local 404 shape (a nil
        // context already failed the enabled gate above — kept so the
        // delegate never has to re-check).
        guard let context else {
            await ProxyForwarder.sendAnthropicError(
                channel: channel, status: .notFound, type: "not_found_error",
                message: "The off-peak async surface is disabled.")
            return nil
        }

        return await serve(
            head: head,
            body: body,
            channel: channel,
            context: context,
            targetModel: nil,
            trafficLog: trafficLog,
            tokenStatsStore: tokenStatsStore,
            vendorID: nil,
            requestID: requestID)
    }

    /// The shared POST core (off-peak wave 2, Task 3): pre-flight, model
    /// canonicalization, orchestration, cancellation bridge, traffic row —
    /// split out of `handle` so the forwarder's routed off-peak path (Task 4)
    /// can serve with a rule's target model and a vendor for stats. The
    /// `/async` face calls this with `targetModel` nil (wire behavior
    /// byte-identical to the pre-split `handle`) and `vendorID` nil — a
    /// vendorless serve records token stats exactly like the passthrough
    /// path: not at all.
    static func serve(
        head: HTTPRequestHead,
        body: ByteBuffer,
        channel: any Channel,
        context: Context,
        targetModel: String?,
        trafficLog: TrafficLog?,
        tokenStatsStore: TokenStatsStore?,
        vendorID: UUID?,
        requestID: String
    ) async -> State? {
        let startedAt = Date.now
        let config = context.configuration()

        // Pre-flight — before ANY ticket-server call (a malformed request
        // must never leak a ticket).
        let bodyData = body.getData(at: body.readerIndex, length: body.readableBytes) ?? Data()
        guard bodyData.count <= maxBodyBytes else {
            await ProxyForwarder.sendAnthropicError(
                channel: channel, status: .payloadTooLarge, type: "request_too_large",
                message: "Off-peak request body exceeds \(maxBodyBytes / (1024 * 1024)) MiB.")
            return nil
        }
        guard let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any]
        else {
            await ProxyForwarder.sendAnthropicError(
                channel: channel, status: .badRequest, type: "invalid_request_error",
                message: "Off-peak request body must be a JSON object.")
            return nil
        }
        guard json["stream"] as? Bool == true else {
            await ProxyForwarder.sendAnthropicError(
                channel: channel, status: .badRequest, type: "async_stream_required",
                message: "The off-peak async surface requires \"stream\": true.")
            return nil
        }
        // Model canonicalization (Task 5 helpers): byte-preserving
        // top-level splice; everything else stays byte-unchanged. A routed
        // serve (Task 4) overrides the request's model with its rule
        // target; the /async face passes nil and uses the request's own.
        var wireBody = bodyData
        var model = "unknown"
        var rawModel: String?
        if let raw = json["model"] as? String, !raw.isEmpty {
            rawModel = raw
            let effective = targetModel ?? raw
            let canonical = RelayTarget.canonicalModel(effective)
            wireBody = ProxyForwarder.replaceModelField(in: bodyData, with: canonical).data
            model = canonical
        }

        let ticketClient = context.makeTicketClient()
        let settleClient = ticketClient
        // Output tokens for the traffic row + token stats (forward()'s
        // capture pattern — the usage callback fires during orchestration,
        // read after it). Stats keying mirrors the forwarder exactly
        // (ProxyForwarder's onUsage): the serving vendor, the canonical
        // model, the RAW request model as source — and a vendorless serve
        // records nothing, same as the passthrough path.
        let statsModel = model
        let sourceModelForStats = rawModel
        nonisolated(unsafe) var capturedOutputTokens: Int?
        nonisolated(unsafe) var capturedInputTokens: Int?
        let onUsage: ResponseRelay.UsageCallback = { [tokenStatsStore] input, output, cacheRead in
            capturedOutputTokens = output
            capturedInputTokens = input
            if let tokenStatsStore, let vendorID {
                Task { @MainActor in
                    tokenStatsStore.add(
                        vendorID: vendorID, model: statsModel, input: input, output: output,
                        cacheRead: cacheRead, sourceModel: sourceModelForStats)
                }
            }
        }
        let sink = KeepaliveBridge(channel: channel, requestID: requestID)
        let deps = Dependencies(
            config: config,
            ticketClient: ticketClient,
            wireBody: wireBody,
            requestID: requestID,
            now: defaultNow,
            sleep: defaultSleep,
            sink: sink,
            dataPlaneExecute: context.dataPlaneExecute,
            settle: { ticketID in
                Task { await settleClient.settle(ticketID: ticketID) }
            },
            onUsage: onUsage,
            onTransition: { state in
                AppLog.proxy.info("[OffPeak] [\(requestID)] state → \(state)")
            })
        AppLog.proxy.info(
            "[OffPeak] [\(requestID)] POST \(head.uri) model=\(model) body=\(bodyData.count)B accepted"
        )

        // Client disconnect mid-orchestration cancels it (forward()'s
        // relayStreamTask pattern): sleeps/HTTP throw CancellationError,
        // the settle defer fires, the state lands on .aborted(.cancelled).
        let orchestration = Task { await orchestrate(deps) }
        channel.closeFuture.whenComplete { _ in orchestration.cancel() }
        let finalState = await orchestration.value

        if let trafficLog {
            let entry = TrafficEntry(
                model: model,
                routeType: .offPeak(targetModel: model),
                requestKind: .generation,
                httpStatus: clientVisibleStatus(finalState),
                duration: Date.now.timeIntervalSince(startedAt),
                ttft: sink.firstChunkAt.map { $0.timeIntervalSince(startedAt) },
                outputTokens: capturedOutputTokens,
                inputTokens: capturedInputTokens)
            let requestClass = ProxyForwarder.claudeCodeRequestClass(from: head.headers)
            await MainActor.run { trafficLog.append(entry.with(requestClass: requestClass)) }
        }
        return finalState
    }

    /// The status the client effectively saw, for the traffic row.
    private static func clientVisibleStatus(_ state: State) -> Int {
        switch state {
        case .done: return 200
        case .expired, .aborted(.maxWaitExceeded), .aborted(.controlFailuresExceeded):
            return 529
        case .aborted(.dataPlaneFailed): return 502
        case .aborted(.clientDisconnected), .aborted(.cancelled): return 499
        case .wait, .ready: return 0
        }
    }

    // MARK: - Wait helpers

    /// `pollIntervalSeconds` or the server's `next_poll_after`, whichever
    /// is LARGER (server wins when bigger). Hand-edited zeros are clamped
    /// to 1 s so the loop can never spin.
    private static func effectivePollInterval(config: OffPeakConfig, hint: Int?) -> TimeInterval {
        let floor = TimeInterval(max(1, config.pollIntervalSeconds))
        guard let hint, hint > 0 else { return floor }
        return max(floor, TimeInterval(hint))
    }

    /// Sleeps until `target`, emitting `": keepalive"` downstream every
    /// `keepaliveSeconds` along the way. A failed keepalive write throws
    /// `Terminal.clientDisconnected`; cancellation propagates.
    private static func waitWithKeepalives(
        until target: Date,
        deps: Dependencies,
        deadline: Date,
        lastKeepaliveAt: inout Date
    ) async throws {
        let kaInterval = TimeInterval(max(1, deps.config.keepaliveSeconds))
        while deps.now() < target {
            let nextKeepalive = lastKeepaliveAt.addingTimeInterval(kaInterval)
            let wake = min(target, nextKeepalive)
            let delay = wake.timeIntervalSince(deps.now())
            if delay > 0 { try await deps.sleep(delay) }
            try Task.checkCancellation()
            let now = deps.now()
            if now >= target { break }
            if now >= nextKeepalive {
                do { try await deps.sink.writeKeepalive() } catch {
                    throw Terminal.clientDisconnected
                }
                lastKeepaliveAt = now
            }
        }
    }

    /// A control-plane call with the 3-failure tolerance: transient errors
    /// (transport, envelope, vanished rows) back off
    /// `min(pollInterval, 2 s)` — keepalives flowing — and retry; the 4th
    /// consecutive failure is terminal.
    private static func withControlRetry<T>(
        deps: Dependencies,
        deadline: Date,
        consecutiveFailures: inout Int,
        lastKeepaliveAt: inout Date,
        _ body: () async throws -> T
    ) async throws -> T {
        while true {
            try Task.checkCancellation()
            if deps.now() >= deadline { throw Terminal.maxWaitExceeded }
            do {
                let value = try await body()
                consecutiveFailures = 0
                return value
            } catch let terminal as Terminal {
                throw terminal
            } catch let cancelled as CancellationError {
                throw cancelled
            } catch {
                consecutiveFailures += 1
                AppLog.proxy.warning(
                    "[OffPeak] [\(deps.requestID)] control-plane failure #\(consecutiveFailures): \(String(describing: error))"
                )
                if consecutiveFailures > maxConsecutiveControlFailures {
                    throw Terminal.controlFailuresExceeded(count: consecutiveFailures)
                }
                let backoff = min(
                    TimeInterval(max(1, deps.config.pollIntervalSeconds)),
                    controlFailureBackoffCapSeconds)
                try await waitWithKeepalives(
                    until: min(deps.now().addingTimeInterval(backoff), deadline),
                    deps: deps, deadline: deadline, lastKeepaliveAt: &lastKeepaliveAt)
            }
        }
    }

    // MARK: - Error-body helpers

    /// Bounded read of a response body (RelayTarget.readBodyCapped's
    /// pattern; the cap keeps a runaway error body from squatting memory).
    private static func drainCapped(_ response: HTTPClientResponse, cap: Int) async -> Data {
        var data = Data()
        do {
            for try await chunk in response.body {
                if let bytes = chunk.getData(at: chunk.readerIndex, length: chunk.readableBytes) {
                    data.append(bytes)
                }
                if data.count > cap { break }
            }
        } catch {
            // Body read failure on an error path: keep what we have.
        }
        return data
    }

    /// The Anthropic `error.type` embedded in a JSON error body, when the
    /// upstream was kind enough to send one.
    private static func embeddedAnthropicType(in data: Data) -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let error = json["error"] as? [String: Any],
            let type = error["type"] as? String, !type.isEmpty
        else { return nil }
        return type
    }
}

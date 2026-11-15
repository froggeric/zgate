import Foundation
import NIOCore
import NIOFoundationCompat
import NIOHTTP1
import NIOPosix
import AsyncHTTPClient
import OSLog

/// The Splash local inference engine as a forward target.
///
/// Splash (a local server, default `http://127.0.0.1:8000`) speaks the
/// Anthropic protocol natively, so its route is a pure passthrough: the
/// client's request goes out with its own headers minus credentials —
/// Splash is local trust, there is no key to present and none is added —
/// and a body whose only mutation is the top-level `model` splice to the
/// rule target's model (e.g. `mlx-community/Qwen3.8-27B-4bit`), performed
/// with the same byte-preserving primitive the relay path uses. No OpenAI
/// translation happens anywhere.
///
/// Thinking-block replay rides upstream model-proxy's transcript machinery
/// rather than a local reimplementation: `TranscriptProjector` keyed on the
/// target's `replayPolicy` already strips thinking-like blocks (and
/// `signature` fields) for `.portableOnly` targets that don't accept them —
/// the splash shape — while `.transparent` targets (the relay) receive the
/// body byte-unchanged. A `thinking` block signed by a non-splash model can
/// therefore never reach Splash through the projection path.
///
/// Health: `LocalHealthMonitor` (below) TCP-probes loopback vendors and
/// implements Task 6's `TargetHealthProviding` seam, so a down splash rules
/// out its rule and the router falls to the next one.
enum LocalTarget {

    // Splash identity (the user's local inference engine).
    static let defaultBaseURL = "http://127.0.0.1:8000"
    /// Splash's default model — the value a rule's `targetModel` names.
    static let defaultModel = "mlx-community/Qwen3.8-27B-4bit"

    private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "0.0.0.0"]

    /// True when a vendor baseURL points at this machine (Splash's shape).
    static func isLoopbackBaseURL(_ baseURL: String) -> Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return false }
        return loopbackHosts.contains(host)
    }

    /// True for the splash-shaped route target: loopback and not the signed
    /// relay (`vendorKind == .anthropic` per the routing spec).
    static func isLocalTarget(_ target: RoutingSnapshot.RouteTarget) -> Bool {
        target.vendorKind != .relay && isLoopbackBaseURL(target.baseURL)
    }

    // MARK: - Wire request

    /// Wire headers for the local route: the client's headers minus
    /// hop-by-hop fields, minus Claude Code gateway identifiers, and minus
    /// CC's `x-api-key`/`authorization` — nothing added in their place.
    /// Splash is local trust: stripping (not replacing) the credentials
    /// means no key material, not even an empty bearer, is ever sent.
    static func upstreamHeaders(from requestHeaders: HTTPHeaders) -> HTTPHeaders {
        var headers = HTTPHeaders()
        for (name, value) in requestHeaders {
            let lower = name.lowercased()
            if lower == "host" || lower == "connection" || lower == "transfer-encoding"
                || lower == "content-length" || lower == "accept-encoding" {
                continue
            }
            if lower == "authorization" || lower == "x-api-key" {
                continue
            }
            // Claude Code session/agent identifiers are meant for the local
            // gateway, not for vendors (mirrors ProxyForwarder's mapped path).
            if lower.hasPrefix("x-claude-code-") {
                continue
            }
            headers.add(name: name, value: value)
        }
        headers.add(name: "Accept-Encoding", value: "gzip, deflate")
        return headers
    }

    /// The wire body: only the top-level `model` value is replaced with the
    /// rule target's model, via the byte-preserving splice. No
    /// canonicalization — the rule target names the splash model verbatim.
    /// A target without `targetModel` forwards the body unchanged.
    static func wireBody(bodyData: Data, target: RoutingSnapshot.RouteTarget) -> Data {
        guard let targetModel = target.targetModel else { return bodyData }
        return ProxyForwarder.replaceModelField(in: bodyData, with: targetModel).data
    }

    // MARK: - Exchange

    /// Outcome of one local exchange.
    enum Outcome {
        /// A response (any status — the ladder decides what streams back).
        case responded(HTTPClientResponse)
        /// Transport-level failure before a status arrived.
        case transportFailed(String)
    }

    /// One splash exchange: credential-free headers, model-spliced body,
    /// passthrough of whatever status comes back. A 2xx exchange also notes
    /// the vendor healthy on the monitor (the relay's `noteRelaySuccess`
    /// pattern: wire successes keep the health entry warm between ticks).
    static func execute(
        head: HTTPRequestHead,
        bodyData: Data,
        target: RoutingSnapshot.RouteTarget,
        httpClient: HTTPClient,
        requestID: String,
        health: LocalHealthMonitor? = nil
    ) async -> Outcome {
        let urlString = target.baseURL.trimmingCharacters(in: .init(charactersIn: "/")) + head.uri
        guard URL(string: urlString) != nil else {
            return .transportFailed("unparseable upstream URL: \(urlString)")
        }
        var request = HTTPClientRequest(url: urlString)
        request.method = head.method
        request.headers = upstreamHeaders(from: head.headers)
        request.body = .bytes(wireBody(bodyData: bodyData, target: target))
        do {
            let response = try await httpClient.execute(
                request, timeout: .seconds(Int64(target.readTimeoutSeconds)))
            if Int(response.status.code) < 400 {
                health?.noteSuccess(vendorID: target.vendorID)
            }
            return .responded(response)
        } catch {
            AppLog.proxy.error(
                "[Proxy] [\(requestID)] Local target upstream error for \(target.vendorName): \(error)")
            return .transportFailed(String(describing: error))
        }
    }

    // MARK: - Fallback ladder

    /// Outcome of the local ladder across a rule's target array.
    enum FallbackOutcome {
        /// A streamable response and the target that produced it.
        case served(HTTPClientResponse, RoutingSnapshot.RouteTarget)
        /// The primary's own error response (rewrapped, bounded to the
        /// 8 KiB drain cap) — no backup succeeded or none was configured;
        /// the client sees the local server's real error.
        case primaryError(HTTPClientResponse, RoutingSnapshot.RouteTarget)
        /// No response at all: the primary was unreachable and every backup
        /// failed.
        case unreachable(String)
    }

    /// Executes the rule's targets (primary first — `router.targets(for:)`
    /// shape): the local exchange runs first; a splash 5xx or transport
    /// failure walks the backups, the same failover the router's 429 path
    /// uses. 2xx–4xx responses pass through without fallback (client errors
    /// are real errors, not availability signals). Relay-kind backups run
    /// their own signed ladder via `RelayTarget.execute`.
    static func executeWithFallback(
        head: HTTPRequestHead,
        bodyData: Data,
        targets: [RoutingSnapshot.RouteTarget],
        httpClient: HTTPClient,
        requestID: String,
        health: LocalHealthMonitor? = nil,
        relayContext: RelayTarget.Context? = nil
    ) async -> FallbackOutcome {
        guard let primary = targets.first else {
            return .unreachable("no routing targets")
        }

        let primaryOutcome = await execute(
            head: head, bodyData: bodyData, target: primary,
            httpClient: httpClient, requestID: requestID, health: health)

        var primaryErrorResponse: HTTPClientResponse?
        var unreachableReason = "local target unreachable"
        switch primaryOutcome {
        case .responded(let response):
            if Int(response.status.code) < 500 {
                return .served(response, primary)
            }
            // 5xx: bounded-drain the error body (8 KiB cap, RelayTarget's
            // primitive) so the connection is reclaimed, then walk backups.
            // The drain yields a re-wrapped response carrying the same bytes —
            // an AsyncHTTPClient body admits a single iterator, so the
            // rewrap (not the drained original) is what may stream later.
            let (_, rewrapped) = await RelayTarget.drainErrorBody(response)
            primaryErrorResponse = rewrapped
        case .transportFailed(let reason):
            unreachableReason = reason
        }

        for backup in targets.dropFirst() {
            if backup.vendorKind == .relay {
                guard let relayContext else {
                    AppLog.proxy.error(
                        "[Proxy] [\(requestID)] Relay backup '\(backup.vendorName)' reached with no signing context; skipping")
                    continue
                }
                switch await RelayTarget.execute(
                    head: head, bodyData: bodyData, target: backup,
                    httpClient: httpClient, context: relayContext, requestID: requestID)
                {
                case .responded(let response):
                    return .served(response, backup)
                default:
                    continue
                }
            }
            if let response = await sendToMappedTarget(
                head: head, bodyData: bodyData, target: backup,
                httpClient: httpClient, requestID: requestID)
            {
                return .served(response, backup)
            }
        }

        if let primaryErrorResponse {
            return .primaryError(primaryErrorResponse, primary)
        }
        return .unreachable(unreachableReason)
    }

    /// Sends to a plain (`.anthropic`-kind) backup target: the vendor's
    /// header treatment (`ProxyForwarder.upstreamHeaders`) plus the same
    /// byte-preserving model splice. Streaming back stays the caller's job.
    private static func sendToMappedTarget(
        head: HTTPRequestHead,
        bodyData: Data,
        target: RoutingSnapshot.RouteTarget,
        httpClient: HTTPClient,
        requestID: String
    ) async -> HTTPClientResponse? {
        let urlString = target.baseURL.trimmingCharacters(in: .init(charactersIn: "/")) + head.uri
        guard URL(string: urlString) != nil else { return nil }
        var request = HTTPClientRequest(url: urlString)
        request.method = head.method
        request.headers = ProxyForwarder.upstreamHeaders(from: head.headers, target: target)
        var body = bodyData
        if let targetModel = target.targetModel {
            body = ProxyForwarder.replaceModelField(in: body, with: targetModel).data
        }
        request.body = .bytes(body)
        do {
            return try await httpClient.execute(
                request, timeout: .seconds(Int64(target.readTimeoutSeconds)))
        } catch {
            AppLog.proxy.error(
                "[Proxy] [\(requestID)] Backup target error for \(target.vendorName): \(error)")
            return nil
        }
    }

    // MARK: - Stream relay

    /// Terminal SSE event written to the client when the local stream cuts
    /// mid-response, so a failure is surfaced instead of a silent EOF.
    static let streamCutErrorEvent: String = {
        let body: [String: Any] = [
            "type": "error",
            "error": [
                "type": "api_error",
                "message": "Local model stream ended unexpectedly",
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        let payload = String(data: data, encoding: .utf8) ?? "{}"
        return "event: error\ndata: \(payload)\n\n"
    }()

    /// Streams a local-route response back to the client channel, chunk for
    /// chunk with no transformation (pure passthrough). If the upstream body
    /// ends mid-response — Splash's process dying, a reset connection — the
    /// client still receives a terminal `error` SSE event before the channel
    /// closes, never a hang. Byte forwarding is immediate: no buffering.
    static func relayStream(
        upstreamResponse: HTTPClientResponse,
        to channel: any Channel,
        requestID: String
    ) async {
        var responseHead = HTTPResponseHead(
            version: .http1_1,
            status: HTTPResponseStatus(statusCode: Int(upstreamResponse.status.code)))
        for (name, value) in upstreamResponse.headers {
            let lower = name.lowercased()
            if lower == "transfer-encoding" || lower == "connection"
                || lower == "content-length" || lower == "content-encoding" {
                continue
            }
            responseHead.headers.add(name: name, value: value)
        }
        responseHead.headers.add(name: "connection", value: "close")

        let contentType = upstreamResponse.headers.first(name: "content-type") ?? ""
        let isSSE = contentType.lowercased().contains("text/event-stream")

        // Queue the head without awaiting (an unflushed write's future only
        // completes on flush — ProxyForwarder.sendResponse's pattern).
        channel.write(NIOAny(HTTPServerResponsePart.head(responseHead)), promise: nil)

        do {
            for try await chunk in upstreamResponse.body {
                try await channel.writeAndFlush(
                    NIOAny(HTTPServerResponsePart.body(.byteBuffer(chunk)))).get()
            }
            try await channel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).get()
        } catch {
            // Upstream cut mid-response, or the client channel itself failed.
            // For SSE streams the head (and possibly events) already reached
            // the client: finish with a clean error event so the consumer
            // sees a terminal signal instead of a truncated stream.
            AppLog.proxy.warning(
                "[Proxy] [\(requestID)] Local target stream ended unexpectedly: \(error)")
            if isSSE {
                var buffer = channel.allocator.buffer(capacity: streamCutErrorEvent.utf8.count)
                buffer.writeString(streamCutErrorEvent)
                channel.write(
                    NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
            }
            _ = try? await channel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).get()
        }
        try? await channel.close().get()
    }
}

/// TCP reachability probe for loopback (splash) vendors; the Task 6 health
/// seam implementation. `RequestRouter` reads `lastSuccess(forVendor:)` when
/// evaluating class/catch-all rules: a vendor whose last success is older
/// than `ClassRuleTable.healthStalenessLimit` (60 s) is treated unhealthy
/// and its rule skipped; never-probed vendors are fail-open. The probe's
/// own cadence (`probeInterval`, 20 s) keeps successful entries comfortably
/// inside that 60 s window — a probe result does not need its own cache,
/// the timestamp IS the cache and the router applies the freshness cutoff.
/// A failed probe records nothing: existing successes simply age out.
final class LocalHealthMonitor: TargetHealthProviding, @unchecked Sendable {

    struct Endpoint: Sendable {
        let vendorID: UUID
        let host: String
        let port: Int
    }

    /// Probe cadence; deliberately shorter than the router's 60 s staleness
    /// limit so entries stay warm even when a tick is delayed.
    static let probeInterval: TimeInterval = 20
    /// TCP connect timeout per probe.
    static let connectTimeoutSeconds: Int = 2

    private let lock = NSLock()
    private var endpoints: [Endpoint] = []
    private var successDates: [UUID: Date] = [:]
    private var attemptDates: [UUID: Date] = [:]
    private var probeLoop: Task<Void, Never>?
    private var eventLoopGroup: MultiThreadedEventLoopGroup?

    /// Tracks the loopback vendors to probe (others ignored). Replaces the
    /// endpoint set wholesale; recorded successes for vendors that disappear
    /// are dropped with them.
    func configure(vendors: [Vendor]) {
        let localEndpoints: [Endpoint] = vendors.compactMap { vendor in
            guard LocalTarget.isLoopbackBaseURL(vendor.baseURL),
                let url = URL(string: vendor.baseURL),
                let host = url.host else { return nil }
            let port = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
            return Endpoint(vendorID: vendor.id, host: host, port: port)
        }
        lock.lock()
        endpoints = localEndpoints
        let known = Set(localEndpoints.map(\.vendorID))
        successDates = successDates.filter { known.contains($0.key) }
        attemptDates = attemptDates.filter { known.contains($0.key) }
        lock.unlock()
    }

    /// Starts the background probe loop. Idempotent.
    func startProbing() {
        lock.lock()
        defer { lock.unlock() }
        guard probeLoop == nil else { return }
        probeLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.probeOnce()
                try? await Task.sleep(nanoseconds: UInt64(Self.probeInterval * 1_000_000_000))
            }
        }
    }

    /// Stops the probe loop and releases the event loop group. Idempotent.
    func stopProbing() async {
        lock.lock()
        let loop = probeLoop
        probeLoop = nil
        let group = eventLoopGroup
        eventLoopGroup = nil
        lock.unlock()
        loop?.cancel()
        try? await group?.shutdownGracefully()
    }

    /// One probe sweep over due endpoints. Within a `probeInterval` window
    /// each vendor is probed at most once (`force` bypasses the window for
    /// tests). A successful TCP connect records `Date()`; a failed one
    /// records nothing — the absence (or age) of a success is the signal.
    func probeOnce(force: Bool = false) async {
        let now = Date()
        lock.lock()
        let due = endpoints.filter { endpoint in
            guard !force, let lastAttempt = attemptDates[endpoint.vendorID] else { return true }
            return now.timeIntervalSince(lastAttempt) >= Self.probeInterval
        }
        for endpoint in due {
            attemptDates[endpoint.vendorID] = now
        }
        lock.unlock()

        guard !due.isEmpty else { return }
        lock.lock()
        if eventLoopGroup == nil {
            eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        }
        let group = eventLoopGroup
        lock.unlock()
        guard let group else { return }

        for endpoint in due {
            if await Self.tcpConnect(host: endpoint.host, port: endpoint.port, group: group) {
                lock.lock()
                successDates[endpoint.vendorID] = Date()
                lock.unlock()
            }
        }
    }

    /// Last successful probe/exchange for the vendor; nil when never probed.
    func lastSuccess(forVendor id: UUID) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return successDates[id]
    }

    /// Records a successful wire exchange (a 2xx local response) so vendor
    /// health stays warm between probe ticks.
    func noteSuccess(vendorID: UUID?) {
        guard let vendorID else { return }
        lock.lock()
        successDates[vendorID] = Date()
        lock.unlock()
    }

    /// Bare TCP connect + immediate close: a real socket, no HTTP spoken —
    /// reaching the listener is the health signal.
    private static func tcpConnect(
        host: String, port: Int, group: MultiThreadedEventLoopGroup
    ) async -> Bool {
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.connectTimeout, value: .seconds(Int64(connectTimeoutSeconds)))
        do {
            let channel = try await bootstrap.connect(host: host, port: port).get()
            try? await channel.close().get()
            return true
        } catch {
            return false
        }
    }
}

import AsyncHTTPClient
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOHTTP1
import OSLog

/// Endpoint-routing seam the relay path consults per request
/// (`EndpointConfigService` is the production implementation; tests inject
/// stubs). Mirrors `QuotaRelayCounting`: RelayTarget's context depends on
/// the seam, not the service type.
protocol EndpointResolving: Sendable {
    /// Resolves a request URL through the current `agent/configs` snapshot.
    /// Always returns (fail-open): non-matching URLs come back unchanged.
    func resolve(_ url: String) async -> (url: String, addZcodeAuthorization: Bool)
    /// The zcode plan JWT (`zcodejwttoken` in the credential store) for the
    /// `x-zcode-authorization` header of a flagged request; nil omits it.
    func zcodeAuthorizationToken() async -> String?
}

/// Server-driven endpoint routing — a port of the CLI's
/// ProviderEndpointRoutingService refresh engine.
///
/// Wire facts (zcode.cjs 0.17.1, reverse-engineered 2026-11-19): the CLI
/// never polls on a timer; every model request resolves through
/// `GET https://zcode.z.ai/api/v1/agent/configs`, refreshed lazily with a
/// 300 s success TTL, a 30 s failure cooldown, a 3 s request timeout, a
/// 256 KiB body bound, and single-flight dedupe.
///
/// Failure policy is fail-open everywhere: a failed, slow, invalid, or
/// missing snapshot never blocks or fails a relay request — the last good
/// snapshot keeps serving, and with no snapshot at all the original pinned
/// URL serves. `resolve` therefore never throws and never blocks longer
/// than the fetch timeout.
actor EndpointConfigService: EndpointResolving {

    struct Configuration {
        /// Origin of the agent API family the config endpoint lives under.
        var origin = "https://zcode.z.ai/api/v1"
        var path = "/agent/configs"
        /// Identity pins shared with the relay header set (RelayTarget).
        var clientVersion = RelayTarget.clientVersion
        /// The signing session's apiKeyId for `x-api-key-id`, when a session
        /// exists (nil = omit the header — "when available").
        var apiKeyIdProvider: (@Sendable () async -> String?)?
        /// The credential store's `zcodejwttoken` (flagged-request Bearer
        /// material); nil provider = always omit the header.
        var zcodeTokenProvider: (@Sendable () -> String?)?
        /// Serve a successful snapshot this long before refetching.
        var successTTL: TimeInterval = 300
        /// After a failed refresh, retry no sooner than this.
        var failureCooldown: TimeInterval = 30
        /// Bound on the whole config fetch (connect + response).
        var requestTimeout: TimeInterval = 3
        /// Bound on the response body read.
        var maxBodyBytes = 256 * 1024
        var now: @Sendable () -> Date = { Date() }
        /// Injected client (tests point one at a local stub); the default
        /// rides the global NIO event loop group like QuotaService's
        /// URLSession — one lightweight client for the process.
        var client: HTTPClient?

        init() {}
    }

    private var configuration: Configuration
    private let client: HTTPClient

    /// Last accepted snapshot and when it was committed.
    private var snapshot: EndpointMapping?
    private var snapshotAt: Date?
    /// End of the last refresh attempt (success or failure) — the anchor of
    /// the 30 s failure cooldown.
    private var lastAttemptAt: Date?
    /// Single-flight: concurrent resolvers share one in-flight refresh.
    private var inFlight: Task<Void, Never>?

    init(configuration: Configuration = Configuration()) {
        var configuration = configuration
        if configuration.client == nil {
            configuration.client = HTTPClient(eventLoopGroupProvider: .singleton)
        }
        self.configuration = configuration
        self.client = configuration.client!
    }

    // MARK: - EndpointResolving

    func resolve(_ url: String) async -> (url: String, addZcodeAuthorization: Bool) {
        await ensureFresh()
        if let resolved = snapshot?.resolve(url) { return resolved }
        return (url: url, addZcodeAuthorization: false)  // fail-open
    }

    func zcodeAuthorizationToken() -> String? {
        configuration.zcodeTokenProvider?()
    }

    // MARK: - Refresh

    /// Lazy TTL refresh: no-op while the snapshot is fresh or the failure
    /// cooldown runs; otherwise one shared fetch (the await is bounded by
    /// `requestTimeout` — the worst case a request path can block here).
    private func ensureFresh() async {
        let now = configuration.now()
        if let snapshotAt, now.timeIntervalSince(snapshotAt) < configuration.successTTL {
            return  // fresh
        }
        if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < configuration.failureCooldown {
            return  // cooling down after a failure — keep serving what we have
        }
        if let inFlight {
            await inFlight.value
            return
        }
        let task = Task { await self.refresh() }
        inFlight = task
        defer { inFlight = nil }
        await task.value
    }

    /// One refresh attempt. Every failure keeps the last snapshot and starts
    /// the cooldown; only a fully valid payload replaces the snapshot.
    private func refresh() async {
        do {
            let data = try await fetch()
            if let mapping = EndpointMapping.parse(data) {
                snapshot = mapping
                snapshotAt = configuration.now()
            } else {
                AppLog.proxy.warning(
                    "[EndpointConfig] agent/configs payload rejected (last snapshot kept, fail-open)")
            }
        } catch {
            let reason = (error as? EndpointConfigError)?.errorDescription ?? String(describing: error)
            AppLog.proxy.warning(
                "[EndpointConfig] agent/configs fetch failed (last snapshot kept, fail-open): \(reason)")
        }
        lastAttemptAt = configuration.now()
    }

    /// The `GET <origin>/agent/configs` exchange: CLI identity headers,
    /// 3 s total bound, 256 KiB body bound.
    private func fetch() async throws -> Data {
        guard let url = URL(string: configuration.origin + configuration.path) else {
            throw EndpointConfigError.badURL
        }
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .GET
        var headers = HTTPHeaders()
        headers.add(name: "accept", value: "application/json")
        headers.add(name: "user-agent", value: "ZCode/\(configuration.clientVersion)")
        headers.add(name: "x-zcode-app-version", value: configuration.clientVersion)
        request.headers = headers
        if let apiKeyId = await configuration.apiKeyIdProvider?() {
            request.headers.add(name: "x-api-key-id", value: apiKeyId)
        }
        let response = try await client.execute(
            request, timeout: .seconds(Int64(configuration.requestTimeout)))
        guard response.status.code == 200 else {
            throw EndpointConfigError.httpStatus(Int(response.status.code))
        }
        var data = Data()
        for try await chunk in response.body {
            if data.count + chunk.readableBytes > configuration.maxBodyBytes {
                throw EndpointConfigError.tooLarge
            }
            if let bytes = chunk.getData(at: chunk.readerIndex, length: chunk.readableBytes) {
                data.append(bytes)
            }
        }
        return data
    }
}

/// Typed refresh failures — reasons only, no response bytes.
private enum EndpointConfigError: Error, LocalizedError {
    case badURL
    case httpStatus(Int)
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .badURL: "configured endpoint URL is invalid"
        case let .httpStatus(status): "agent/configs answered HTTP \(status)"
        case .tooLarge: "agent/configs body exceeded the 256 KiB bound"
        }
    }
}

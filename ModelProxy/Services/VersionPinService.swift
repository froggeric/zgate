import AsyncHTTPClient
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOHTTP1
import OSLog

/// Server-driven relay client-version pin (relay fidelity Task 4).
///
/// The impersonated zcode CLI version must not fall below the server's
/// minimum. Wire shape: `GET
/// https://zcode.z.ai/api/v1/client/configs?app_version=<current>&platform=darwin-arm64`
/// (optional `Authorization: Bearer <zcodejwttoken>` — the credential
/// store's `zcodejwttoken`, same material the endpoint-routing flagged
/// header uses); the response's `data.configs.forceUpdate.minimalVersion`
/// names the oldest acceptable client version.
///
/// Policy:
/// - Cadence: one poll at launch, then every 6 h (`startPolling`; tests
///   drive `pollIfDue`/`pollNow` with the injected clock — no real timers).
/// - Greater-only bump: a semver-GREATER minimum raises the pin and fires
///   the injected `onBump` sink exactly once (the app layer persists it as
///   `AppConfig.relayClientVersion` and updates the live relay context);
///   an equal or lower minimum, a missing/unparseable value, or any fetch
///   failure changes nothing.
/// - Silent failure: a failed poll keeps the current pin, surfaces nothing
///   user-visible, and logs one debug line at most (once per 6 h attempt —
///   no spam).
actor VersionPinService {

    /// Dot-separated non-negative integers compared numerically, component
    /// by component (missing components count as 0): `0.17.1 < 0.18.0`,
    /// equal is never greater, `1.0.0 > 0.99.99`. Anything else (pre-release
    /// suffixes, letters, empty components) fails to parse — the bump path
    /// treats an unparseable SERVER value as inert; the pin itself only
    /// ever holds parseable values (the default is, and only parseable
    /// values bump).
    struct SemVer: Comparable, Sendable {
        let numbers: [Int]

        init?(_ raw: String) {
            let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
            var parsed: [Int] = []
            for part in parts {
                // ASCII digits only — no signs, whitespace, or suffixes.
                guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                    let value = Int(part)
                else { return nil }
                parsed.append(value)
            }
            guard !parsed.isEmpty else { return nil }
            numbers = parsed
        }

        static func < (lhs: SemVer, rhs: SemVer) -> Bool {
            let count = max(lhs.numbers.count, rhs.numbers.count)
            for i in 0..<count {
                let l = i < lhs.numbers.count ? lhs.numbers[i] : 0
                let r = i < rhs.numbers.count ? rhs.numbers[i] : 0
                if l != r { return l < r }
            }
            return false
        }

        /// Consistent with `<`: zero-padded equality (`0.17.0 == 0.17`) —
        /// the synthesized array == would disagree with the ordering.
        static func == (lhs: SemVer, rhs: SemVer) -> Bool {
            !(lhs < rhs || rhs < lhs)
        }
    }

    // MARK: - Configuration

    struct Configuration {
        /// Origin of the client API family the config endpoint lives under.
        var origin = "https://zcode.z.ai/api/v1"
        var path = "/client/configs"
        /// `platform` query value — the relay face's platform pin.
        var platform = RelayTarget.platform
        /// The pin this service starts from (the persisted
        /// `AppConfig.relayClientVersion`, itself defaulted to the bundled
        /// constant).
        var initialVersion = RelayTarget.clientVersion
        /// The credential store's `zcodejwttoken` for the optional request
        /// Bearer; nil provider or nil value = omit the header.
        var zcodeTokenProvider: (@Sendable () -> String?)?
        /// Fired once per ACCEPTED bump (version strings only, never on
        /// rejections or failures) — the app-layer persistence sink plus
        /// live-context update. Never throws, never blocks the poll.
        var onBump: (@Sendable (String) -> Void)?
        /// Poll at least this far apart.
        var pollInterval: TimeInterval = 6 * 3600
        /// Bound on the whole config fetch (connect + response + body).
        var requestTimeout: TimeInterval = 20
        /// Bound on the response body read.
        var maxBodyBytes = 256 * 1024
        var now: @Sendable () -> Date = { Date() }
        /// Injected client (tests point one at a local stub); the default
        /// rides the global NIO event loop group like the endpoint-routing
        /// service's — one lightweight client for the process.
        var client: HTTPClient?

        init() {}
    }

    private let configuration: Configuration
    private let client: HTTPClient

    /// The current pin (actor-isolated).
    private var version: String
    /// Last poll attempt — the anchor of the 6 h cadence.
    private var lastAttemptAt: Date?
    private var pollLoop: Task<Void, Never>?

    init(configuration: Configuration = Configuration()) {
        var configuration = configuration
        if configuration.client == nil {
            configuration.client = HTTPClient(eventLoopGroupProvider: .singleton)
        }
        self.configuration = configuration
        self.client = configuration.client!
        self.version = configuration.initialVersion
    }

    // MARK: - Cadence

    /// Starts the cadence: one poll immediately (launch), then one every
    /// `pollInterval`. Idempotent; runs for the process lifetime (like
    /// quota polling, version tracking is independent of the listener).
    /// Tests never start it — they drive `pollIfDue`/`pollNow` directly.
    func startPolling() {
        guard pollLoop == nil else { return }
        let intervalNanoseconds = UInt64(max(0, configuration.pollInterval) * 1_000_000_000)
        pollLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollIfDue()
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
            }
        }
    }

    func stopPolling() {
        pollLoop?.cancel()
        pollLoop = nil
    }

    /// Polls when due: no attempt yet (the launch poll), or the last
    /// attempt older than `pollInterval`.
    func pollIfDue() async {
        let now = configuration.now()
        if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < configuration.pollInterval {
            return
        }
        lastAttemptAt = now
        await poll()
    }

    /// Polls unconditionally (manual refresh; the test surface).
    func pollNow() async {
        lastAttemptAt = configuration.now()
        await poll()
    }

    /// The current pin.
    func currentVersion() -> String {
        version
    }

    // MARK: - Poll

    private func poll() async {
        do {
            let data = try await fetchBounded()
            guard let minimal = Self.minimalVersion(in: data) else {
                // A well-formed response without a usable minimum is not an
                // error — there is simply nothing to bump to.
                AppLog.proxy.debug("[VersionPin] client/configs carried no usable minimalVersion (pin kept)")
                return
            }
            apply(minimal)
        } catch {
            // Silent policy: keep the current pin, nothing user-visible, no
            // log spam — one debug line per (at most 6-hourly) attempt.
            let reason = (error as? VersionPinError)?.errorDescription ?? String(describing: error)
            AppLog.proxy.debug("[VersionPin] client/configs poll failed (pin kept): \(reason)")
        }
    }

    /// Greater-only bump: the pin rises to a semver-greater server minimum;
    /// equal, lower, or unparseable values change nothing. The pin updates
    /// BEFORE the sink runs, so the next poll's `app_version` query already
    /// carries the new value.
    private func apply(_ minimal: String) {
        guard let server = SemVer(minimal), let pinned = SemVer(version),
            pinned < server
        else { return }
        let previous = version
        version = minimal
        AppLog.proxy.info("[VersionPin] relay client-version pin bumped: \(previous) → \(minimal)")
        configuration.onBump?(minimal)
    }

    /// `data.configs.forceUpdate.minimalVersion` of the `{code, msg, data}`
    /// envelope — nil when absent or empty (never a bump).
    static func minimalVersion(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let payload = json["data"] as? [String: Any],
            let configs = payload["configs"] as? [String: Any],
            let forceUpdate = configs["forceUpdate"] as? [String: Any],
            let minimal = forceUpdate["minimalVersion"] as? String,
            !minimal.isEmpty
        else { return nil }
        return minimal
    }

    /// The whole-exchange time bound (the endpoint-routing service's
    /// lesson): async-http-client's `execute` deadline covers only connect +
    /// request + response HEAD — a head-then-stall or trickling endpoint
    /// would hang the body read forever. Racing the whole fetch against
    /// `requestTimeout` closes that gap: cancelling the losing task cancels
    /// the AHC transaction and unblocks the body iterator, so `poll` always
    /// returns within the bound.
    private func fetchBounded() async throws -> Data {
        let timeoutNanoseconds = UInt64(max(0, configuration.requestTimeout) * 1_000_000_000)
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await self.fetch() }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw VersionPinError.timeout
            }
            defer { group.cancelAll() }
            guard let data = try await group.next() else {
                throw VersionPinError.timeout
            }
            return data
        }
    }

    /// The `GET <origin>/client/configs` exchange: the pinned query pair,
    /// head-phase deadline, 256 KiB body bound (the outer time bound lives
    /// in `fetchBounded`).
    private func fetch() async throws -> Data {
        guard var components = URLComponents(string: configuration.origin + configuration.path) else {
            throw VersionPinError.badURL
        }
        components.queryItems = [
            URLQueryItem(name: "app_version", value: version),
            URLQueryItem(name: "platform", value: configuration.platform),
        ]
        guard let url = components.url else {
            throw VersionPinError.badURL
        }
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .GET
        var headers = HTTPHeaders()
        headers.add(name: "accept", value: "application/json")
        if let token = configuration.zcodeTokenProvider?() {
            headers.add(name: "authorization", value: "Bearer \(token)")
        }
        request.headers = headers
        let response = try await client.execute(
            request, timeout: .seconds(Int64(configuration.requestTimeout)))
        guard response.status.code == 200 else {
            throw VersionPinError.httpStatus(Int(response.status.code))
        }
        var data = Data()
        for try await chunk in response.body {
            if data.count + chunk.readableBytes > configuration.maxBodyBytes {
                throw VersionPinError.tooLarge
            }
            if let bytes = chunk.getData(at: chunk.readerIndex, length: chunk.readableBytes) {
                data.append(bytes)
            }
        }
        return data
    }
}

/// Typed poll failures — reasons only, no response bytes.
private enum VersionPinError: Error, LocalizedError {
    case badURL
    case httpStatus(Int)
    case tooLarge
    case timeout

    var errorDescription: String? {
        switch self {
        case .badURL: "configured client/configs URL is invalid"
        case let .httpStatus(status): "client/configs answered HTTP \(status)"
        case .tooLarge: "client/configs body exceeded the 256 KiB bound"
        case .timeout: "client/configs exchange exceeded the whole-exchange bound"
        }
    }
}

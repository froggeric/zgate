import CryptoKit
import Foundation

/// The credential set a `ready` poll result carries (§A.6 step 3).
/// Value type is deliberate: it hands token material to the caller and is
/// never logged, never emitted into an event, never persisted anywhere
/// except through `CredentialStore.saveZaiLogin`.
struct ZaiLoginCredentials: Equatable, Sendable {
    /// ~1 h OAuth access JWT (`oauth:zai:access_token` — the z/login input).
    let accessToken: String
    /// Long-lived identity JWT (`zcodejwttoken`, no `exp` claim).
    let zcodeJwtToken: String
    /// The `user` object re-serialized as JSON (`oauth:zai:user_info`).
    let userInfoJSON: String
}

/// Terminal outcome of the CLI OAuth poll flow.
enum ZaiLoginOutcome: Equatable, Sendable {
    case ready(ZaiLoginCredentials)
    /// The server reported a terminal failure (`failed` / `auth_failed`).
    case failed(status: String)
    /// The overall cap (300 s, the CLI's default) elapsed first.
    case timedOut(afterMs: Int64)
}

enum ZaiLoginError: Error, Equatable {
    /// `pollUntilTerminal` ran before a successful `begin()`.
    case notStarted
    /// An endpoint answered outside the protocol shape (no recovery).
    case malformed(stage: String, reason: String)
}

/// Native in-app OAuth client for the z.ai CLI flow (item 4, report §C.2):
/// locally generated poll token → `POST /oauth/cli/init`
/// (`{"provider":"zai"}`, `Authorization: Bearer <pollToken>`) →
/// `authorizeURL` (the UI opens it in the default browser) →
/// `GET /oauth/cli/poll/{flow_id}` with the same bearer at the
/// server-advertised interval until `ready`/`failed`, 300 s overall cap,
/// 408/429/5xx tolerated. No local callback server, no custom scheme, no
/// node dependency. On `ready`, a configured `storeBase` persists the
/// credential set through the store's envelope write path.
///
/// This type never logs: no token byte ever becomes a string outside the
/// credentials value itself; events carry durations/booleans and fixed
/// typed display copy only.
actor ZaiLoginClient {

    struct Configuration {
        var origin = "https://api.z.ai"
        var session: URLSession = .shared
        var requestTimeout: TimeInterval = 15
        /// Overall poll cap — the bundle's `EDc = 300` default.
        var overallTimeout: TimeInterval = 300
        /// Bearer for both endpoints: 32 random bytes hex. Injectable so
        /// tests pin a synthetic token.
        var pollToken = ZaiLoginClient.generatePollToken()
        var now: @Sendable () -> Date = { Date() }
        /// Sleep seam: production suspends for real; tests advance a
        /// virtual clock (the GatedSplashClock pattern).
        var sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        /// Store base for the `ready` write path; nil = the caller owns
        /// persistence.
        var storeBase: URL?
        /// Optional event hook (`.awaitingAuthorization` after init,
        /// `.authorizationComplete` after the ready-path persist, then a
        /// `.refreshFailed(location)` warning when the written store
        /// carries no project-key location) — the UI task wires it to the
        /// credential event channel.
        var onEvent: (@Sendable (CredentialEvent) -> Void)?

        init() {}
    }

    private struct LoginFlow: Sendable {
        let flowID: String
        let authorizeURL: URL
        let pollIntervalSeconds: TimeInterval
    }

    private let configuration: Configuration
    private var flow: LoginFlow?

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// 32 random bytes as 64 hex chars — the flow's bearer.
    static func generatePollToken() -> String {
        SymmetricKey(size: .bits256)
            .withUnsafeBytes { Data($0).map { String(format: "%02x", $0) }.joined() }
    }

    /// Stage of the missing-location warning (`.refreshFailed` after a
    /// ready persist that produced a location-less store).
    static let missingLocationStage = "location"

    /// Warning copy for that event — fixed display strings, never token
    /// material: ZGate cannot resolve the project location itself (the
    /// store entry is the only source), so one GUI/CLI login must
    /// populate it.
    static let missingLocationReason =
        "sign-in succeeded but the store has no project location — complete one login in the ZCode GUI or CLI to populate it, then Reload"

    /// The authorize URL once `begin()` succeeded — the UI opens it.
    func authorizeURL() -> URL? {
        flow?.authorizeURL
    }

    /// Starts the flow: the init call returns `{flow_id, authorize_url,
    /// expires_at, poll_interval_sec}` (validated exactly these fields,
    /// §A.6 step 1).
    func begin() async throws {
        let body = try JSONSerialization.data(withJSONObject: ["provider": "zai"])
        let (status, json) = try await post(path: "/oauth/cli/init", body: body)
        let data = (json?["data"] as? [String: Any]) ?? (json ?? [:])
        guard status == 200,
            let flowID = data["flow_id"] as? String,
            let authorize = data["authorize_url"] as? String,
            let url = URL(string: authorize)
        else {
            throw ZaiLoginError.malformed(stage: "init", reason: "missing flow_id/authorize_url")
        }
        flow = LoginFlow(
            flowID: flowID,
            authorizeURL: url,
            pollIntervalSeconds: (data["poll_interval_sec"] as? Double) ?? 2)
        configuration.onEvent?(.awaitingAuthorization)
    }

    /// Polls until a terminal status or the overall cap. On `ready` with a
    /// configured `storeBase`, the credentials are persisted through
    /// `CredentialStore.saveZaiLogin` (envelope write path, §A.6 step 4)
    /// before returning; a persist failure propagates to the caller. When
    /// the written store carries no `project-key-location:v1:*` entry, a
    /// non-fatal `.refreshFailed(location)` warning trails
    /// `.authorizationComplete` (the login cannot mint a plan token until
    /// a GUI/CLI login populates the location).
    func pollUntilTerminal() async throws -> ZaiLoginOutcome {
        guard let flow else { throw ZaiLoginError.notStarted }
        let startMs = currentMs()
        while true {
            let (status, json) = try await get(path: "/oauth/cli/poll/\(flow.flowID)")
            if status == 200, let outcome = Self.parsePoll(json) {
                var missingLocationAfterSave = false
                if case let .ready(credentials) = outcome, let base = configuration.storeBase {
                    let saved = try CredentialStore.saveZaiLogin(
                        accessToken: credentials.accessToken,
                        zcodeJwtToken: credentials.zcodeJwtToken,
                        userInfoJSON: credentials.userInfoJSON,
                        base: base)
                    missingLocationAfterSave = saved.storeLacksProjectLocation
                }
                if case .ready = outcome {
                    configuration.onEvent?(.authorizationComplete)
                    // Honest limitation (fast-follow F3): a store without a
                    // location entry cannot mint a plan token, and ZGate
                    // cannot resolve the location itself (the store entry is
                    // the only source). Emitted AFTER .authorizationComplete
                    // so the warning is the channel's LAST event — the
                    // standing face already renders a trailing
                    // .refreshFailed generically. Non-fatal: the login
                    // itself succeeded; payload is fixed typed copy.
                    if missingLocationAfterSave {
                        configuration.onEvent?(.refreshFailed(
                            stage: Self.missingLocationStage,
                            reason: Self.missingLocationReason))
                    }
                }
                return outcome
            }
            // Pending answers and 408/429/5xx: retry at the advertised
            // interval, bounded by the overall cap.
            let elapsedMs = currentMs() - startMs
            if elapsedMs >= Int64(configuration.overallTimeout * 1000) {
                return .timedOut(afterMs: elapsedMs)
            }
            try await configuration.sleep(flow.pollIntervalSeconds)
        }
    }

    /// The poll body: `data.status` pending / ready / failed (auth_failed);
    /// the ready payload carries accessToken / token / user. Tolerant of
    /// the payload sitting at the top level instead of under `data`.
    /// Returns nil for pending/unknown shapes (keep polling).
    private static func parsePoll(_ json: [String: Any]?) -> ZaiLoginOutcome? {
        guard let json else { return nil }
        let data = (json["data"] as? [String: Any]) ?? json
        let accessToken = (data["accessToken"] as? String) ?? ""
        if !accessToken.isEmpty {
            let userJSON = (data["user"] ).flatMap {
                (try? JSONSerialization.data(withJSONObject: $0))
                    .flatMap { String(data: $0, encoding: .utf8) }
            } ?? "{}"
            return .ready(ZaiLoginCredentials(
                accessToken: accessToken,
                zcodeJwtToken: (data["token"] as? String) ?? "",
                userInfoJSON: userJSON))
        }
        switch data["status"] as? String {
        case "failed", "auth_failed":
            return .failed(status: (data["status"] as? String) ?? "failed")
        default:
            return nil
        }
    }

    // MARK: - HTTP

    private func post(path: String, body: Data) async throws -> (Int, [String: Any]?) {
        var request = try request(path: path)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try await send(request)
    }

    private func get(path: String) async throws -> (Int, [String: Any]?) {
        var request = try request(path: path)
        request.httpMethod = "GET"
        return try await send(request)
    }

    private func request(path: String) throws -> URLRequest {
        guard let url = URL(string: configuration.origin + path) else {
            // path embeds the server-supplied flow_id — never force-unwrap it
            throw ZaiLoginError.malformed(stage: "url", reason: "unbuildable request URL")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = configuration.requestTimeout
        request.setValue(
            "Bearer \(configuration.pollToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Int, [String: Any]?) {
        let (data, response) = try await configuration.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (status, json)
    }

    private func currentMs() -> Int64 {
        Int64(configuration.now().timeIntervalSince1970 * 1000)
    }
}

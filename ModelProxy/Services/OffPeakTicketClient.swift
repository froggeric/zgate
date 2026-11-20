import AsyncHTTPClient
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOHTTP1

/// One off-peak ticket — the control plane's universal row shape (take
/// returns one, status returns many).
///
/// Unit notes (upstream wire fields are converted at the parse boundary):
/// - `active_deadline` arrives as UNIX SECONDS and is stored here as
///   `activeDeadlineMs` (epoch milliseconds) — the deadline to START using a
///   ready ticket, not its expiry.
/// - `next_poll_after` arrives as (and stays) SECONDS.
struct OffPeakTicket: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case queued, ready, active, settled, expired
        case notFound = "not_found"
    }

    let ticketID: String
    let state: State
    let position: Int?
    let activeDeadlineMs: Int64?
    let nextPollAfterSeconds: Int?
}

/// `GET /api/v1/off-peak/ticket/availability` payload. `nextTakeAtSeconds`
/// is the upstream `next_take_at` in UNIX SECONDS (no conversion) and is
/// mandatory on the wire whenever `can_take_number` is false — enforced at
/// the parse boundary.
struct OffPeakAvailability: Equatable, Sendable {
    let canTake: Bool
    let nextTakeAtSeconds: Int64?
}

/// Typed control-plane failures. `code`/`msg` come from the PARSED envelope
/// only (never substring-scanned); `code == nil` means the body was not a
/// JSON envelope carrying a numeric `code`. Reasons are static strings — no
/// response bytes are embedded.
enum OffPeakTicketError: Error, Equatable, Sendable {
    /// The zcode plan JWT provider answered nil (CredentialStore
    /// `zcodejwttoken` in production).
    case missingJWT
    /// The coding-plan api-key provider answered nil (Task 7's minted
    /// `"{apiKey}.{secretKey}"` in production).
    case missingCodingPlanKey
    /// Envelope rejected: `code` was absent/unparseable (nil) or non-zero.
    case envelope(status: Int, code: Int?, msg: String?)
    /// `code == 0` but a required payload field was missing/invalid.
    case malformed(String)
    /// The whole-exchange bound (head + body) was exceeded.
    case exchangeTimeout(seconds: Int)
}

/// The official ZCode "Off-Peak / Idle Plan" ticket-queue control plane:
/// availability → take → status → settle. A standalone, stateless-per-call
/// client (no actor, no singleton, no network at initialization) — Task 10's
/// orchestrator drives it; the production wiring (JWT from
/// `CredentialStore.zcodeJwtToken()`, key from ApiKeyMinter, origin from
/// config) also lives there.
///
/// Wire discipline (official desktop-client protocol):
/// - UNSIGNED plane: `/api/v1/off-peak/*` is in the official client's
///   `isUnsignedModelRequestPath` — this client NEVER builds the V4 signing
///   quartet (`x-client-ts`/`-sig`/`-nonce`/`-pow`), `x-app-id`, or the
///   signed plane's `x-api-key`. Auth is `Authorization: Bearer <zcode plan
///   JWT>` + `X-Coding-Plan-Api-Key: {apiKey}.{secretKey}` on every call.
/// - Envelope: `{code, msg, data}` — success ONLY on numeric `code == 0`
///   from parsed JSON (booleans excluded, the RelayErrorTaxonomy number
///   discipline); anything else throws `OffPeakTicketError.envelope` with
///   code + msg. No substring parsing of bodies.
/// - Timeouts bound the WHOLE exchange (head + body raced against the
///   deadline — Task 1's lesson; AHC's execute deadline alone leaves the
///   body read unbounded). 15 s for availability/take/status, 8 s for
///   settle.
/// - Status batches chunk to ≤ `statusBatchLimit` ids per POST.
/// - Settle is fire-and-forget-tolerant: any 4xx is success (the server
///   already cleaned the ticket up) and no failure — transport, envelope,
///   or otherwise — is ever thrown to the caller (logged instead).
struct OffPeakTicketClient: Sendable {

    /// Maximum ticket ids per `status` POST (upstream batch bound).
    static let statusBatchLimit = 100
    /// Whole-exchange bound for availability / take / status.
    static let requestTimeout: TimeInterval = 15
    /// Whole-exchange bound for settle.
    static let settleTimeout: TimeInterval = 8
    /// Response body bound (ticket payloads are small JSON envelopes).
    static let maxBodyBytes = 256 * 1024

    /// Origin of the off-peak plane family (default `https://zcode.z.ai`,
    /// configurable so tests point the default execute at a local stub).
    let origin: String
    /// zcode plan JWT provider (`zcodejwttoken`); nil → `missingJWT`.
    let jwtProvider: @Sendable () async -> String?
    /// `"{apiKey}.{secretKey}"` provider (Task 7's minted credential);
    /// nil → `missingCodingPlanKey`.
    let credentialProvider: @Sendable () async -> String?
    /// HTTP seam — receives the prepared request, the serialized body bytes,
    /// and the whole-exchange bound for THIS call (15 s control calls, 8 s
    /// settle). Tests script it; the default rides a real AsyncHTTPClient
    /// with the Task-1 head+body race.
    let execute: @Sendable (
        _ request: HTTPClientRequest, _ body: Data?, _ timeout: TimeInterval
    ) async throws -> (status: Int, body: Data)
    /// CLI face version driving `user-agent`/`x-zcode-app-version` (the
    /// configured pin's default, like RelayTarget).
    let clientVersion: String
    /// Client-scoped `x-session-id` (the control plane is not
    /// per-conversation; Task 10 may inject its own identity).
    let sessionID: String

    init(
        origin: String,
        jwtProvider: @escaping @Sendable () async -> String?,
        credentialProvider: @escaping @Sendable () async -> String?,
        clientVersion: String = RelayTarget.clientVersion,
        sessionID: String = UUID().uuidString.lowercased(),
        execute: @escaping @Sendable (
            _ request: HTTPClientRequest, _ body: Data?, _ timeout: TimeInterval
        ) async throws -> (status: Int, body: Data) = Self.defaultExecute
    ) {
        self.origin = origin
        self.jwtProvider = jwtProvider
        self.credentialProvider = credentialProvider
        self.clientVersion = clientVersion
        self.sessionID = sessionID
        self.execute = execute
    }

    // MARK: - Control calls

    /// `GET /api/v1/off-peak/ticket/availability` — whether a ticket may be
    /// taken now, and (when not) the unix-second moment the queue reopens.
    func availability() async throws -> OffPeakAvailability {
        let payload = try await call(
            method: "GET", path: "/api/v1/off-peak/ticket/availability", body: nil)
        guard let canTake = Self.boolField(payload["can_take_number"]) else {
            throw OffPeakTicketError.malformed("availability carries no can_take_number")
        }
        let next = Self.numberField(payload["next_take_at"]).map(Int64.init)
        if !canTake, next == nil {
            throw OffPeakTicketError.malformed("availability false without next_take_at")
        }
        return OffPeakAvailability(canTake: canTake, nextTakeAtSeconds: next)
    }

    /// `POST /api/v1/off-peak/ticket` body `{"task_id": <id>}` — take a
    /// place in the queue for a task.
    func takeTicket(taskID: String) async throws -> OffPeakTicket {
        let body = try JSONSerialization.data(withJSONObject: ["task_id": taskID])
        let payload = try await call(method: "POST", path: "/api/v1/off-peak/ticket", body: body)
        return try Self.ticket(from: payload)
    }

    /// `POST /api/v1/off-peak/ticket/status` body `{"ticket_ids": [...]}` —
    /// batch status, chunked to ≤ 100 ids per POST. Tickets from all batches
    /// return in request order; `nextPollAfterSeconds` is the MAX hint across
    /// batches (nil when every batch omitted it). An empty id list performs
    /// no call and returns `([], nil)`.
    func status(ticketIDs: [String]) async throws -> (
        tickets: [OffPeakTicket], nextPollAfterSeconds: Int?
    ) {
        var tickets: [OffPeakTicket] = []
        var nextPoll: Int?
        var start = ticketIDs.startIndex
        while start < ticketIDs.endIndex {
            let end = ticketIDs.index(start, offsetBy: Self.statusBatchLimit, limitedBy: ticketIDs.endIndex)
                ?? ticketIDs.endIndex
            let chunk = Array(ticketIDs[start..<end])
            let body = try JSONSerialization.data(withJSONObject: ["ticket_ids": chunk])
            let payload = try await call(
                method: "POST", path: "/api/v1/off-peak/ticket/status", body: body)
            let rows = Self.arrayField(payload["tickets"])
            tickets += try rows.map(Self.ticket(from:))
            if let hint = Self.numberField(payload["next_poll_after"]).map(Int.init) {
                nextPoll = max(nextPoll ?? hint, hint)
            }
            start = end
        }
        return (tickets, nextPoll)
    }

    /// `POST /api/v1/off-peak/ticket/{id}/settle` — release a finished
    /// ticket. Any 4xx is success (the server already cleaned it up) and no
    /// failure of any kind is thrown to the caller — the best-effort outcome
    /// is logged and swallowed.
    func settle(ticketID: String) async {
        let encoded = ticketID.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?"))
        ) ?? ticketID
        do {
            let material = try await authMaterial()
            guard let url = URL(string: "\(origin)/api/v1/off-peak/ticket/\(encoded)/settle") else {
                throw OffPeakTicketError.malformed("settle path does not form a URL")
            }
            var request = HTTPClientRequest(url: url.absoluteString)
            request.method = .POST
            request.headers = Self.requestHeaders(
                authorization: material.jwt, codingPlanKey: material.codingPlanKey,
                clientVersion: clientVersion, sessionID: sessionID, jsonBody: false)
            let (status, data) = try await execute(request, nil, Self.settleTimeout)
            if (400..<500).contains(status) { return }  // already cleaned up
            if (200..<300).contains(status) {
                _ = try Self.gate(status: status, body: data)
                return
            }
            AppLog.proxy.warning("[OffPeakTicket] settle answered HTTP \(status) — swallowed")
        } catch {
            AppLog.proxy.warning("[OffPeakTicket] settle failed — swallowed: \(Self.reason(error))")
        }
    }

    // MARK: - Shared exchange

    private struct AuthMaterial {
        let jwt: String
        let codingPlanKey: String
    }

    private func authMaterial() async throws -> AuthMaterial {
        guard let jwt = await jwtProvider(), !jwt.isEmpty else {
            throw OffPeakTicketError.missingJWT
        }
        guard let codingPlanKey = await credentialProvider(), !codingPlanKey.isEmpty else {
            throw OffPeakTicketError.missingCodingPlanKey
        }
        return AuthMaterial(jwt: jwt, codingPlanKey: codingPlanKey)
    }

    /// One control-plane exchange: auth headers, unsigned identity face,
    /// whole-exchange bound, envelope gate → payload object.
    private func call(method: String, path: String, body: Data?) async throws -> [String: Any] {
        let material = try await authMaterial()
        guard let url = URL(string: origin + path) else {
            throw OffPeakTicketError.malformed("path does not form a URL: \(path)")
        }
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = method == "GET" ? .GET : .POST
        request.headers = Self.requestHeaders(
            authorization: material.jwt, codingPlanKey: material.codingPlanKey,
            clientVersion: clientVersion, sessionID: sessionID, jsonBody: body != nil)
        let (status, data) = try await execute(request, body, Self.requestTimeout)
        return try Self.gate(status: status, body: data)
    }

    /// Envelope gate: success ONLY on numeric `code == 0` from parsed JSON
    /// (booleans excluded); non-zero or absent code → typed error with code
    /// + msg; `code == 0` without a `data` object → malformed.
    static func gate(status: Int, body: Data) throws -> [String: Any] {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            throw OffPeakTicketError.envelope(status: status, code: nil, msg: nil)
        }
        let code = numberField(json["code"]).map(Int.init)
        guard code == 0 else {
            throw OffPeakTicketError.envelope(status: status, code: code, msg: json["msg"] as? String)
        }
        guard let payload = json["data"] as? [String: Any] else {
            throw OffPeakTicketError.malformed("envelope carries no data object")
        }
        return payload
    }

    // MARK: - Payload walking (tolerant)

    /// One ticket row from a `data` object (take) or a `data.tickets[]` row
    /// (status). Deadline converted seconds → milliseconds HERE — the only
    /// place wire units meet the stored ones.
    static func ticket(from raw: [String: Any]) throws -> OffPeakTicket {
        guard let ticketID = stringField(raw["ticket_id"] ?? raw["ticketId"]), !ticketID.isEmpty
        else {
            throw OffPeakTicketError.malformed("ticket row carries no ticket_id")
        }
        guard let stateRaw = raw["state"] as? String,
            let state = OffPeakTicket.State(rawValue: stateRaw)
        else {
            throw OffPeakTicketError.malformed("ticket row carries an unknown state")
        }
        return OffPeakTicket(
            ticketID: ticketID,
            state: state,
            position: numberField(raw["position"]).map(Int.init),
            activeDeadlineMs: numberField(raw["active_deadline"] ?? raw["activeDeadline"])
                .map { Int64($0) * 1000 },
            nextPollAfterSeconds: numberField(raw["next_poll_after"] ?? raw["nextPollAfter"])
                .map(Int.init))
    }

    /// The CLI identity header set for the off-peak plane — the Task 2
    /// (RelayTarget) static face in the same wire order, built from the
    /// same pinned constants, plus the plane's own auth pair right after
    /// `authorization`. Deliberately NOT reused from `relayHeaders` (that
    /// builder is welded to the signing session): the assembly is
    /// duplicated here on purpose — keep the two in sync when the CLI face
    /// changes. Excluded vs the relay face: the V4 quartet + `x-app-id` +
    /// `x-api-key` (unsigned plane — `x-coding-plan-api-key` replaces the
    /// project-token auth) and `anthropic-version`/`anthropic-beta`
    /// (messages-endpoint headers, not identity; Task 10's data plane adds
    /// them where they belong).
    static func requestHeaders(
        authorization: String,
        codingPlanKey: String,
        clientVersion: String,
        sessionID: String,
        jsonBody: Bool
    ) -> HTTPHeaders {
        var headers = HTTPHeaders()
        if jsonBody {
            headers.add(name: "content-type", value: "application/json")
        }
        headers.add(name: "authorization", value: "Bearer \(authorization)")
        headers.add(name: "x-coding-plan-api-key", value: codingPlanKey)
        headers.add(name: "http-referer", value: RelayTarget.httpReferer)
        headers.add(name: "user-agent", value: RelayTarget.userAgent(for: clientVersion))
        headers.add(name: "x-zcode-app-version", value: clientVersion)
        headers.add(name: "x-title", value: RelayTarget.title)
        headers.add(name: "x-client-language", value: RelayTarget.clientLanguage)
        headers.add(name: "x-client-timezone", value: TimeZone.current.identifier)
        headers.add(name: "x-zcode-agent", value: RelayTarget.zcodeAgent)
        headers.add(name: "x-platform", value: RelayTarget.platform)
        headers.add(name: "x-os-category", value: RelayTarget.osCategory)
        headers.add(name: "x-os-version", value: RelayTarget.osVersion)
        headers.add(name: "x-request-id", value: UUID().uuidString.lowercased())
        headers.add(name: "x-zcode-session-type", value: RelayTarget.SessionIdentity.mainType)
        headers.add(name: "x-zcode-trace-id", value: UUID().uuidString.lowercased())
        headers.add(name: "x-query-id", value: UUID().uuidString.lowercased())
        headers.add(name: "x-zcode-query-source", value: RelayTarget.querySource)
        headers.add(name: "x-session-id", value: sessionID)
        return headers
    }

    /// Number-or-numeric-string field, booleans excluded (the
    /// RelayErrorTaxonomy / MonitorEnvelope parse discipline — a JSON
    /// `false` must never masquerade as `code == 0`).
    private static func numberField(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.doubleValue
        }
        if let string = value as? String { return Double(string) }
        return nil
    }

    /// Boolean field (JSON bools and 0/1 numbers).
    private static func boolField(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    /// Non-empty string field.
    private static func stringField(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        return nil
    }

    /// Array-of-objects field, empty when absent or of another shape.
    private static func arrayField(_ value: Any?) -> [[String: Any]] {
        if let list = value as? [[String: Any]] { return list }
        if let any = value as? [Any] { return any.compactMap { $0 as? [String: Any] } }
        return []
    }

    /// Static display reason for logs — typed errors only, never bytes.
    private static func reason(_ error: Error) -> String {
        if let typed = error as? OffPeakTicketError {
            switch typed {
            case .missingJWT: "no zcode plan JWT available"
            case .missingCodingPlanKey: "no coding-plan api key available"
            case .envelope(let status, let code, let msg):
                "plane answered HTTP \(status) code \(code.map(String.init) ?? "nil")"
                    + (msg.map { " (\($0))" } ?? "")
            case .malformed(let why): why
            case .exchangeTimeout(let seconds): "exchange exceeded \(seconds) s"
            }
        } else {
            String(describing: error)
        }
    }

    // MARK: - Default execute (real transport)

    /// The production seam implementation: a fresh AsyncHTTPClient per call
    /// on the shared singleton event-loop group (no client singleton, no
    /// network at type initialization), with the WHOLE exchange — head AND
    /// body — raced against the timeout (Task 1's lesson: AHC's execute
    /// deadline cancels when the head arrives, leaving the body read
    /// unbounded; the race closes that gap and cancelling the loser closes
    /// the connection).
    static func defaultExecute(
        request: HTTPClientRequest, body: Data?, timeout: TimeInterval
    ) async throws -> (status: Int, body: Data) {
        var request = request
        if let body {
            request.body = .bytes(ByteBuffer(data: body))
        }
        let client = HTTPClient(eventLoopGroupProvider: .singleton)
        do {
            let result = try await runBounded(client: client, request: request, timeout: timeout)
            try? await client.shutdown()
            return result
        } catch {
            try? await client.shutdown()
            throw error
        }
    }

    /// Race the exchange against the whole-exchange bound.
    private static func runBounded(
        client: HTTPClient, request: HTTPClientRequest, timeout: TimeInterval
    ) async throws -> (status: Int, body: Data) {
        try await withThrowingTaskGroup(of: (status: Int, body: Data).self) { group in
            group.addTask { try await exchange(client: client, request: request, timeout: timeout) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                throw OffPeakTicketError.exchangeTimeout(seconds: Int(timeout))
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw OffPeakTicketError.exchangeTimeout(seconds: Int(timeout))
            }
            return first
        }
    }

    /// The raw exchange: head-phase deadline (belt to the race's braces) and
    /// a bounded body drain.
    private static func exchange(
        client: HTTPClient, request: HTTPClientRequest, timeout: TimeInterval
    ) async throws -> (status: Int, body: Data) {
        let response = try await client.execute(
            request, timeout: .seconds(Int64(max(0, timeout))))
        var data = Data()
        for try await chunk in response.body {
            if data.count + chunk.readableBytes > maxBodyBytes {
                throw OffPeakTicketError.malformed("response body exceeded the 256 KiB bound")
            }
            if let bytes = chunk.getData(at: chunk.readerIndex, length: chunk.readableBytes) {
                data.append(bytes)
            }
        }
        return (Int(response.status.code), data)
    }
}

import Foundation
import OSLog

/// Counter hook the relay path calls once per relayed request; `QuotaService`
/// conforms. A protocol so RelayTarget's context depends on the seam, not the
/// service type.
protocol QuotaRelayCounting: Sendable {
    func noteRelayedRequest()
}

/// Polls the zcode-plan billing endpoints and feeds the router's `quotaBelow`
/// condition (the Task 6 `QuotaSnapshotProviding` seam's real provider) plus
/// Task 9's menu-bar quota bar.
///
/// Wire facts (live-pinned 2026-11-16, docs/zgate-notes.md):
/// - Origin `https://zcode.z.ai`, GET `/api/v1/zcode-plan/billing/balance`
///   and `/billing/current`, query `app_version`.
/// - Auth is the credential store's zcode identity JWT (`zcodejwttoken`) as a
///   plain `Authorization: Bearer` — NOT the relay's minted project token,
///   and no V4 signing quartet (zcode.z.ai 401s every project-token form).
/// - `current` answers 200/code 0 with `data.plans[]` + `data.server_time`
///   (empty `plans` for a coding-plan account like this one).
///   `balance`'s payload schema is pinned from the ZCode.app bundle's own
///   parsers (`data.balances[]` with unit counters, correlated to plans by
///   `user_plan_id`, else `plan_id`); on the capture day the endpoint itself
///   answered HTTP 400 `code 3001 "parameter error"` to every reconstructable
///   request form — parsed defensively so the machinery serves real numbers
///   the moment the request form is pinned.
///
/// Cadence: a background tick loop polls when due — every 30 min since the
/// last attempt, or after every 25th relayed request (`noteRelayedRequest`,
/// called from RelayTarget). All decisions run through `pollIfDue`, which is
/// also the test surface: tests inject the clock and drive the counter — no
/// real timers anywhere near the suite.
///
/// Failure policy: a failed poll keeps the last-known snapshot, sets `stale`
/// (the bar dims), and never blocks proxying — the router independently
/// fail-opens when a snapshot is older than its 2 h staleness limit.
///
/// History: one `quota-history-<date>.json` per day in Application Support
/// (the `token-stats-<date>.json` pattern), entries carry the derived
/// fraction + timestamp only — raw unit counters never touch disk here.
/// Files older than 30 days are pruned on write.
final class QuotaService: QuotaSnapshotProviding, QuotaRelayCounting, @unchecked Sendable {

    // MARK: - Wire shapes

    /// Business envelope both endpoints share (`code`/`msg`/`success`,
    /// sometimes `logid`); `data` presence varies with the endpoint state.
    /// Transient parse result (its raw payload is not Sendable) — consumed
    /// immediately in `performPoll`.
    struct BillingEnvelope {
        var code: Double?
        var success: Bool?
        var msg: String?
        var payload: [String: Any]?

        static func parse(_ data: Data) -> BillingEnvelope? {
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return nil }
            var success: Bool?
            if let value = json["success"] as? NSNumber,
                CFGetTypeID(value) == CFBooleanGetTypeID()
            {
                success = value.boolValue
            }
            return BillingEnvelope(
                code: quotaNumber(json["code"]),
                success: success,
                msg: json["msg"] as? String,
                payload: json["data"] as? [String: Any])
        }

        /// The app's business-success predicate: `success !== false` and
        /// `code` absent/0/200.
        var isBusinessSuccess: Bool {
            if success == false { return false }
            guard let code else { return true }
            return code == 0 || code == 200
        }
    }

    /// Shared plan row (both endpoints carry it).
    struct BillingPlan: Sendable, Equatable {
        var name: String?
        var planID: String?
        var status: String?
        /// Seconds since epoch; a plan whose `ends_at` ≤ `server_time` reads
        /// as expired even when its status says "active" (the app normalizes
        /// exactly this way client-side).
        var endsAtSeconds: Double?
        var userPlanID: String?
    }

    /// `/billing/balance` payload (fields per the app bundle's
    /// `summarizeStartPlanBalances` / `normalizeStartPlanExpiry`).
    struct BillingBalance: Sendable, Equatable {
        var serverTimeSeconds: Double?
        var plans: [BillingPlan]
        var balances: [PlanBalance]

        struct PlanBalance: Sendable, Equatable {
            var entitlementID: String?
            var totalUnits: Double?
            var usedUnits: Double?
            var remainingUnits: Double?
            var availableUnits: Double?
            var reservedUnits: Double?
            var userPlanID: String?
            var planID: String?
        }

        static func parse(_ envelope: BillingEnvelope) -> BillingBalance {
            let payload = envelope.payload ?? [:]
            return BillingBalance(
                serverTimeSeconds: quotaNumber(payload["server_time"]),
                plans: parsePlans(payload["plans"]),
                balances: ((payload["balances"] as? [Any]) ?? []).compactMap { entry in
                    guard let entry = entry as? [String: Any] else { return nil }
                    return PlanBalance(
                        entitlementID: entry["entitlement_id"] as? String,
                        totalUnits: quotaNumber(entry["total_units"]),
                        usedUnits: quotaNumber(entry["used_units"]),
                        remainingUnits: quotaNumber(entry["remaining_units"]),
                        availableUnits: quotaNumber(entry["available_units"]),
                        reservedUnits: quotaNumber(entry["reserved_units"]),
                        userPlanID: entry["user_plan_id"] as? String,
                        planID: entry["plan_id"] as? String)
                })
        }
    }

    /// `/billing/current` payload (live-pinned).
    struct BillingCurrent: Sendable, Equatable {
        var serverTimeSeconds: Double?
        var plans: [BillingPlan]

        static func parse(_ envelope: BillingEnvelope) -> BillingCurrent {
            let payload = envelope.payload ?? [:]
            return BillingCurrent(
                serverTimeSeconds: quotaNumber(payload["server_time"]),
                plans: parsePlans(payload["plans"]))
        }
    }

    private static func parsePlans(_ raw: Any?) -> [BillingPlan] {
        ((raw as? [Any]) ?? []).compactMap { entry in
            guard let entry = entry as? [String: Any] else { return nil }
            return BillingPlan(
                name: entry["name"] as? String,
                planID: entry["plan_id"] as? String,
                status: entry["status"] as? String,
                endsAtSeconds: quotaNumber(entry["ends_at"]),
                userPlanID: entry["user_plan_id"] as? String)
        }
    }

    // MARK: - Configuration

    struct Configuration {
        var origin = "https://zcode.z.ai"
        var session: URLSession = .shared
        /// Poll at least this far apart (timer trigger).
        var pollInterval: TimeInterval = 30 * 60
        /// Poll after this many relayed requests since the last attempt.
        var requestTriggerCount = 25
        /// Background tick that evaluates due-ness (well under `pollInterval`
        /// so the request trigger lands promptly; the tick itself never makes
        /// a poll due — only the interval and the counter do).
        var pollTick: TimeInterval = 60
        /// Query param the app's billing URL helper appends.
        var appVersion = "0.0.0-dev"
        /// History file directory (`quota-history-<date>.json`).
        var historyDirectory = AppPaths.appSupport
        var historyRetention: TimeInterval = 30 * 24 * 3600
        var requestTimeout: TimeInterval = 15
        var now: @Sendable () -> Date = { Date() }

        init() {}
    }

    // MARK: - State

    private let lock = NSLock()
    private var configuration: Configuration
    /// Bearer token for the billing endpoints (the store's zcode identity
    /// JWT). Injected so tests never touch a real store; throws surface the
    /// poll-failure path.
    private let authBearer: @Sendable () async throws -> String
    private let events: QuotaEventChannel?

    private var snapshot: QuotaSnapshot?
    /// True when the last poll attempt failed; the last-known value stays.
    private var stale = false
    private var lastLevel: QuotaLevel?
    private var lastAttemptAt: Date?
    private var relayedSincePoll = 0
    private var pollInFlight = false
    private var pollLoop: Task<Void, Never>?
    private var loopActive = false

    private static let historyFilePrefix = "quota-history-"
    private nonisolated(unsafe) static let historyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    // MARK: - Init

    init(
        configuration: Configuration = Configuration(),
        authBearer: @escaping @Sendable () async throws -> String,
        events: QuotaEventChannel? = nil
    ) {
        self.configuration = configuration
        self.authBearer = authBearer
        self.events = events
    }

    // MARK: - Poll loop

    /// Starts the background due-ness loop. Idempotent; runs for the process
    /// lifetime (billing exists independently of the proxy listener, so
    /// stopping the server does not stop quota polling).
    func startPolling() {
        lock.lock()
        defer { lock.unlock() }
        guard pollLoop == nil else { return }
        loopActive = true
        let tick = configuration.pollTick
        pollLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollIfDue()
                try? await Task.sleep(nanoseconds: UInt64(tick * 1_000_000_000))
            }
        }
    }

    /// Stops the background loop (tests never start it).
    func stopPolling() {
        lock.lock()
        loopActive = false
        let loop = pollLoop
        pollLoop = nil
        lock.unlock()
        loop?.cancel()
    }

    /// The relay path's request counter (RelayTarget calls this once per
    /// relayed request). Crossing `requestTriggerCount` schedules an
    /// immediate poll — only while the loop runs, so tests (which drive
    /// `pollIfDue` directly against the injected counter) stay
    /// deterministic.
    func noteRelayedRequest() {
        lock.lock()
        relayedSincePoll += 1
        let trigger = relayedSincePoll >= configuration.requestTriggerCount && loopActive
        lock.unlock()
        guard trigger else { return }
        Task { [weak self] in
            await self?.pollIfDue()
        }
    }

    /// Polls when due: the last attempt is older than `pollInterval`, or
    /// `requestTriggerCount` requests have been relayed since then.
    func pollIfDue() async {
        lock.lock()
        let due = lastAttemptAt == nil
            || configuration.now().timeIntervalSince(lastAttemptAt!) >= configuration.pollInterval
            || relayedSincePoll >= configuration.requestTriggerCount
        guard due, !pollInFlight else {
            lock.unlock()
            return
        }
        markAttemptLocked()
        lock.unlock()
        await runPoll()
    }

    /// Polls unconditionally (manual refresh; still deduped in-flight).
    func pollNow() async {
        lock.lock()
        guard !pollInFlight else {
            lock.unlock()
            return
        }
        markAttemptLocked()
        lock.unlock()
        await runPoll()
    }

    /// Attempt bookkeeping (caller holds the lock): an attempt consumes both
    /// triggers — the timer window restarts AND the request counter resets,
    /// so "after every 25th relayed request" means per poll, not per process.
    private func markAttemptLocked() {
        lastAttemptAt = configuration.now()
        relayedSincePoll = 0
        pollInFlight = true
    }

    private func runPoll() async {
        defer {
            lock.lock()
            pollInFlight = false
            lock.unlock()
        }
        await performPoll()
    }

    // MARK: - Read surface

    /// The router seam read: last SUCCESSFUL poll's fraction, nil before the
    /// first success (fail-open everywhere downstream).
    func quotaSnapshot() -> QuotaSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    /// True when the last poll attempt failed (UI dims the bar).
    var isStale: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stale
    }

    /// Current threshold band of the last-known fraction (nil = unknown).
    var currentLevel: QuotaLevel? {
        lock.lock()
        defer { lock.unlock() }
        return lastLevel
    }

    // MARK: - Poll

    private func performPoll() async {
        do {
            let bearer = try await authBearer()
            async let balanceBody = get("/api/v1/zcode-plan/billing/balance", bearer: bearer)
            async let currentBody = get("/api/v1/zcode-plan/billing/current", bearer: bearer)
            let (balanceData, currentData) = try await (balanceBody, currentBody)
            guard let balanceEnvelope = BillingEnvelope.parse(balanceData),
                let currentEnvelope = BillingEnvelope.parse(currentData)
            else {
                throw QuotaPollError.malformedResponse
            }
            guard balanceEnvelope.isBusinessSuccess, currentEnvelope.isBusinessSuccess else {
                throw QuotaPollError.businessRejection(
                    code: balanceEnvelope.isBusinessSuccess
                        ? currentEnvelope.code : balanceEnvelope.code,
                    msg: balanceEnvelope.isBusinessSuccess
                        ? currentEnvelope.msg : balanceEnvelope.msg)
            }
            let balance = BillingBalance.parse(balanceEnvelope)
            let current = BillingCurrent.parse(currentEnvelope)
            commit(fraction: Self.remainingFraction(balance: balance, current: current))
        } catch {
            // Keep the last-known value; mark stale. Typed reasons only —
            // a poll failure never carries a credential or balance value.
            lock.lock()
            stale = true
            lock.unlock()
            let reason = (error as? QuotaPollError)?.errorDescription ?? String(describing: error)
            AppLog.stats.warning("[QuotaService] Poll failed (last-known kept, stale): \(reason)")
        }
    }

    /// One billing GET. Envelope/business checks happen after the parse so a
    /// business rejection (HTTP 200 + `code 3001` etc.) follows the same
    /// failure path as a transport error.
    private func get(_ path: String, bearer: String) async throws -> Data {
        guard let base = URL(string: configuration.origin + path) else {
            throw QuotaPollError.malformedResponse
        }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "app_version", value: configuration.appVersion)
        ]
        guard let url = components.url else {
            throw QuotaPollError.malformedResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = configuration.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await configuration.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw QuotaPollError.httpStatus(status)
        }
        return data
    }

    private func commit(fraction: Double?) {
        let now = configuration.now()
        var levelEvents: [(QuotaLevel, QuotaLevel)] = []
        var committed: Double?
        lock.lock()
        if let fraction {
            snapshot = QuotaSnapshot(fractionRemaining: fraction, fetchedAt: now)
            stale = false
            committed = fraction
            let level = QuotaLevel.level(forFraction: fraction)
            if let previous = lastLevel, previous != level {
                levelEvents.append((previous, level))
            }
            lastLevel = level
        }
        // fraction nil = parsed fine but no quota rows apply (today's live
        // truth for this account): keep whatever was known. Not an error, so
        // staleness only clears on a real observed value.
        lock.unlock()

        for (from, to) in levelEvents {
            let channel = events
            Task { @MainActor in
                channel?.emit(.levelChanged(from: from, to: to))
            }
        }
        if let committed {
            appendHistory(fraction: committed, at: now)
        }
    }

    // MARK: - Fraction semantics

    /// Remaining fraction of the billing quota, mirroring the app's own
    /// semantics: plans whose `ends_at` ≤ `server_time` are expired; balances
    /// of expired plans are dropped; the fraction is
    /// `available_units`/`total_units` (falling back to `remaining_units`)
    /// of the surviving balances with a positive total. nil when nothing
    /// applies — callers treat that as "no data" (fail-open), never 0%.
    static func remainingFraction(balance: BillingBalance, current: BillingCurrent) -> Double? {
        let serverTime = balance.serverTimeSeconds ?? current.serverTimeSeconds
        var plans = balance.plans.isEmpty ? current.plans : balance.plans
        if let serverTime {
            plans = plans.map { plan in
                // Active-by-status but past ends_at: expired (app parity).
                if plan.status?.lowercased() == "active",
                    let endsAt = plan.endsAtSeconds, endsAt > 0, endsAt <= serverTime
                {
                    var expired = plan
                    expired.status = "expired"
                    return expired
                }
                return plan
            }
        }
        let livePlans = plans.filter { $0.status?.lowercased() != "expired" }
        let livePlanIDs = Set(livePlans.compactMap(\.planID))
        let liveUserPlanIDs = Set(livePlans.compactMap(\.userPlanID))

        var fractions: [Double] = []
        for entry in balance.balances {
            // Balance→plan correlation: user_plan_id first, else plan_id; a
            // balance with no correlation key counts as plan-less.
            let correlated: Bool
            if let userPlanID = entry.userPlanID, !userPlanID.isEmpty {
                correlated = liveUserPlanIDs.contains(userPlanID)
            } else if let planID = entry.planID, !planID.isEmpty {
                correlated = livePlanIDs.contains(planID)
            } else {
                correlated = true
            }
            guard correlated else { continue }
            guard let total = entry.totalUnits, total > 0 else { continue }
            let remaining = entry.availableUnits ?? entry.remainingUnits ?? 0
            fractions.append(min(max(remaining / total, 0), 1))
        }
        guard !fractions.isEmpty else { return nil }
        return fractions.min()  // the tightest entitlement governs
    }

    // MARK: - History

    private struct HistoryEntry: Codable {
        let timestampMs: Int64
        let fraction: Double
    }

    private struct HistoryFile: Codable {
        var entries: [HistoryEntry]
    }

    private func appendHistory(fraction: Double, at date: Date) {
        let directory = configuration.historyDirectory
        let day = Self.historyDateFormatter.string(from: date)
        let fileURL = directory.appendingPathComponent("\(Self.historyFilePrefix)\(day).json")
        let timestampMs = Int64(date.timeIntervalSince1970 * 1000)

        var file = (try? JSONDecoder().decode(HistoryFile.self, from: (try? Data(contentsOf: fileURL)) ?? Data()))
            ?? HistoryFile(entries: [])
        file.entries.append(HistoryEntry(timestampMs: timestampMs, fraction: fraction))
        pruneHistory(olderThan: date)

        // Best-effort like TokenStatsStore: history is an enhancement, never
        // a failure source for the poll itself. Synchronous (performPoll
        // already runs off-main) so the write is observable immediately.
        if let data = try? JSONEncoder().encode(file) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Deletes `quota-history-*.json` files whose date is older than the
    /// retention window (date parsed from the file NAME, not mtime).
    private func pruneHistory(olderThan now: Date) {
        let cutoff = now.addingTimeInterval(-configuration.historyRetention)
        let fileManager = FileManager.default
        guard
            let names = try? fileManager.contentsOfDirectory(
                atPath: configuration.historyDirectory.path)
        else { return }
        for name in names where name.hasPrefix(Self.historyFilePrefix) && name.hasSuffix(".json") {
            let day = String(name.dropFirst(Self.historyFilePrefix.count).dropLast(".json".count))
            guard let fileDate = Self.historyDateFormatter.date(from: day),
                fileDate < cutoff
            else { continue }
            try? fileManager.removeItem(
                at: configuration.historyDirectory.appendingPathComponent(name))
        }
    }

    // MARK: - Errors

    enum QuotaPollError: Error, LocalizedError {
        case httpStatus(Int)
        case businessRejection(code: Double?, msg: String?)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case let .httpStatus(status):
                return "billing endpoint answered HTTP \(status)"
            case let .businessRejection(code, msg):
                let codeText = code.map { String($0) } ?? "none"
                let msgText = msg.map { " \($0)" } ?? ""
                return "billing business rejection (code \(codeText)\(msgText))"
            case .malformedResponse:
                return "billing response did not match the pinned shape"
            }
        }
    }
}

/// JSON number tolerant of string-encoded values (shared shape with
/// SigningClient's `numberField`).
private func quotaNumber(_ value: Any?) -> Double? {
    if let number = value as? NSNumber { return number.doubleValue }
    if let string = value as? String { return Double(string) }
    return nil
}

import Foundation
import OSLog

/// Counter hook the relay path calls once per relayed request; `QuotaService`
/// conforms. A protocol so RelayTarget's context depends on the seam, not the
/// service type.
protocol QuotaRelayCounting: Sendable {
    func noteRelayedRequest()
}

/// Polls z.ai's official quota monitor and feeds the router's `quotaBelow`
/// condition (the Task 6 `QuotaSnapshotProviding` seam's real provider) plus
/// Task 9's menu-bar quota bar.
///
/// Wire facts (live-verified 2026-11-16):
/// - `GET https://api.z.ai/api/monitor/usage/quota/limit`, auth is a plain
///   `Authorization: Bearer <apiKey>` — the same z.ai API key Claude Code
///   authenticates with (`MonitorAPIKeyReader` reads it from the Claude
///   settings file; only its PATH lives in ZGate's config). The earlier
///   zcode-plan billing endpoints (`zcode.z.ai/api/v1/zcode-plan/billing/*`,
///   identity-JWT auth) are dead for this account — `current` returns empty
///   plans and `balance` 400/3001 in every form (Task 8 probes) — and are
///   gone from this type.
/// - Response: the standard `{code, msg, success, data}` envelope; `data`
///   carries `limits[]` rows `{type, unit, number, percentage, nextResetTime}`
///   and a `level` string. Window identity is `(type, unit, number)`:
///   `TOKENS_LIMIT`+6+1 = weekly tokens (the binding plan quota — the
///   snapshot's fraction), `TOKENS_LIMIT`+3+5 = 5-hour tokens, `TIME_LIMIT` =
///   the monthly MCP window. `percentage` is percent USED; remaining is
///   `100 − percentage`. `nextResetTime` is epoch milliseconds.
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
/// fraction + timestamp only — raw window counters never touch disk here.
/// Files older than 30 days are pruned on write.
final class QuotaService: QuotaSnapshotProviding, QuotaRelayCounting, @unchecked Sendable {

    // MARK: - Wire shapes

    /// Business envelope (`code`/`msg`/`success`); `data` presence varies
    /// with the endpoint state. Transient parse result (its raw payload is
    /// not Sendable) — consumed immediately in `performPoll`.
    struct MonitorEnvelope {
        var code: Double?
        var success: Bool?
        var msg: String?
        var payload: [String: Any]?

        static func parse(_ data: Data) -> MonitorEnvelope? {
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return nil }
            var success: Bool?
            if let value = json["success"] as? NSNumber,
                CFGetTypeID(value) == CFBooleanGetTypeID()
            {
                success = value.boolValue
            }
            return MonitorEnvelope(
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

    /// One `data.limits[]` row: a quota window with its identity triple,
    /// percent used, and reset time (epoch ms).
    struct MonitorLimit: Sendable, Equatable {
        var type: String?
        var unit: Double?
        var number: Double?
        /// Percent of this window already consumed (0...100 nominal).
        var percentage: Double?
        /// Epoch milliseconds of the next reset.
        var nextResetTimeMs: Double?

        static func parse(_ raw: Any?) -> [MonitorLimit] {
            ((raw as? [Any]) ?? []).compactMap { entry in
                guard let entry = entry as? [String: Any] else { return nil }
                return MonitorLimit(
                    type: entry["type"] as? String,
                    unit: quotaNumber(entry["unit"]),
                    number: quotaNumber(entry["number"]),
                    percentage: quotaNumber(entry["percentage"]),
                    nextResetTimeMs: quotaNumber(entry["nextResetTime"]))
            }
        }

        /// The weekly tokens window — the coding plan's binding quota and the
        /// snapshot's source. Identity live-pinned 2026-11-16 (values 6/1;
        /// the plugin ecosystem uses the same discriminator).
        var isWeeklyTokensWindow: Bool {
            type == "TOKENS_LIMIT" && unit == 6 && number == 1
        }
    }

    /// `/usage/quota/limit` payload.
    struct MonitorQuota: Sendable, Equatable {
        var limits: [MonitorLimit]

        static func parse(_ envelope: MonitorEnvelope) -> MonitorQuota {
            MonitorQuota(limits: MonitorLimit.parse(envelope.payload?["limits"]))
        }
    }

    // MARK: - Configuration

    struct Configuration {
        /// Origin of the official quota monitor API family.
        var origin = "https://api.z.ai/api/monitor"
        var session: URLSession = .shared
        /// Poll at least this far apart (timer trigger).
        var pollInterval: TimeInterval = 30 * 60
        /// Poll after this many relayed requests since the last attempt.
        var requestTriggerCount = 25
        /// Background tick that evaluates due-ness (well under `pollInterval`
        /// so the request trigger lands promptly; the tick itself never makes
        /// a poll due — only the interval and the counter do).
        var pollTick: TimeInterval = 60
        /// Path of the Claude Code settings file whose
        /// `env.ANTHROPIC_AUTH_TOKEN` authenticates the monitor endpoint
        /// (config stores the path, never the key — spec §7).
        var claudeSettingsURL = MonitorAPIKeyReader.defaultSettingsURL()
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
    /// API key for the monitor endpoint. Injected so tests never touch a real
    /// settings file; throws surface the poll-failure path. The default
    /// provider reads `configuration.claudeSettingsURL` per poll (picks up key
    /// rotation without a restart; the value is never logged).
    private let apiKeyProvider: @Sendable () async throws -> String
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
    /// UTC-pinned day bucketing: the history FILENAME (and prune boundary)
    /// must be the same on every runner, independent of local timezone.
    private nonisolated(unsafe) static let historyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    // MARK: - Init

    init(
        configuration: Configuration = Configuration(),
        apiKeyProvider: (@Sendable () async throws -> String)? = nil,
        events: QuotaEventChannel? = nil
    ) {
        self.configuration = configuration
        if let apiKeyProvider {
            self.apiKeyProvider = apiKeyProvider
        } else {
            let settingsURL = configuration.claudeSettingsURL
            self.apiKeyProvider = { try MonitorAPIKeyReader.apiKey(at: settingsURL) }
        }
        self.events = events
    }

    // MARK: - Poll loop

    /// Starts the background due-ness loop. Idempotent; runs for the process
    /// lifetime (quota polling exists independently of the proxy listener, so
    /// stopping the server does not stop it).
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
            let key = try await apiKeyProvider()
            let body = try await get("/usage/quota/limit", apiKey: key)
            guard let envelope = MonitorEnvelope.parse(body) else {
                throw QuotaPollError.malformedResponse
            }
            guard envelope.isBusinessSuccess else {
                throw QuotaPollError.businessRejection(code: envelope.code, msg: envelope.msg)
            }
            let quota = MonitorQuota.parse(envelope)
            commit(
                fraction: Self.remainingFraction(limits: quota.limits),
                windows: Self.windows(limits: quota.limits))
        } catch {
            // Keep the last-known value; mark stale. Typed reasons only —
            // a poll failure never carries a credential or usage value.
            lock.lock()
            stale = true
            lock.unlock()
            let reason = (error as? QuotaPollError)?.errorDescription ?? String(describing: error)
            AppLog.stats.warning("[QuotaService] Poll failed (last-known kept, stale): \(reason)")
        }
    }

    /// The monitor GET. Envelope/business checks happen after the parse so a
    /// business rejection (HTTP 200 + non-zero code) follows the same
    /// failure path as a transport error.
    private func get(_ path: String, apiKey: String) async throws -> Data {
        guard let url = URL(string: configuration.origin + path) else {
            throw QuotaPollError.malformedResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = configuration.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await configuration.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw QuotaPollError.httpStatus(status)
        }
        return data
    }

    private func commit(fraction: Double?, windows: [QuotaWindow]) {
        let now = configuration.now()
        var levelEvents: [(QuotaLevel, QuotaLevel)] = []
        var committed: Double?
        lock.lock()
        if let fraction {
            snapshot = QuotaSnapshot(fractionRemaining: fraction, fetchedAt: now, windows: windows)
            stale = false
            committed = fraction
            let level = QuotaLevel.level(forFraction: fraction)
            if let previous = lastLevel, previous != level {
                levelEvents.append((previous, level))
            }
            lastLevel = level
        }
        // fraction nil = parsed fine but no weekly window applies: keep
        // whatever was known. Not an error, so staleness only clears on a
        // real observed value.
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

    /// Remaining fraction of the WEEKLY tokens window (the plan's binding
    /// quota): `(100 − percentage) / 100` clamped to 0...1. nil when no
    /// weekly row applies — callers treat that as "no data" (fail-open),
    /// never 0%.
    static func remainingFraction(limits: [MonitorLimit]) -> Double? {
        guard let weekly = limits.first(where: { $0.isWeeklyTokensWindow }),
            let percentage = weekly.percentage
        else { return nil }
        return clampedRemaining(percentage: percentage)
    }

    /// `(100 − percentage) / 100` clamped to 0...1 — the shared math behind
    /// the weekly fraction and the per-window rows.
    private static func clampedRemaining(percentage: Double) -> Double {
        min(max((100 - percentage) / 100, 0), 1)
    }

    /// Per-window projection for the popover: the three known monitor
    /// windows in canonical display order (weekly, 5-hour, monthly MCP).
    /// Unknown row shapes are dropped; so are rows without a percentage —
    /// no fabricated data. `TIME_LIMIT` is the monthly MCP window whatever
    /// its unit/number; `TOKENS_LIMIT`+3+5 is the 5-hour window.
    static func windows(limits: [MonitorLimit]) -> [QuotaWindow] {
        func fraction(_ limit: MonitorLimit) -> Double? {
            limit.percentage.map { clampedRemaining(percentage: $0) }
        }
        var byKind: [QuotaWindow.Kind: QuotaWindow] = [:]
        for limit in limits {
            let kind: QuotaWindow.Kind
            if limit.isWeeklyTokensWindow {
                kind = .weeklyTokens
            } else if limit.type == "TOKENS_LIMIT" && limit.unit == 3 && limit.number == 5 {
                kind = .fiveHourTokens
            } else if limit.type == "TIME_LIMIT" {
                kind = .monthlyMCP
            } else {
                continue
            }
            guard let fraction = fraction(limit) else { continue }
            byKind[kind] = QuotaWindow(
                kind: kind, fractionRemaining: fraction,
                resetsAt: limit.nextResetTimeMs.map { Date(timeIntervalSince1970: $0 / 1000) })
        }
        let order: [QuotaWindow.Kind] = [.weeklyTokens, .fiveHourTokens, .monthlyMCP]
        return order.compactMap { byKind[$0] }
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
                return "quota monitor answered HTTP \(status)"
            case let .businessRejection(code, msg):
                let codeText = code.map { String($0) } ?? "none"
                let msgText = msg.map { " \($0)" } ?? ""
                return "quota monitor business rejection (code \(codeText)\(msgText))"
            case .malformedResponse:
                return "quota monitor response did not match the pinned shape"
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

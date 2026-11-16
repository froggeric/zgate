import Foundation
import Testing
@testable import ZGate

/// Offline tests for `QuotaService` — monitor poll, threshold levels, and
/// history — driven entirely through a `URLProtocol` mock with a synthetic
/// fixture (`Fixtures/quota-monitor.json`, values synthetic, shape pinned by
/// the live smoke against `api.z.ai/api/monitor/usage/quota/limit`). No real
/// credential or usage value ever loads. The live smoke suite lives at the
/// bottom of this file (env-gated, executor-run).
@Suite(.serialized)
struct QuotaServiceTests {

    // MARK: - Fixture plumbing

    /// Marker class so the test bundle can be located portably.
    private final class BundleToken {}

    /// Committed synthetic fixtures (same lookup order as
    /// CredentialStoreTests: bundle resources first, source tree fallback).
    static func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: BundleToken.self)
        let fileName = "quota-\(name).json"
        let candidates = [
            bundle.resourceURL?.appendingPathComponent("Fixtures").appendingPathComponent(fileName),
            bundle.resourceURL?.appendingPathComponent(fileName),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures").appendingPathComponent(fileName),
        ]
        let url = try #require(candidates.compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.path)
        })
        return try Data(contentsOf: url)
    }

    // MARK: - Mock plumbing

    /// Lock-guarded mutable clock injected as `Configuration.now`.
    private final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant: Date

        init(_ date: Date) { instant = date }

        var now: Date {
            lock.lock(); defer { lock.unlock() }
            return instant
        }

        func advance(_ seconds: TimeInterval) {
            lock.lock(); instant = instant.addingTimeInterval(seconds); lock.unlock()
        }
    }

    /// Serves the monitor endpoint with a synthetic body; the scenario knob
    /// is a plain var (the suite is serialized).
    private final class QuotaMock: @unchecked Sendable {
        private let lock = NSRecursiveLock()
        private var recordedPaths: [String] = []
        /// Overridable response (status, body); default = the fixture.
        var quotaResponse: (Int, Data)?

        func count(pathContaining marker: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return recordedPaths.filter { $0.contains(marker) }.count
        }

        func respond(path: String) throws -> (Int, Data) {
            lock.lock()
            recordedPaths.append(path)
            let quota = quotaResponse
            lock.unlock()
            if path.contains("/usage/quota/limit") {
                if let quota { return quota }
                return (200, try QuotaServiceTests.fixture("monitor"))
            }
            throw NSError(domain: "QuotaMock", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "unexpected path \(path)"])
        }
    }

    private final class QuotaURLProtocol: URLProtocol {
        nonisolated(unsafe) static var mock: QuotaMock?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let mock = Self.mock, let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            do {
                let (status, body) = try mock.respond(path: url.path + (url.query.map { "?\($0)" } ?? ""))
                let response = HTTPURLResponse(
                    url: url, statusCode: status, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    // MARK: - Helpers

    private static let baseDate = Date(timeIntervalSince1970: 1_763_000_000)

    private func makeService(
        clock: ManualClock,
        historyDirectory: URL? = nil,
        key: (@Sendable () async throws -> String)? = nil,
        events: QuotaEventChannel? = nil
    ) throws -> QuotaService {
        var configuration = QuotaService.Configuration()
        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [QuotaURLProtocol.self]
        configuration.session = URLSession(configuration: urlSessionConfiguration)
        configuration.now = { clock.now }
        // Tests never write to the real Application Support — the injected
        // temp dir is cleaned up per-test.
        configuration.historyDirectory = try historyDirectory ?? makeHistoryDirectory()
        return QuotaService(
            configuration: configuration,
            apiKeyProvider: key ?? { "synthetic-api-key" },
            events: events)
    }

    private func installMock(_ mock: QuotaMock) {
        QuotaURLProtocol.mock = mock
    }

    private func makeHistoryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zgate-quota-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A synthetic monitor body: the weekly window at `weeklyUsed` percent,
    /// plus 5h/MCP rows (values synthetic).
    private func monitorBody(weeklyUsed: Int, stringEncoded: Bool = false) throws -> Data {
        func limit(_ type: String, unit: Int, number: Int, percentage: Any, reset: Int) -> [String: Any] {
            [
                "type": type,
                "unit": unit,
                "number": number,
                "percentage": percentage,
                "nextResetTime": reset,
            ]
        }
        let weeklyPercentage: Any = stringEncoded ? String(weeklyUsed) : weeklyUsed
        return try JSONSerialization.data(withJSONObject: [
            "code": 0,
            "msg": "Operation successful",
            "success": true,
            "data": [
                "level": "max",
                "limits": [
                    limit("TOKENS_LIMIT", unit: 3, number: 5, percentage: 40, reset: 1_763_000_000_000),
                    limit("TOKENS_LIMIT", unit: 6, number: 1, percentage: weeklyPercentage, reset: 1_763_691_200_000),
                    limit("TIME_LIMIT", unit: 5, number: 1, percentage: 1, reset: 1_765_505_600_000),
                ],
            ],
        ])
    }

    /// Lets @MainActor emission tasks (spawned by `commit`) run before an
    /// assertion reads the channel.
    private func drainEmissions() async {
        for _ in 0..<20 { await Task.yield() }
    }

    // MARK: - Parsers

    @Test func monitorFixtureParsesToPinnedShape() throws {
        let envelope = try #require(
            QuotaService.MonitorEnvelope.parse(try Self.fixture("monitor")))
        #expect(envelope.isBusinessSuccess)

        let quota = QuotaService.MonitorQuota.parse(envelope)
        #expect(quota.limits.count == 3)

        let fiveHour = quota.limits[0]
        #expect(fiveHour.type == "TOKENS_LIMIT")
        #expect(fiveHour.unit == 3)
        #expect(fiveHour.number == 5)
        #expect(fiveHour.percentage == 40)
        #expect(fiveHour.nextResetTimeMs == 1_763_000_000_000)
        #expect(!fiveHour.isWeeklyTokensWindow)

        let weekly = quota.limits[1]
        #expect(weekly.type == "TOKENS_LIMIT")
        #expect(weekly.unit == 6)
        #expect(weekly.number == 1)
        #expect(weekly.percentage == 25)
        #expect(weekly.nextResetTimeMs == 1_763_691_200_000)
        #expect(weekly.isWeeklyTokensWindow)

        #expect(quota.limits[2].type == "TIME_LIMIT")
        #expect(!quota.limits[2].isWeeklyTokensWindow)
    }

    @Test func envelopeSuccessPredicateMirrorsTheApp() throws {
        func envelope(code: Double?, success: Bool?) -> QuotaService.MonitorEnvelope {
            QuotaService.MonitorEnvelope(code: code, success: success, msg: nil, payload: [:])
        }
        #expect(envelope(code: nil, success: nil).isBusinessSuccess)
        #expect(envelope(code: 0, success: nil).isBusinessSuccess)
        #expect(envelope(code: 200, success: true).isBusinessSuccess)
        #expect(!envelope(code: 3001, success: nil).isBusinessSuccess)
        #expect(!envelope(code: 0, success: false).isBusinessSuccess)
    }

    @Test func weeklyWindowGovernsRemainingFraction() throws {
        let envelope = try #require(
            QuotaService.MonitorEnvelope.parse(try Self.fixture("monitor")))
        let fraction = QuotaService.remainingFraction(
            limits: QuotaService.MonitorQuota.parse(envelope).limits)
        // Fixture weekly window: 25% used → 75% remaining. The 5h window at
        // 40% used must NOT govern.
        #expect(fraction == 0.75)
    }

    @Test func remainingFractionClampsAndToleratesStringNumbers() throws {
        func fraction(weeklyUsed: Int, stringEncoded: Bool = false) throws -> Double? {
            let envelope = try #require(
                QuotaService.MonitorEnvelope.parse(try monitorBody(weeklyUsed: weeklyUsed, stringEncoded: stringEncoded)))
            return QuotaService.remainingFraction(
                limits: QuotaService.MonitorQuota.parse(envelope).limits)
        }
        #expect(try fraction(weeklyUsed: 0) == 1.0)
        #expect(try fraction(weeklyUsed: 130) == 0.0)
        #expect(try fraction(weeklyUsed: -5) == 1.0)
        #expect(try fraction(weeklyUsed: 63) == 0.37)
        // JSON numbers sometimes arrive string-encoded (quotaNumber parity
        // with SigningClient's numberField).
        #expect(try fraction(weeklyUsed: 63, stringEncoded: true) == 0.37)
    }

    @Test func missingWeeklyRowIsNil() throws {
        let envelope = try #require(QuotaService.MonitorEnvelope.parse(
            try JSONSerialization.data(withJSONObject: [
                "code": 0, "msg": "", "success": true,
                "data": ["limits": [["type": "TIME_LIMIT", "unit": 5, "number": 1, "percentage": 1]]],
            ])))
        #expect(QuotaService.remainingFraction(
            limits: QuotaService.MonitorQuota.parse(envelope).limits) == nil)
        #expect(QuotaService.remainingFraction(limits: []) == nil)
    }

    // MARK: - Poll + cadence

    @Test func pollPublishesSnapshotAndHistory() async throws {
        let mock = QuotaMock()
        installMock(mock)
        let clock = ManualClock(Self.baseDate)
        let history = try makeHistoryDirectory()
        defer { try? FileManager.default.removeItem(at: history) }
        let service = try makeService(clock: clock, historyDirectory: history)

        #expect(service.quotaSnapshot() == nil)
        await service.pollIfDue()
        #expect(mock.count(pathContaining: "/usage/quota/limit") == 1)

        let snapshot = try #require(service.quotaSnapshot())
        #expect(snapshot.fractionRemaining == 0.75)
        #expect(snapshot.fetchedAt == clock.now)
        #expect(!service.isStale)
        #expect(service.currentLevel == .normal)

        // The formatter is UTC-pinned, so the filename day is runner-TZ-independent.
        let day = "2025-11-13"  // 1_763_000_000 = 2025-11-13T01:46:40Z
        let fileURL = history.appendingPathComponent("quota-history-\(day).json")
        let data = try #require(try? Data(contentsOf: fileURL))
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try #require(object["entries"] as? [[String: Any]])
        #expect(entries.count == 1)
        #expect(entries[0]["fraction"] as? Double == 0.75)
    }

    @Test func timerCadenceGatesPolls() async throws {
        let mock = QuotaMock()
        installMock(mock)
        let clock = ManualClock(Self.baseDate)
        let service = try makeService(clock: clock)

        await service.pollIfDue()
        #expect(mock.count(pathContaining: "/usage/quota/limit") == 1)

        // 29 min later: not due.
        clock.advance(29 * 60)
        await service.pollIfDue()
        #expect(mock.count(pathContaining: "/usage/quota/limit") == 1)

        // Past the 30 min interval: due again.
        clock.advance(2 * 60)
        await service.pollIfDue()
        #expect(mock.count(pathContaining: "/usage/quota/limit") == 2)
    }

    @Test func requestCounterTriggersPollAndResets() async throws {
        let mock = QuotaMock()
        installMock(mock)
        let clock = ManualClock(Self.baseDate)
        let service = try makeService(clock: clock)

        // Baseline poll (no attempt yet → immediately due).
        await service.pollIfDue()
        #expect(mock.count(pathContaining: "/usage/quota/limit") == 1)

        // 24 relayed requests (loop NOT started — pure counting, no spawns):
        // under the trigger, interval not passed → no new poll.
        for _ in 0..<24 { service.noteRelayedRequest() }
        await service.pollIfDue()
        #expect(mock.count(pathContaining: "/usage/quota/limit") == 1)

        // The 25th makes the next pollIfDue due; the poll resets the counter.
        service.noteRelayedRequest()
        await service.pollIfDue()
        #expect(mock.count(pathContaining: "/usage/quota/limit") == 2)

        // Counter reset and interval not passed: not due again.
        await service.pollIfDue()
        #expect(mock.count(pathContaining: "/usage/quota/limit") == 2)
    }

    // MARK: - Levels

    @Test @MainActor func thresholdCrossingEmitsLevelEventsOnlyOnChange() async throws {
        let mock = QuotaMock()
        installMock(mock)
        let clock = ManualClock(Self.baseDate)
        let events = QuotaEventChannel()
        let service = try makeService(clock: clock, events: events)

        func setWeeklyUsed(_ percent: Int) throws {
            mock.quotaResponse = (200, try monitorBody(weeklyUsed: percent))
        }

        // 50% used = 50% remaining — baseline, no event (first observation
        // is silent).
        try setWeeklyUsed(50)
        await service.pollNow()
        await drainEmissions()
        #expect(events.events.isEmpty)

        // 76% used = 24% remaining — crosses into warning, one event.
        try setWeeklyUsed(76)
        await service.pollNow()
        await drainEmissions()
        #expect(events.events == [.levelChanged(from: .normal, to: .warning)])

        // 80% used = 20% remaining — same band, no event (crossing
        // detection, not per-poll spam).
        try setWeeklyUsed(80)
        await service.pollNow()
        await drainEmissions()
        #expect(events.events.count == 1)

        // 91% used = 9% remaining — critical.
        try setWeeklyUsed(91)
        await service.pollNow()
        await drainEmissions()
        #expect(events.events.count == 2)
        #expect(events.events.last == .levelChanged(from: .warning, to: .critical))

        // Recovery to 40% used = 60% remaining — back to normal.
        try setWeeklyUsed(40)
        await service.pollNow()
        await drainEmissions()
        #expect(events.events.count == 3)
        #expect(events.events.last == .levelChanged(from: .critical, to: .normal))
        #expect(service.currentLevel == .normal)
    }

    // MARK: - Failure policy

    @Test func pollFailureKeepsLastKnownAndSetsStale() async throws {
        let mock = QuotaMock()
        installMock(mock)
        let clock = ManualClock(Self.baseDate)
        let service = try makeService(clock: clock)

        await service.pollIfDue()
        let snapshot = try #require(service.quotaSnapshot())
        #expect(!service.isStale)

        // Transport failure on the next due poll: value kept, stale set.
        mock.quotaResponse = (500, Data("{}".utf8))
        clock.advance(31 * 60)
        await service.pollIfDue()
        #expect(service.isStale)
        let kept = try #require(service.quotaSnapshot())
        #expect(kept == snapshot)

        // Recovery clears stale.
        mock.quotaResponse = nil
        clock.advance(31 * 60)
        await service.pollIfDue()
        #expect(!service.isStale)
        #expect(service.quotaSnapshot()?.fractionRemaining == 0.75)
    }

    @Test func businessRejectionIsAFailure() async throws {
        let mock = QuotaMock()
        installMock(mock)
        // HTTP 200 + failed business envelope.
        mock.quotaResponse = (
            200,
            try JSONSerialization.data(withJSONObject: [
                "code": 3001, "msg": "parameter error", "success": false,
            ])
        )
        let clock = ManualClock(Self.baseDate)
        let service = try makeService(clock: clock)

        await service.pollIfDue()
        #expect(service.quotaSnapshot() == nil)
        #expect(service.isStale)
    }

    @Test func authFailureSurfacesStaleWithoutRequests() async throws {
        let mock = QuotaMock()
        installMock(mock)
        let clock = ManualClock(Self.baseDate)
        let service = try makeService(clock: clock, key: {
            throw MonitorAPIKeyReader.ReaderError.absent(path: "synthetic")
        })

        await service.pollIfDue()
        #expect(service.quotaSnapshot() == nil)
        #expect(service.isStale)
        #expect(mock.count(pathContaining: "/usage/quota/limit") == 0)
    }

    // MARK: - Key reader

    @Test func apiKeyReaderReturnsEnvToken() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zgate-keyreader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: [
            "env": ["ANTHROPIC_AUTH_TOKEN": "sk-synthetic-key"],
        ]).write(to: url)
        #expect(try MonitorAPIKeyReader.apiKey(at: url) == "sk-synthetic-key")
    }

    @Test func apiKeyReaderThrowsWithoutValueOrFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zgate-keyreader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // No env block → malformed.
        let malformed = directory.appendingPathComponent("malformed.json")
        try JSONSerialization.data(withJSONObject: ["model": "x"]).write(to: malformed)
        #expect(throws: MonitorAPIKeyReader.ReaderError.malformed(path: malformed.path)) {
            _ = try MonitorAPIKeyReader.apiKey(at: malformed)
        }

        // env present but no token → absent.
        let absent = directory.appendingPathComponent("absent.json")
        try JSONSerialization.data(withJSONObject: ["env": ["OTHER": "x"]]).write(to: absent)
        #expect(throws: MonitorAPIKeyReader.ReaderError.absent(path: absent.path)) {
            _ = try MonitorAPIKeyReader.apiKey(at: absent)
        }

        // Missing file → unreadable.
        let missing = directory.appendingPathComponent("missing.json")
        #expect(throws: MonitorAPIKeyReader.ReaderError.unreadable(path: missing.path)) {
            _ = try MonitorAPIKeyReader.apiKey(at: missing)
        }
    }

    // MARK: - History pruning

    @Test func historyPrunesFilesOlderThanThirtyDays() async throws {
        let mock = QuotaMock()
        installMock(mock)
        let clock = ManualClock(Self.baseDate)
        let history = try makeHistoryDirectory()
        defer { try? FileManager.default.removeItem(at: history) }

        let ancient = history.appendingPathComponent("quota-history-2020-01-01.json")
        try Data("{}".utf8).write(to: ancient)
        let recent = history.appendingPathComponent("quota-history-2025-10-15.json")
        try Data("{}".utf8).write(to: recent)
        let unrelated = history.appendingPathComponent("token-stats-2020-01-01.json")
        try Data("{}".utf8).write(to: unrelated)

        let service = try makeService(clock: clock, historyDirectory: history)
        await service.pollIfDue()

        let fileManager = FileManager.default
        func exists(_ url: URL) -> Bool { fileManager.fileExists(atPath: url.path) }
        #expect(!exists(ancient))  // > 30 days: pruned
        #expect(exists(recent))  // 29 days: kept
        #expect(exists(unrelated))  // different prefix: never touched
    }
}

/// Live smoke (executor-run, never CI): one authenticated fetch against
/// `api.z.ai/api/monitor/usage/quota/limit` (live-verified 2026-11-16; auth =
/// the z.ai API key from the Claude settings file, plain Bearer) plus one
/// end-to-end poll through the real service. Prints status, byte count, and
/// the response SHAPE — field names and JSON types only; no value (percent,
/// token, id) is ever printed or stored.
@Suite(.serialized)
struct QuotaServiceLiveSmokeTests {

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZGATE_LIVE_SMOKE"] == "1"))
    func liveMonitorFetchAndPoll() async throws {
        let fileManager = FileManager.default

        // The key travels only inside the closure; errors report paths only.
        let settingsURL = MonitorAPIKeyReader.defaultSettingsURL()
        let key = try MonitorAPIKeyReader.apiKey(at: settingsURL)

        var request = URLRequest(url: URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        print("[zgate-smoke] monitor status=\(status) bytes=\(data.count) auth=bearer-claude-settings-key@api.z.ai")
        #expect(status == 200, "monitor fetch failed — key or origin regressed")

        if let json = try? JSONSerialization.jsonObject(with: data) {
            printShape(json, indent: "monitor ")
        }

        // End-to-end: the production service, real config, injected history
        // dir (the default key provider reads the real settings file).
        // Outcome state only (stale / has-snapshot), never a value.
        let historyDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("zgate-quota-smoke-\(UUID().uuidString)", isDirectory: true)
        var configuration = QuotaService.Configuration()
        configuration.historyDirectory = historyDirectory
        let service = QuotaService(configuration: configuration)
        await service.pollNow()
        let stale = service.isStale
        let hasSnapshot = service.quotaSnapshot() != nil
        print("[zgate-smoke] service pollNow stale=\(stale) hasSnapshot=\(hasSnapshot)")
    }
}

/// Shape printer shared by the live smoke — keys and JSON types only.
private func printShape(_ value: Any, indent: String) {
    if let dict = value as? [String: Any] {
        if dict.isEmpty { print("[zgate-smoke] \(indent){}") }
        for (key, child) in dict.sorted(by: { $0.key < $1.key }) {
            print("[zgate-smoke] \(indent)\(key): \(jsonTypeName(child))")
            if child is [String: Any] || child is [Any] {
                printShape(child, indent: indent + "  ")
            }
        }
    } else if let array = value as? [Any] {
        print("[zgate-smoke] \(indent)[\(array.count) items]")
        if let first = array.first {
            printShape(first, indent: indent + "  ")
        }
    } else {
        print("[zgate-smoke] \(indent)\(jsonTypeName(value))")
    }
}

private func jsonTypeName(_ value: Any) -> String {
    if value is NSNull { return "null" }
    if let number = value as? NSNumber {
        // JSON bools arrive as CFBoolean; plain numbers bridge to Bool
        // too, so the type-ID check must come first.
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return "bool" }
        if String(cString: number.objCType) == "d" { return "double" }
        return "int"
    }
    if value is String { return "string" }
    if value is [String: Any] { return "object" }
    if value is [Any] { return "array" }
    return "unknown"
}

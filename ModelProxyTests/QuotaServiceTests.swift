import Foundation
import Testing
@testable import ZGate

/// Offline tests for `QuotaService` — billing poll, threshold levels, and
/// history — driven entirely through a `URLProtocol` mock with synthetic
/// fixtures (`Fixtures/quota-balance.json` / `quota-current.json`, values
/// synthetic, shapes pinned by the live smoke). No real credential or
/// balance value ever loads. The live smoke suite lives at the bottom of
/// this file (env-gated, executor-run).
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

    /// Serves the two billing endpoints with synthetic bodies; scenario knobs
    /// are plain vars (the suite is serialized).
    private final class QuotaMock: @unchecked Sendable {
        private let lock = NSRecursiveLock()
        private var recordedPaths: [String] = []
        /// Overridable responses (status, body); default = the fixtures.
        var balanceResponse: (Int, Data)?
        var currentResponse: (Int, Data)?

        func count(pathContaining marker: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return recordedPaths.filter { $0.contains(marker) }.count
        }

        func respond(path: String) throws -> (Int, Data) {
            lock.lock()
            recordedPaths.append(path)
            let balance = balanceResponse
            let current = currentResponse
            lock.unlock()
            if path.contains("/billing/balance") {
                if let balance { return balance }
                return (200, try QuotaServiceTests.fixture("balance"))
            }
            if path.contains("/billing/current") {
                if let current { return current }
                return (200, try QuotaServiceTests.fixture("current"))
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
        auth: (@Sendable () async throws -> String)? = nil,
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
            authBearer: auth ?? { "synthetic-bearer" },
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

    /// A synthetic balance body with a configurable remaining fraction (one
    /// active plan, one balance row; values synthetic).
    private func balanceBody(availableUnits: Int, totalUnits: Int) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "code": 0,
            "msg": "",
            "success": true,
            "data": [
                "server_time": 1_763_000_000,
                "plans": [[
                    "name": "Synthetic Plan",
                    "plan_id": "start-plan-synthetic-001",
                    "status": "active",
                    "ends_at": 4_102_444_800,
                    "user_plan_id": "up-synthetic-001",
                ]],
                "balances": [[
                    "entitlement_id": "ent-synthetic-001",
                    "show_name": "Synthetic Units",
                    "total_units": totalUnits,
                    "used_units": totalUnits - availableUnits,
                    "remaining_units": availableUnits,
                    "available_units": availableUnits,
                    "reserved_units": 0,
                    "user_plan_id": "up-synthetic-001",
                    "plan_id": "start-plan-synthetic-001",
                ]],
            ],
        ])
    }

    /// Lets @MainActor emission tasks (spawned by `commit`) run before an
    /// assertion reads the channel.
    private func drainEmissions() async {
        for _ in 0..<20 { await Task.yield() }
    }

    // MARK: - Parsers

    @Test func fixturesParseToPinnedShapes() throws {
        let balanceEnvelope = try #require(
            QuotaService.BillingEnvelope.parse(try Self.fixture("balance")))
        let currentEnvelope = try #require(
            QuotaService.BillingEnvelope.parse(try Self.fixture("current")))
        #expect(balanceEnvelope.isBusinessSuccess)
        #expect(currentEnvelope.isBusinessSuccess)

        let balance = QuotaService.BillingBalance.parse(balanceEnvelope)
        let current = QuotaService.BillingCurrent.parse(currentEnvelope)

        #expect(balance.serverTimeSeconds == 1_763_000_000)
        #expect(balance.plans.count == 2)
        #expect(balance.balances.count == 2)
        #expect(balance.balances[0].totalUnits == 1000)
        #expect(balance.balances[0].availableUnits == 750)

        #expect(current.serverTimeSeconds == 1_763_000_000)
        #expect(current.plans.count == 1)
        #expect(current.plans[0].status == "active")
        #expect(current.plans[0].endsAtSeconds == 4_102_444_800)
    }

    @Test func envelopeSuccessPredicateMirrorsTheApp() throws {
        func envelope(code: Double?, success: Bool?) -> QuotaService.BillingEnvelope {
            QuotaService.BillingEnvelope(code: code, success: success, msg: nil, payload: [:])
        }
        #expect(envelope(code: nil, success: nil).isBusinessSuccess)
        #expect(envelope(code: 0, success: nil).isBusinessSuccess)
        #expect(envelope(code: 200, success: true).isBusinessSuccess)
        #expect(!envelope(code: 3001, success: nil).isBusinessSuccess)
        #expect(!envelope(code: 0, success: false).isBusinessSuccess)
    }

    @Test func remainingFractionDropsExpiredPlanBalances() throws {
        // The fixture's second balance belongs to a plan whose ends_at is
        // already past server_time — expired client-side (app parity), so
        // only the 750/1000 row governs.
        let balanceEnvelope = try #require(
            QuotaService.BillingEnvelope.parse(try Self.fixture("balance")))
        let currentEnvelope = try #require(
            QuotaService.BillingEnvelope.parse(try Self.fixture("current")))
        let fraction = QuotaService.remainingFraction(
            balance: QuotaService.BillingBalance.parse(balanceEnvelope),
            current: QuotaService.BillingCurrent.parse(currentEnvelope))
        #expect(fraction == 0.75)
    }

    @Test func remainingFractionNilWithoutBalances() throws {
        let empty = QuotaService.BillingBalance(
            serverTimeSeconds: 1_763_000_000, plans: [], balances: [])
        let current = QuotaService.BillingCurrent(
            serverTimeSeconds: 1_763_000_000, plans: [])
        #expect(QuotaService.remainingFraction(balance: empty, current: current) == nil)
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
        #expect(mock.count(pathContaining: "/billing/balance") == 1)
        #expect(mock.count(pathContaining: "/billing/current") == 1)

        let snapshot = try #require(service.quotaSnapshot())
        #expect(snapshot.fractionRemaining == 0.75)
        #expect(snapshot.fetchedAt == clock.now)
        #expect(!service.isStale)
        #expect(service.currentLevel == .normal)

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
        #expect(mock.count(pathContaining: "/billing/balance") == 1)

        // 29 min later: not due.
        clock.advance(29 * 60)
        await service.pollIfDue()
        #expect(mock.count(pathContaining: "/billing/balance") == 1)

        // Past the 30 min interval: due again.
        clock.advance(2 * 60)
        await service.pollIfDue()
        #expect(mock.count(pathContaining: "/billing/balance") == 2)
    }

    @Test func requestCounterTriggersPollAndResets() async throws {
        let mock = QuotaMock()
        installMock(mock)
        let clock = ManualClock(Self.baseDate)
        let service = try makeService(clock: clock)

        // Baseline poll (no attempt yet → immediately due).
        await service.pollIfDue()
        #expect(mock.count(pathContaining: "/billing/balance") == 1)

        // 24 relayed requests (loop NOT started — pure counting, no spawns):
        // under the trigger, interval not passed → no new poll.
        for _ in 0..<24 { service.noteRelayedRequest() }
        await service.pollIfDue()
        #expect(mock.count(pathContaining: "/billing/balance") == 1)

        // The 25th makes the next pollIfDue due; the poll resets the counter.
        service.noteRelayedRequest()
        await service.pollIfDue()
        #expect(mock.count(pathContaining: "/billing/balance") == 2)

        // Counter reset and interval not passed: not due again.
        await service.pollIfDue()
        #expect(mock.count(pathContaining: "/billing/balance") == 2)
    }

    // MARK: - Levels

    @Test @MainActor func thresholdCrossingEmitsLevelEventsOnlyOnChange() async throws {
        let mock = QuotaMock()
        installMock(mock)
        let clock = ManualClock(Self.baseDate)
        let events = QuotaEventChannel()
        let service = try makeService(clock: clock, events: events)

        func setFraction(_ available: Int, _ total: Int) throws {
            mock.balanceResponse = (200, try balanceBody(availableUnits: available, totalUnits: total))
        }

        // 50% — baseline, no event (first observation is silent).
        try setFraction(500, 1000)
        await service.pollNow()
        await drainEmissions()
        #expect(events.events.isEmpty)

        // 24% — crosses into warning, one event.
        try setFraction(240, 1000)
        await service.pollNow()
        await drainEmissions()
        #expect(events.events == [.levelChanged(from: .normal, to: .warning)])

        // 20% — same band, no event (crossing detection, not per-poll spam).
        try setFraction(200, 1000)
        await service.pollNow()
        await drainEmissions()
        #expect(events.events.count == 1)

        // 9% — critical.
        try setFraction(90, 1000)
        await service.pollNow()
        await drainEmissions()
        #expect(events.events.count == 2)
        #expect(events.events.last == .levelChanged(from: .warning, to: .critical))

        // Recovery to 60% — back to normal.
        try setFraction(600, 1000)
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
        mock.balanceResponse = (500, Data("{}".utf8))
        clock.advance(31 * 60)
        await service.pollIfDue()
        #expect(service.isStale)
        let kept = try #require(service.quotaSnapshot())
        #expect(kept == snapshot)

        // Recovery clears stale.
        mock.balanceResponse = nil
        clock.advance(31 * 60)
        await service.pollIfDue()
        #expect(!service.isStale)
        #expect(service.quotaSnapshot()?.fractionRemaining == 0.75)
    }

    @Test func businessRejectionIsAFailure() async throws {
        let mock = QuotaMock()
        installMock(mock)
        // HTTP 200 + code 3001: the live-observed balance answer today.
        mock.balanceResponse = (
            200,
            try JSONSerialization.data(withJSONObject: [
                "code": 3001, "msg": "parameter error", "success": false,
            ])
        )
        installMock(mock)
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
        let service = try makeService(clock: clock, auth: {
            throw CredentialError.notFound(path: "synthetic")
        })

        await service.pollIfDue()
        #expect(service.quotaSnapshot() == nil)
        #expect(service.isStale)
        #expect(mock.count(pathContaining: "/billing/") == 0)
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

/// Live smoke (executor-run, never CI): one authenticated balance + current
/// fetch against zcode.z.ai. Auth pinned live 2026-11-16 (probe matrix + the
/// ZCode.app bundle's own billing client, recorded in zgate-notes): billing
/// takes the STORE's zcode identity JWT (`zcodejwttoken`) as a plain
/// `Authorization: Bearer` — NOT the minted project token, and no signing
/// quartet (zcode.z.ai 401s every project-token form). Enabled only when
/// `ZGATE_LIVE_SMOKE=1` reaches the test host (`TEST_RUNNER_` prefix through
/// xcodebuild, the Task 4 pattern). Prints status, byte count, and the
/// response SHAPE — field names and JSON types only; no value (balance,
/// token, id) is ever printed or stored.
@Suite(.serialized)
struct QuotaServiceLiveSmokeTests {

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZGATE_LIVE_SMOKE"] == "1"))
    func liveBalanceAndCurrentFetch() async throws {
        let fileManager = FileManager.default
        let scratchHome = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".zcode-scratch-v3", isDirectory: true)
        // Billing auth = the store's zcode identity JWT (read programmatically
        // via CredentialStore; never printed).
        let store = try #require(try CredentialStore(scratchHome: scratchHome))
        let zcodeJwt = try store.zcodeJwtToken()

        let session = URLSession.shared
        let origin = "https://zcode.z.ai"
        // The app's billing URL helper appends `app_version` (bundle parity;
        // wire.log shows the CLI sending `0.0.0-dev` on zcode.z.ai).
        let appVersion = "0.0.0-dev"

        /// GET one billing endpoint with explicit query items.
        func get(_ path: String, query: [String: String]) async throws -> (Int, Any?, Int) {
            var components = URLComponents(url: URL(string: origin + path)!, resolvingAgainstBaseURL: false)!
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            var request = URLRequest(url: components.url!)
            request.httpMethod = "GET"
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(zcodeJwt)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (status, try? JSONSerialization.jsonObject(with: data), data.count)
        }

        /// Prints the response shape — keys and JSON types only, never values.
        /// Arrays print their length and the first element's shape. Every
        /// line carries the smoke prefix so no filter can drop it.
        func printShape(_ value: Any, indent: String) {
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
        func jsonTypeName(_ value: Any) -> String {
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

        // Lean permanent smoke (discovery matrix preserved in
        // docs/zgate-notes.md): one evidence fetch per endpoint, then one
        // end-to-end poll through the real service. `current` is the stable
        // one (assert 200); `balance`'s live answer is recorded, not
        // asserted, until its request form is pinned.
        let balanceEvidence = try await get(
            "/api/v1/zcode-plan/billing/balance", query: ["app_version": appVersion])
        print("[zgate-smoke] balance status=\(balanceEvidence.0) bytes=\(balanceEvidence.2) auth=bearer-zcodejwttoken@zcode.z.ai")
        if let envelope = balanceEvidence.1 as? [String: Any] {
            let code = (envelope["code"] as? NSNumber)?.intValue.description ?? "-"
            let msg = (envelope["msg"] as? String) ?? "-"
            print("[zgate-smoke] balance envelope code=\(code) msg=\(msg)")
            printShape(envelope, indent: "balance ")
        }

        let currentEvidence = try await get(
            "/api/v1/zcode-plan/billing/current", query: ["app_version": appVersion])
        print("[zgate-smoke] current status=\(currentEvidence.0) bytes=\(currentEvidence.2) auth=bearer-zcodejwttoken@zcode.z.ai")
        if currentEvidence.0 == 200, let currentJson = currentEvidence.1 {
            printShape(currentJson, indent: "current ")
        }
        #expect(currentEvidence.0 == 200, "current fetch failed — auth or origin regressed")

        // End-to-end: the production service, real config, injected history
        // dir. Outcome state only (stale / has-snapshot), never a value.
        let historyDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("zgate-quota-smoke-\(UUID().uuidString)", isDirectory: true)
        var configuration = QuotaService.Configuration()
        configuration.historyDirectory = historyDirectory
        let service = QuotaService(
            configuration: configuration, authBearer: { try store.zcodeJwtToken() })
        await service.pollNow()
        let stale = service.isStale
        let hasSnapshot = service.quotaSnapshot() != nil
        print("[zgate-smoke] service pollNow stale=\(stale) hasSnapshot=\(hasSnapshot)")
    }
}

import AsyncHTTPClient
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOHTTP1
import NIOPosix
import Testing
@testable import ZGate

/// Task 6 — the conditional router: model-class patterns, time/quota/health
/// conditions, terminal fallback, and the server-layer relay-signing wiring.
/// All evaluation is offline: fixed dates, fake seams, synthetic vendors.
@MainActor
@Suite(.serialized)
struct RouterTests {

    // MARK: - Fixtures

    private enum Paris {
        static let zone = TimeZone(identifier: "Europe/Paris")!
        /// 2026-11-09 is a Monday, 2026-11-14 a Saturday.
        static func date(_ ymd: (Int, Int, Int), _ hm: (Int, Int)) -> Date {
            var comps = DateComponents()
            comps.year = ymd.0; comps.month = ymd.1; comps.day = ymd.2
            comps.hour = hm.0; comps.minute = hm.1
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            return calendar.date(from: comps)!
        }
    }

    private final class FakeHealth: TargetHealthProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [UUID: Date] = [:]
        func setLastSuccess(_ date: Date?, forVendor id: UUID) {
            lock.lock(); defer { lock.unlock() }
            entries[id] = date
        }
        func lastSuccess(forVendor id: UUID) -> Date? {
            lock.lock(); defer { lock.unlock() }
            return entries[id]
        }
    }

    private final class FakeQuota: QuotaSnapshotProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot: QuotaSnapshot?
        func set(_ snapshot: QuotaSnapshot?) {
            lock.lock(); defer { lock.unlock() }
            self.snapshot = snapshot
        }
        func quotaSnapshot() -> QuotaSnapshot? {
            lock.lock(); defer { lock.unlock() }
            return snapshot
        }
    }

    /// Thread-safe boolean for assertions made from @Sendable closures.
    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() {
            lock.lock(); defer { lock.unlock() }
            value = true
        }
        var isSet: Bool {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    /// The spec §2 default table against synthetic vendor records.
    private struct RoutingFixture {
        let relayVendor: Vendor
        let splashVendor: Vendor
        let config: AppConfig
        let client: ClientConfig
    }

    private func makeFixture(mappings: [ModelMapping]? = nil) -> RoutingFixture {
        let relay = Vendor(
            name: "zcode relay", baseURL: "https://zcode.z.ai/api/v1/ultra-zai/anthropic",
            apiKey: "", readTimeoutSeconds: 10, vendorKind: .relay)
        let splash = Vendor(
            name: "splash (local)", baseURL: "http://127.0.0.1:8000",
            apiKey: "", replayPolicy: .portableOnly)
        let client = ClientConfig(
            clientName: "Claude Code", port: 0,
            defaultUpstream: "https://api.anthropic.com", unmappedPolicy: .passthrough)
        let table: [ModelMapping]
        if let mappings {
            table = mappings
        } else {
            // Same order as `AppConfig.makeZGateDefaultRouting` (owner
            // ruling 2026-11-16: sonnet → relay flash, haiku → splash q8).
            table = [
                ModelMapping(sourceModel: "auto", targetModel: "GLM-5.3", targetVendorID: relay.id, matchClass: .auto),
                ModelMapping(
                    sourceModel: "haiku", targetModel: "local/qwen3.8-27b-q8", targetVendorID: splash.id,
                    backupTargetModel: "GLM-5.3-Flash", backupTargetVendorID: relay.id, matchClass: .haiku),
                ModelMapping(sourceModel: "sonnet", targetModel: "GLM-5.3-Flash", targetVendorID: relay.id, matchClass: .sonnet),
                ModelMapping(
                    sourceModel: "opus (peak hours)", targetModel: "GLM-5.3-Flash",
                    targetVendorID: relay.id, isEnabled: false, matchClass: .opus,
                    conditions: [RuleCondition(
                        type: .timeWindow, days: .weekdays, from: "07:00", to: "11:00", tz: "Europe/Paris")]),
                ModelMapping(sourceModel: "opus", targetModel: "GLM-5.3", targetVendorID: relay.id, matchClass: .opus),
                ModelMapping(sourceModel: "fallback", targetModel: "GLM-5.3-Flash", targetVendorID: relay.id, catchAll: true),
            ]
        }
        let config = AppConfig(
            vendors: [relay, splash], clients: [client], modelMappings: table)
        return RoutingFixture(relayVendor: relay, splashVendor: splash, config: config, client: client)
    }

    private func resolve(
        _ fixture: RoutingFixture, model: String,
        context: ConditionContext = ConditionContext(now: Paris.date((2026, 11, 9), (12, 0)))
    ) -> RoutingSnapshot.ResolveResult {
        let snapshot = RoutingSnapshot(from: fixture.config, for: fixture.client)
        return snapshot.resolve(model: model, originalAPIKey: "client-key", conditions: context).result
    }

    private func routedTarget(_ result: RoutingSnapshot.ResolveResult) -> RoutingSnapshot.RouteTarget? {
        if case .routed(let target) = result { return target }
        return nil
    }

    private func fixedBody(model: String) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: 0)
        buffer.writeData(try! JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 64,
            "messages": [["role": "user", "content": "hello"]],
        ]))
        return buffer
    }

    // MARK: - Class map (AC: exact strings CC sends today)

    @Test func classMapMatchesCCWireNames() {
        // CC env aliases: opus/sonnet → glm-5.3 (also [1m]), haiku → glm-5.3-flash.
        #expect(ModelClass.classify("glm-5.3") == .sonnet)
        #expect(ModelClass.classify("glm-5.3[1m]") == .sonnet)
        #expect(ModelClass.classify("GLM-5.3") == .sonnet)  // case-insensitive
        #expect(ModelClass.classify("glm-5.3-flash") == .haiku)  // flash before glm-5.3 prefix
        #expect(ModelClass.classify("claude-3-5-haiku-20241022") == .haiku)
        #expect(ModelClass.classify("claude-opus-4-6") == .opus)
        #expect(ModelClass.classify("claude-fable-5") == .opus)  // fable alias
        #expect(ModelClass.classify("claude-sonnet-4-5-20250929") == .sonnet)
        #expect(ModelClass.classify("auto") == .auto)
        #expect(ModelClass.classify("default") == .auto)
        #expect(ModelClass.classify(nil) == .auto)  // missing model field
        #expect(ModelClass.classify("") == .auto)
        #expect(ModelClass.classify("  ") == .auto)
        #expect(ModelClass.classify("some-new-model-name") == nil)  // unknown → fallback
    }

    @Test func classRulesRouteCCModels() {
        let fixture = makeFixture()

        // glm-5.3 lands on the sonnet rule (CC aliasing), not the fallback —
        // which meters at the flash tier per the owner's 2026-11-16 ruling.
        let sonnetTarget = routedTarget(resolve(fixture, model: "glm-5.3"))
        #expect(sonnetTarget?.vendorKind == .relay)
        #expect(sonnetTarget?.targetModel == "GLM-5.3-Flash")

        // glm-5.3-flash lands on the haiku rule → splash.
        let haikuTarget = routedTarget(resolve(fixture, model: "glm-5.3-flash"))
        #expect(haikuTarget?.vendorName == "splash (local)")
        #expect(haikuTarget?.targetModel == "local/qwen3.8-27b-q8")

        #expect(routedTarget(resolve(fixture, model: "claude-3-5-haiku-20241022"))?.targetModel == "local/qwen3.8-27b-q8")
        #expect(routedTarget(resolve(fixture, model: "claude-opus-4-6"))?.targetModel == "GLM-5.3")

        // auto rule (before class rules in the ordered table).
        let autoTarget = routedTarget(resolve(fixture, model: "auto"))
        #expect(autoTarget?.targetModel == "GLM-5.3")

        // Missing model field routes as class auto.
        let missingTarget = routedTarget(resolve(fixture, model: ""))
        #expect(missingTarget?.targetModel == "GLM-5.3")
    }

    @Test func unknownModelHitsTerminalFallbackNeverDropped() {
        let fixture = makeFixture()
        let target = routedTarget(resolve(fixture, model: "some-new-model-name"))
        #expect(target != nil)  // never dropped
        #expect(target?.vendorKind == .relay)
        #expect(target?.targetModel == "GLM-5.3-Flash")
    }

    @Test func exactMatchMappingStillWinsOverClassRules() {
        var fixture = makeFixture()
        // A user's exact mapping for the aliased name beats the class table
        // (upstream engine evaluation order preserved).
        fixture.config.modelMappings.insert(
            ModelMapping(
                sourceModel: "glm-5.3", targetModel: "Qwen3.8-27B-4bit",
                targetVendorID: fixture.splashVendor.id),
            at: 0)
        let target = routedTarget(resolve(fixture, model: "glm-5.3"))
        #expect(target?.vendorName == "splash (local)")
    }

    // MARK: - timeWindow (AC: fixed-date Date injection)

    @Test func timeWindowMatchesParisWeekdayMorning() {
        let window = RuleCondition(type: .timeWindow, days: .weekdays, from: "07:00", to: "11:00", tz: "Europe/Paris")

        // Mon 08:00 Paris → in; Sat 08:00 and Mon 12:00 → out.
        #expect(window.isSatisfied(in: ConditionContext(now: Paris.date((2026, 11, 9), (8, 0)))))
        #expect(!window.isSatisfied(in: ConditionContext(now: Paris.date((2026, 11, 14), (8, 0)))))
        #expect(!window.isSatisfied(in: ConditionContext(now: Paris.date((2026, 11, 9), (12, 0)))))

        // Edges: 06:59 out, 07:00 in, 10:59 in, 11:00 out (to exclusive).
        #expect(!window.isSatisfied(in: ConditionContext(now: Paris.date((2026, 11, 9), (6, 59)))))
        #expect(window.isSatisfied(in: ConditionContext(now: Paris.date((2026, 11, 9), (7, 0)))))
        #expect(window.isSatisfied(in: ConditionContext(now: Paris.date((2026, 11, 9), (10, 59)))))
        #expect(!window.isSatisfied(in: ConditionContext(now: Paris.date((2026, 11, 9), (11, 0)))))
    }

    @Test func peakHoursRuleGovernsOpusRoutingWhenEnabled() {
        var fixture = makeFixture()
        fixture.config.modelMappings[3].isEnabled = true  // enable the opus peak lever

        // Mon 08:00 Paris → peak rule (flash) wins over the plain opus rule.
        let mondayPeak = resolve(
            fixture, model: "claude-opus-4-6",
            context: ConditionContext(now: Paris.date((2026, 11, 9), (8, 0))))
        #expect(routedTarget(mondayPeak)?.targetModel == "GLM-5.3-Flash")

        // Sat 08:00 Paris → weekday gate rejects → plain opus rule.
        let saturday = resolve(
            fixture, model: "claude-opus-4-6",
            context: ConditionContext(now: Paris.date((2026, 11, 14), (8, 0))))
        #expect(routedTarget(saturday)?.targetModel == "GLM-5.3")

        // Mon 12:00 Paris → outside the window → plain opus rule.
        let mondayNoon = resolve(
            fixture, model: "claude-opus-4-6",
            context: ConditionContext(now: Paris.date((2026, 11, 9), (12, 0))))
        #expect(routedTarget(mondayNoon)?.targetModel == "GLM-5.3")
    }

    @Test func timeWindowIsZoneAware() {
        let window = RuleCondition(type: .timeWindow, days: .weekdays, from: "07:00", to: "11:00", tz: "Europe/Paris")
        // 10:00 UTC on that Monday = 11:00 Paris (CET, UTC+1) → outside.
        var utcComps = DateComponents()
        utcComps.year = 2026; utcComps.month = 11; utcComps.day = 9; utcComps.hour = 10
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let utcDate = utcCalendar.date(from: utcComps)!
        #expect(!window.isSatisfied(in: ConditionContext(now: utcDate)))
    }

    // MARK: - quotaBelow (AC: seam snapshot, stale > 2h fails open)

    @Test func quotaBelowUsesSnapshotAndFailsOpenWhenStale() {
        let quota = FakeQuota()
        let condition = RuleCondition(type: .quotaBelow, percent: 20)
        let now = Paris.date((2026, 11, 9), (12, 0))

        // Fresh low quota → condition holds.
        quota.set(QuotaSnapshot(fractionRemaining: 0.15, fetchedAt: now))
        #expect(condition.isSatisfied(in: ConditionContext(now: now, quota: quota)))

        // Fresh high quota → does not hold.
        quota.set(QuotaSnapshot(fractionRemaining: 0.5, fetchedAt: now))
        #expect(!condition.isSatisfied(in: ConditionContext(now: now, quota: quota)))

        // Stale (> 2h) → treated as false even when the value is low.
        quota.set(QuotaSnapshot(fractionRemaining: 0.15, fetchedAt: now.addingTimeInterval(-3 * 3600)))
        #expect(!condition.isSatisfied(in: ConditionContext(now: now, quota: quota)))

        // Exactly 2h old is still usable (boundary).
        quota.set(QuotaSnapshot(fractionRemaining: 0.15, fetchedAt: now.addingTimeInterval(-2 * 3600)))
        #expect(condition.isSatisfied(in: ConditionContext(now: now, quota: quota)))

        // No seam at all → false.
        #expect(!condition.isSatisfied(in: ConditionContext(now: now)))
    }

    @Test func quotaGatedRuleSkipsToNextRuleWhenConditionFails() {
        let quota = FakeQuota()
        let relay = Vendor(name: "relay", baseURL: "https://zcode.z.ai/api/v1/ultra-zai/anthropic", apiKey: "", vendorKind: .relay)
        let splash = Vendor(name: "splash", baseURL: "http://127.0.0.1:8000", apiKey: "")
        let client = ClientConfig(clientName: "Claude Code", port: 0, defaultUpstream: "https://api.anthropic.com")
        let config = AppConfig(vendors: [relay, splash], clients: [client], modelMappings: [
            ModelMapping(
                sourceModel: "haiku", targetModel: "Qwen3.8-27B-4bit", targetVendorID: splash.id,
                matchClass: .haiku, conditions: [RuleCondition(type: .quotaBelow, percent: 20)]),
            ModelMapping(sourceModel: "fallback", targetModel: "GLM-5.3-Flash", targetVendorID: relay.id, catchAll: true),
        ])
        let fixture = RoutingFixture(relayVendor: relay, splashVendor: splash, config: config, client: client)
        let now = Paris.date((2026, 11, 9), (12, 0))

        // Quota low → the gated haiku rule serves.
        quota.set(QuotaSnapshot(fractionRemaining: 0.05, fetchedAt: now))
        #expect(routedTarget(
            resolve(fixture, model: "claude-3-5-haiku-20241022", context: ConditionContext(now: now, quota: quota))
        )?.targetModel == "Qwen3.8-27B-4bit")

        // Quota stale → condition false → fail-open to the catch-all rule.
        quota.set(QuotaSnapshot(fractionRemaining: 0.05, fetchedAt: now.addingTimeInterval(-3 * 3600)))
        #expect(routedTarget(
            resolve(fixture, model: "claude-3-5-haiku-20241022", context: ConditionContext(now: now, quota: quota))
        )?.targetModel == "GLM-5.3-Flash")
    }

    // MARK: - Health (AC: stale TCP probe > 60s skips the rule)

    @Test func staleProbeSkipsRuleToNextRule() {
        let fixture = makeFixture()
        let health = FakeHealth()
        let now = Paris.date((2026, 11, 9), (12, 0))
        let context = ConditionContext(now: now, health: health)

        // Fresh probe → the haiku rule serves via splash.
        health.setLastSuccess(now.addingTimeInterval(-5), forVendor: fixture.splashVendor.id)
        #expect(routedTarget(resolve(fixture, model: "claude-3-5-haiku-20241022", context: context))?.vendorName == "splash (local)")

        // Probe > 60s old → splash considered down → next rule → catch-all relay flash.
        health.setLastSuccess(now.addingTimeInterval(-120), forVendor: fixture.splashVendor.id)
        let skipped = routedTarget(resolve(fixture, model: "claude-3-5-haiku-20241022", context: context))
        #expect(skipped?.vendorKind == .relay)
        #expect(skipped?.targetModel == "GLM-5.3-Flash")

        // Never probed → no data → fail-open (rule serves).
        health.setLastSuccess(nil, forVendor: fixture.splashVendor.id)
        #expect(routedTarget(resolve(fixture, model: "claude-3-5-haiku-20241022", context: context))?.vendorName == "splash (local)")

        // Exactly 60s old is still healthy (boundary).
        health.setLastSuccess(now.addingTimeInterval(-60), forVendor: fixture.splashVendor.id)
        #expect(routedTarget(resolve(fixture, model: "claude-3-5-haiku-20241022", context: context))?.vendorName == "splash (local)")
    }

    @Test func nilHealthSeamFailOpens() {
        let fixture = makeFixture()
        // Tasks 7/8 not wired yet: no seam → splash rule serves normally.
        #expect(routedTarget(resolve(fixture, model: "claude-3-5-haiku-20241022"))?.vendorName == "splash (local)")
    }

    // MARK: - RequestRouter end-to-end (actor path)

    @Test func requestRouterRoutesClassRulesAndAllowsMissingModel() async throws {
        let fixture = makeFixture()
        let snapshot = RoutingSnapshot(from: fixture.config, for: fixture.client)
        let router = RequestRouter(snapshot: snapshot)

        func body(_ model: String?) -> ByteBuffer {
            var buffer = ByteBufferAllocator().buffer(capacity: 0)
            let json: [String: Any] = model.map { ["model": $0, "messages": []] } ?? ["messages": []]
            buffer.writeData(try! JSONSerialization.data(withJSONObject: json))
            return buffer
        }

        let sonnet = try await router.resolve(bodyBytes: body("glm-5.3"), originalAPIKey: "k")
        if case .routed(let target) = sonnet.result {
            #expect(target.targetModel == "GLM-5.3-Flash")
        } else {
            Issue.record("expected routed sonnet target")
        }

        let fallback = try await router.resolve(bodyBytes: body("some-new-model-name"), originalAPIKey: "k")
        if case .routed(let target) = fallback.result {
            #expect(target.targetModel == "GLM-5.3-Flash")
        } else {
            Issue.record("expected routed fallback target")
        }

        // Missing model field routes as auto when class rules exist…
        let missing = try await router.resolve(bodyBytes: body(nil), originalAPIKey: "k")
        #expect(missing.model == "")
        if case .routed(let target) = missing.result {
            #expect(target.targetModel == "GLM-5.3")
        } else {
            Issue.record("expected routed auto target for missing model")
        }

        // …but keeps the legacy 400 for configs without class rules.
        let legacyConfig = AppConfig(
            vendors: fixture.config.vendors, clients: [fixture.client], modelMappings: [])
        let legacyRouter = RequestRouter(snapshot: RoutingSnapshot(from: legacyConfig, for: fixture.client))
        await #expect(throws: RouterError.missingModelField) {
            _ = try await legacyRouter.resolve(bodyBytes: body(nil), originalAPIKey: "k")
        }
    }

    @Test func unparseableBodiesAnswerLocal400WhenClassRulesExist() async throws {
        let fixture = makeFixture()
        let router = RequestRouter(
            snapshot: RoutingSnapshot(from: fixture.config, for: fixture.client))

        func raw(_ string: String) -> ByteBuffer {
            var buffer = ByteBufferAllocator().buffer(capacity: 0)
            buffer.writeData(Data(string.utf8))
            return buffer
        }

        // Garbage JSON → local 400, never routed.
        await #expect(throws: RouterError.missingModelField) {
            _ = try await router.resolve(bodyBytes: raw("not json at all"), originalAPIKey: "k")
        }
        // Empty body → local 400.
        await #expect(throws: RouterError.missingModelField) {
            _ = try await router.resolve(
                bodyBytes: ByteBufferAllocator().buffer(capacity: 0), originalAPIKey: "k")
        }
        // Non-object JSON (bare array) → local 400.
        await #expect(throws: RouterError.missingModelField) {
            _ = try await router.resolve(bodyBytes: raw("[1,2,3]"), originalAPIKey: "k")
        }
        // Only a parsed object LACKING a model field routes as auto.
        let noModel = try await router.resolve(
            bodyBytes: raw(#"{"messages":[]}"#), originalAPIKey: "k")
        if case .routed(let target) = noModel.result {
            #expect(target.targetModel == "GLM-5.3")
        } else {
            Issue.record("expected routed auto target for object without model")
        }
    }

    @Test func failoverTargetsAndStateWritebackCoverClassRoutes() async throws {
        let fixture = makeFixture()
        let snapshot = RoutingSnapshot(from: fixture.config, for: fixture.client)
        let router = RequestRouter(snapshot: snapshot)

        // The haiku rule carries its backup target (splash primary, relay flash backup).
        let haikuTargets = try #require(await router.targets(for: "claude-3-5-haiku-20241022"))
        #expect(haikuTargets.count == 2)
        #expect(haikuTargets[0].vendorName == "splash (local)")
        #expect(haikuTargets[1].targetModel == "GLM-5.3-Flash")

        // State write-back keys by the class rule (read/write symmetry).
        var state = RoutingSnapshot.RouteState()
        state.failCount = 10
        state.activeTarget = .backup
        await router.updateRouteState(model: "claude-3-5-haiku-20241022", state: state)
        let resolved = try await router.resolve(
            bodyBytes: fixedBody(model: "claude-3-5-haiku-20241022"), originalAPIKey: "k")
        if case .routed(let target) = resolved.result {
            // activeTarget .backup → the relay flash backup serves.
            #expect(target.targetModel == "GLM-5.3-Flash")
        } else {
            Issue.record("expected routed backup target")
        }
        #expect(resolved.state.activeTarget == .backup)
    }

    @Test func failoverTargetsHonorRuleEligibility() async throws {
        let fixture = makeFixture()
        let health = FakeHealth()
        // Stale splash probe: the resolver must skip the haiku rule.
        health.setLastSuccess(Date().addingTimeInterval(-120), forVendor: fixture.splashVendor.id)
        let router = RequestRouter(
            snapshot: RoutingSnapshot(from: fixture.config, for: fixture.client),
            healthProvider: health)

        // The catch-all (relay flash) serves the haiku-classed request.
        let resolved = try await router.resolve(
            bodyBytes: fixedBody(model: "claude-3-5-haiku-20241022"), originalAPIKey: "k")
        if case .routed(let target) = resolved.result {
            #expect(target.targetModel == "GLM-5.3-Flash")
        } else {
            Issue.record("expected catch-all to serve while splash is stale")
        }

        // 429 failover consults the ELIGIBLE rule: the catch-all's relay
        // target only — never the skipped splash rule's targets.
        let failoverTargets = try #require(await router.targets(for: "claude-3-5-haiku-20241022"))
        #expect(!failoverTargets.isEmpty)
        #expect(failoverTargets.allSatisfy { $0.vendorKind == .relay })
        #expect(!failoverTargets.contains { $0.vendorName == "splash (local)" })

        // Probe fresh again → the haiku rule is eligible → its targets
        // (splash primary + relay flash backup) come back.
        health.setLastSuccess(Date().addingTimeInterval(-5), forVendor: fixture.splashVendor.id)
        let eligibleTargets = try #require(await router.targets(for: "claude-3-5-haiku-20241022"))
        #expect(eligibleTargets.count == 2)
        #expect(eligibleTargets[0].vendorName == "splash (local)")
        #expect(eligibleTargets[1].targetModel == "GLM-5.3-Flash")
    }

    @Test func routeStateWritebackKeysTheServedRuleNotTheSkippedOne() async throws {
        let fixture = makeFixture()
        let health = FakeHealth()
        health.setLastSuccess(Date().addingTimeInterval(-120), forVendor: fixture.splashVendor.id)
        let router = RequestRouter(
            snapshot: RoutingSnapshot(from: fixture.config, for: fixture.client),
            healthProvider: health)

        // Catch-all serves (splash skipped): state read starts at primary.
        let served = try await router.resolve(
            bodyBytes: fixedBody(model: "claude-3-5-haiku-20241022"), originalAPIKey: "k")
        #expect(served.state.activeTarget == .primary)

        // Failover write-back: must land on the catch-all's key — the rule
        // that served — not the skipped haiku rule's key.
        var state = served.state
        state.failCount = 10
        state.activeTarget = .backup
        await router.updateRouteState(model: "claude-3-5-haiku-20241022", state: state)

        // The catch-all re-reads its own written state.
        let again = try await router.resolve(
            bodyBytes: fixedBody(model: "claude-3-5-haiku-20241022"), originalAPIKey: "k")
        #expect(again.state.activeTarget == .backup)
        #expect(again.state.failCount == 10)

        // And the skipped haiku rule's state stayed untouched: once splash is
        // healthy it serves from primary (a mis-keyed write would have
        // flipped it to backup → relay flash).
        health.setLastSuccess(Date().addingTimeInterval(-5), forVendor: fixture.splashVendor.id)
        let healthy = try await router.resolve(
            bodyBytes: fixedBody(model: "claude-3-5-haiku-20241022"), originalAPIKey: "k")
        #expect(healthy.state.activeTarget == .primary)
        #expect(healthy.state.failCount == 0)
        if case .routed(let target) = healthy.result {
            #expect(target.vendorName == "splash (local)")
        } else {
            Issue.record("expected splash to serve once healthy")
        }
    }

    // MARK: - Default rule table (AC: installs on first launch, JSON pinned)

    @Test func defaultConfigJSONCarriesSpecSection2RuleTable() throws {
        let config = AppConfig.makeDefault()
        let data = try JSONEncoder().encode(config)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        // Vendors: relay + splash, no secrets.
        let vendors = try #require(json["vendors"] as? [[String: Any]])
        #expect(vendors.count == 2)
        let relay = try #require(vendors.first { ($0["name"] as? String) == "zcode relay" })
        #expect(relay["baseURL"] as? String == "https://zcode.z.ai/api/v1/ultra-zai/anthropic")
        #expect(relay["vendorKind"] as? String == "relay")
        #expect(relay["apiKey"] as? String == "")
        let splash = try #require(vendors.first { ($0["name"] as? String) == "splash (local)" })
        #expect(splash["baseURL"] as? String == "http://127.0.0.1:8000")
        #expect(splash["replayPolicy"] as? String == "portableOnly")

        // Rules, ordered: auto, haiku, sonnet, opus-peak (disabled), opus,
        // fallback — with the owner-ruled targets (2026-11-16 correction of
        // spec §2): sonnet meters at flash, haiku rides the splash q8 quant.
        let mappings = try #require(json["modelMappings"] as? [[String: Any]])
        #expect(mappings.count == 6)
        #expect(mappings[0]["matchClass"] as? String == "auto")
        #expect(mappings[0]["targetModel"] as? String == "GLM-5.3")
        #expect(mappings[1]["matchClass"] as? String == "haiku")
        #expect(mappings[1]["targetModel"] as? String == "local/qwen3.8-27b-q8")
        #expect(mappings[1]["backupTargetModel"] as? String == "GLM-5.3-Flash")
        #expect(mappings[2]["matchClass"] as? String == "sonnet")
        #expect(mappings[2]["targetModel"] as? String == "GLM-5.3-Flash")
        #expect(mappings[3]["matchClass"] as? String == "opus")
        #expect(mappings[3]["targetModel"] as? String == "GLM-5.3-Flash")
        #expect(mappings[3]["isEnabled"] as? Bool == false)  // cost lever ships disabled
        let peak = try #require(mappings[3]["conditions"] as? [[String: Any]])
        #expect(peak.count == 1)
        #expect(peak[0]["type"] as? String == "timeWindow")
        #expect(peak[0]["days"] as? String == "weekdays")
        #expect(peak[0]["from"] as? String == "07:00")
        #expect(peak[0]["to"] as? String == "11:00")
        #expect(peak[0]["tz"] as? String == "Europe/Paris")
        #expect(mappings[4]["matchClass"] as? String == "opus")
        #expect(mappings[4]["targetModel"] as? String == "GLM-5.3")
        #expect(mappings[4]["isEnabled"] as? Bool == true)
        #expect(mappings[5]["catchAll"] as? Bool == true)
        #expect(mappings[5]["targetModel"] as? String == "GLM-5.3-Flash")

        // Targets point at the vendors by id.
        let relayID = try #require(relay["id"] as? String)
        let splashID = try #require(splash["id"] as? String)
        #expect(mappings[0]["targetVendorID"] as? String == relayID)
        #expect(mappings[1]["targetVendorID"] as? String == splashID)
        #expect(mappings[5]["targetVendorID"] as? String == relayID)

        // Round-trip keeps the rule semantics.
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.modelMappings.map(\.matchClass) == config.modelMappings.map(\.matchClass))
        #expect(decoded.modelMappings[5].catchAll)
        #expect(decoded.modelMappings[3].conditions == config.modelMappings[3].conditions)
        #expect(!decoded.modelMappings[3].isEnabled)
    }

    @Test func legacyConfigWithoutNewFieldsDecodesUnchanged() throws {
        // A pre-Task-6 config JSON: no matchClass/catchAll/conditions keys.
        let legacy = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "sourceModel": "claude-haiku-4-5", "targetModel": "qwen-turbo",
          "targetVendorID": "00000000-0000-0000-0000-000000000001", "isEnabled": true
        }
        """
        let mapping = try JSONDecoder().decode(ModelMapping.self, from: Data(legacy.utf8))
        #expect(mapping.matchClass == nil)
        #expect(mapping.catchAll == false)
        #expect(mapping.conditions == nil)
        #expect(mapping.sourceModel == "claude-haiku-4-5")
    }

    // MARK: - Relay-signing wiring (server layer → forwarder)

    /// A SigningClient that can never build a chain (no store, no location,
    /// no cache) — unusable by design, so a request reaching the signed
    /// ladder fails fast with the signing-unavailable 502 and nothing is sent.
    private nonisolated static func makeUnusableSigningClientSendable() -> SigningClient {
        var configuration = SigningClient.Configuration()
        configuration.store = nil
        configuration.initialLocation = nil
        configuration.cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zgate-router-unusable-\(UUID().uuidString).cache")
        return SigningClient(configuration: configuration)
    }

    @Test func relayRulesReachSignedLadderEndToEnd() async throws {
        // Full chain over a real socket: ProxyServer builds the context
        // (injected unusable signing client), the channel handler passes it
        // down, and the relay-kind rule runs RelayTarget's signed ladder —
        // which fails with the chain's own 502, NOT the nil-context
        // "no signing context" 502. Nothing is sent upstream unsigned.
        let fixture = makeFixture()
        let server = ProxyServer(
            tokenStatsStore: TokenStatsStore(),
            makeSigningClient: { Self.makeUnusableSigningClientSendable() })
        await server.start(config: fixture.config)
        defer { Task { await server.stop() } }
        let port = try #require(server.boundPorts["Claude Code"])

        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        defer { Task { try? await httpClient.shutdown() } }

        var request = HTTPClientRequest(url: "http://127.0.0.1:\(port)/v1/messages")
        request.method = .POST
        request.headers.add(name: "x-api-key", value: "client-key")
        request.headers.add(name: "content-type", value: "application/json")
        var body = fixedBody(model: "glm-5.3")
        var bodyData = ByteBufferAllocator().buffer(capacity: body.readableBytes)
        bodyData.writeBuffer(&body)
        request.body = .bytes(bodyData)

        let response = try await httpClient.execute(request, timeout: .seconds(10))
        #expect(response.status == .badGateway)
        var data = Data()
        for try await chunk in response.body {
            if let bytes = chunk.getData(at: chunk.readerIndex, length: chunk.readableBytes) {
                data.append(bytes)
            }
        }
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let error = try #require(json["error"] as? [String: Any])
        let message = try #require(error["message"] as? String)
        #expect(message.localizedCaseInsensitiveContains("signing unavailable"))
        #expect(!message.localizedCaseInsensitiveContains("no signing context"))
    }

    @Test func proxyServerBuildsRelayContextOnlyForRelayVendors() async throws {
        // No relay vendor → no signing context (and the factory never runs).
        let plain = AppConfig(
            vendors: [Vendor(name: "plain", baseURL: "https://api.anthropic.com", apiKey: "k")],
            clients: [ClientConfig(clientName: "Claude Code", port: 0, defaultUpstream: "https://api.anthropic.com")],
            modelMappings: [])
        let factoryRan = LockedFlag()
        let server = ProxyServer(tokenStatsStore: TokenStatsStore(), makeSigningClient: {
            factoryRan.set()
            return Self.makeUnusableSigningClientSendable()
        })
        await server.start(config: plain)
        #expect(server.relayContext == nil)
        #expect(!factoryRan.isSet)
        await server.stop()

        // Relay vendor → context built once, wired to the shared event channel,
        // and stable across a restart (per-process session id).
        let fixture = makeFixture()
        let relayServer = ProxyServer(tokenStatsStore: TokenStatsStore(), makeSigningClient: {
            factoryRan.set()
            return Self.makeUnusableSigningClientSendable()
        })
        await relayServer.start(config: fixture.config)
        #expect(factoryRan.isSet)
        let context = try #require(relayServer.relayContext)
        #expect(context.credentialEvents === relayServer.credentialEvents)
        await relayServer.stop()
        await relayServer.start(config: fixture.config)
        #expect(relayServer.relayContext === context)
        await relayServer.stop()
    }

    @Test func proxyServerStartIsIdempotentWhileRunning() async throws {
        // The app starts the server at LAUNCH (ModelProxyApp init); the
        // popover's .task start path and Resume re-enter start() afterwards.
        // The second start must be a strict no-op: same bound port, no extra
        // listener, still running (fix round 1, Important 1).
        let config = AppConfig(
            clients: [ClientConfig(
                clientName: "Claude Code", port: 0,
                defaultUpstream: "https://api.anthropic.com")])
        let server = ProxyServer(tokenStatsStore: TokenStatsStore())
        await server.start(config: config)
        defer { Task { await server.stop() } }
        let port = try #require(server.boundPorts["Claude Code"])
        #expect(server.isRunning)

        await server.start(config: config)
        #expect(server.isRunning)
        #expect(server.boundPorts["Claude Code"] == port)
        #expect(server.boundPorts.count == 1)
    }

    @Test func proxyServerAdvancesToNextFreePortWhenConfiguredPortTaken() async throws {
        // Binding plan: configured port taken → bind the next free port, and
        // `boundPorts` (what the popover's copyable env line reads) carries
        // the truth. Two consecutive blockers prove the search walks past a
        // run of taken ports; a successful advance is no error (no banner).
        let blockerGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await blockerGroup.shutdownGracefully() } }
        func occupy(_ port: Int) async throws -> any Channel {
            try await ServerBootstrap(group: blockerGroup)
                .bind(host: "127.0.0.1", port: port).get()
        }
        let firstBlocker = try await occupy(0)
        let takenPort = try #require(firstBlocker.localAddress?.port)
        let secondBlocker = try await occupy(takenPort + 1)

        let config = AppConfig(
            clients: [ClientConfig(
                clientName: "Claude Code", port: takenPort,
                defaultUpstream: "https://api.anthropic.com")])
        let server = ProxyServer(tokenStatsStore: TokenStatsStore())
        await server.start(config: config)
        defer { Task { await server.stop() } }

        #expect(server.isRunning)
        #expect(server.lastError == nil)
        #expect(server.boundPorts["Claude Code"] == takenPort + 2)

        _ = try? await firstBlocker.close().get()
        _ = try? await secondBlocker.close().get()
    }
}

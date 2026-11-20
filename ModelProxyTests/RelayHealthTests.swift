import Foundation
import Testing
@testable import ZGate

/// Unit tests for `RelayHealth` — the relay plane's degraded machine (probe
/// cadence, risk cooldown) and the strictly separated fallback-key plane
/// (lazy mint, no-balance cooldown). The clock is injected; nothing here
/// sleeps or touches the network.
@Suite struct RelayHealthTests {

    // MARK: - Clock

    private final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant: Date

        init(_ date: Date = Date(timeIntervalSince1970: 1_763_000_000)) {
            instant = date
        }

        var now: Date {
            lock.lock(); defer { lock.unlock() }
            return instant
        }

        func advance(_ seconds: TimeInterval) {
            lock.lock(); instant = instant.addingTimeInterval(seconds); lock.unlock()
        }
    }

    // MARK: - Scripted mint chain

    /// Serves the whole mint chain in-memory through the minter's execute
    /// seam: getCustomerInfo → list → copy, counting full chain runs and
    /// handing out an incrementing secret per run.
    private final class ScriptedMintChain: @unchecked Sendable {
        private let lock = NSLock()
        private var _runs = 0
        private var _secretIndex = 0
        /// When true every call answers a business rejection (mint throws).
        var fail = false
        /// When set, the mint waits this long per call (single-flight test).
        var delaySeconds: TimeInterval = 0

        var runs: Int {
            lock.lock(); defer { lock.unlock() }
            return _runs
        }

        private func json(_ object: [String: Any]) -> Data {
            (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        }

        func respond(path: String) throws -> (Int, Data) {
            if delaySeconds > 0 {
                awaitlessSleep(delaySeconds)
            }
            if fail {
                return (200, json(["code": 500, "msg": "mint refused"]))
            }
            if path.contains("getCustomerInfo") {
                lock.lock(); _runs += 1; lock.unlock()
                return (200, json(["code": 0, "data": ["organizations": [
                    ["id": "org-1", "name": "默认机构", "projects": [["id": "proj-1", "name": "默认项目"]]],
                ]]]))
            }
            if path.contains("/copy/") {
                lock.lock(); _secretIndex += 1; let index = _secretIndex; lock.unlock()
                return (200, json(["code": 0, "data": ["secretKey": "secret-\(index)"]]))
            }
            if path.hasSuffix("/api_keys") {
                return (200, json(["code": 0, "data": ["list": [["id": "apiKey-1", "name": "zcode-api-key"]]]]))
            }
            throw NSError(domain: "ScriptedMintChain", code: 1)
        }

        private func awaitlessSleep(_ seconds: TimeInterval) {
            // Runs inside a @Sendable sync closure; a plain thread nap is
            // fine for the single-flight test (50 ms).
            Thread.sleep(forTimeInterval: seconds)
        }
    }

    private func makeMinter(chain: ScriptedMintChain) -> ApiKeyMinter {
        var configuration = ApiKeyMinter.Configuration()
        configuration.bizJWTProvider = { "biz-jwt" }
        configuration.execute = { request in
            try chain.respond(path: request.url?.path ?? "")
        }
        return ApiKeyMinter(configuration: configuration)
    }

    private func makeHealth(
        clock: ManualClock,
        chain: ScriptedMintChain? = nil,
        onKeyMinted: (@Sendable (String) -> Void)? = nil
    ) -> RelayHealth {
        var configuration = RelayHealth.Configuration()
        configuration.now = { clock.now }
        if let chain {
            configuration.minter = makeMinter(chain: chain)
        }
        configuration.onKeyMinted = onKeyMinted
        return RelayHealth(configuration: configuration)
    }

    // MARK: - Relay machine: healthy → degraded

    @Test func admissionAttemptsWhileHealthy() async {
        let clock = ManualClock()
        let health = makeHealth(clock: clock)

        #expect(await health.currentState() == .healthy)
        #expect(await health.admission() == .attempt)
    }

    @Test func signingFailureEntersDegradedWithBaseProbeInterval() async {
        let clock = ManualClock()
        let health = makeHealth(clock: clock)

        await health.noteSigningFailure()

        #expect(await health.currentState() == .degradedSigning(
            nextProbeAtMs: 1_763_000_060_000, backoffSeconds: 60))
        clock.advance(59.9)
        #expect(await health.admission() == .serveViaFallback)
        clock.advance(0.1)
        #expect(await health.admission() == .probe)
    }

    @Test func probeCadenceDoublesThenCapsAt300Seconds() async {
        let clock = ManualClock()
        let health = makeHealth(clock: clock)

        // First failure: probe due at +60 with base backoff 60.
        await health.noteSigningFailure()

        // Probe 1 at t=60 fails → backoff 120, next probe 60+120=180.
        clock.advance(60)
        #expect(await health.admission() == .probe)
        await health.noteSigningFailure()
        #expect(await health.currentState() == .degradedSigning(
            nextProbeAtMs: 1_763_000_180_000, backoffSeconds: 120))

        // Before 180: fallback; probe 2 at 180 fails → backoff 240, next 420.
        clock.advance(119.9)
        #expect(await health.admission() == .serveViaFallback)
        clock.advance(0.1)
        #expect(await health.admission() == .probe)
        await health.noteSigningFailure()
        #expect(await health.currentState() == .degradedSigning(
            nextProbeAtMs: 1_763_000_420_000, backoffSeconds: 240))

        // Probe 3 at 420 fails → backoff capped at 300, next 720.
        clock.advance(240)
        #expect(await health.admission() == .probe)
        await health.noteSigningFailure()
        #expect(await health.currentState() == .degradedSigning(
            nextProbeAtMs: 1_763_000_720_000, backoffSeconds: 300))

        // Probe 4 at 720 fails → backoff stays capped, next 1020.
        clock.advance(300)
        #expect(await health.admission() == .probe)
        await health.noteSigningFailure()
        #expect(await health.currentState() == .degradedSigning(
            nextProbeAtMs: 1_763_001_020_000, backoffSeconds: 300))
    }

    @Test func probeClaimHoldsTheSlotAgainstConcurrentRequests() async {
        let clock = ManualClock()
        let health = makeHealth(clock: clock)

        await health.noteSigningFailure()
        clock.advance(60)
        #expect(await health.admission() == .probe)
        // The in-flight probe claimed the slot through the current backoff
        // (60 s): a concurrent request serves via the fallback instead.
        #expect(await health.admission() == .serveViaFallback)
        clock.advance(59.9)
        #expect(await health.admission() == .serveViaFallback)
        // A probe that never reported (cancelled client) re-arms after the
        // claimed interval.
        clock.advance(0.1)
        #expect(await health.admission() == .probe)
    }

    @Test func probeSuccessResetsToHealthyAndBackoff() async {
        let clock = ManualClock()
        let health = makeHealth(clock: clock)

        await health.noteSigningFailure()
        clock.advance(60)
        _ = await health.admission()  // probe
        await health.noteSigningFailure()  // backoff 120
        clock.advance(120)
        #expect(await health.admission() == .probe)
        await health.noteRelayServed()

        #expect(await health.currentState() == .healthy)
        #expect(await health.admission() == .attempt)
        // Reset proven: the next degradation starts at the base interval.
        await health.noteSigningFailure()
        #expect(await health.currentState() == .degradedSigning(
            nextProbeAtMs: 1_763_000_180_000 + 60_000, backoffSeconds: 60))
    }

    // MARK: - Risk cooldown

    @Test func riskCooldownBlocksRelayAttemptsAndExpiresToHealthy() async {
        let clock = ManualClock()
        let health = makeHealth(clock: clock)

        await health.noteRiskControl()
        #expect(await health.currentState() == .riskCooldown(untilMs: 1_763_000_900_000))
        clock.advance(899.9)
        #expect(await health.admission() == .riskBlocked)
        clock.advance(0.1)
        #expect(await health.admission() == .attempt)
        #expect(await health.currentState() == .healthy)
    }

    @Test func riskControlSupersedesDegradedAndIgnoresSigningFailures() async {
        let clock = ManualClock()
        let health = makeHealth(clock: clock)

        await health.noteSigningFailure()
        await health.noteRiskControl()
        let untilMs = Int64(1_763_000_900_000)

        await health.noteSigningFailure()  // ignored during the cooldown
        #expect(await health.currentState() == .riskCooldown(untilMs: untilMs))
        clock.advance(901)
        #expect(await health.admission() == .attempt)  // expired to healthy, not degraded
        #expect(await health.currentState() == .healthy)
    }

    // MARK: - Fallback key plane

    @Test func fallbackKeyMintsLazilyOnceAndCaches() async {
        let clock = ManualClock()
        let chain = ScriptedMintChain()
        var mintedNotifications: [String] = []
        let health = makeHealth(clock: clock, chain: chain, onKeyMinted: { mintedNotifications.append($0) })

        let key = await health.fallbackKey()
        #expect(key == "apiKey-1.secret-1")
        #expect(chain.runs == 1)
        #expect(mintedNotifications == ["apiKey-1.secret-1"])

        // Cached: no second chain run.
        #expect(await health.fallbackKey() == "apiKey-1.secret-1")
        #expect(chain.runs == 1)
        #expect(mintedNotifications.count == 1)
    }

    @Test func forcedRemintRunsTheChainAgain() async {
        let chain = ScriptedMintChain()
        let health = makeHealth(clock: ManualClock(), chain: chain)

        _ = await health.fallbackKey()
        #expect(await health.fallbackKey(forceRemint: true) == "apiKey-1.secret-2")
        #expect(chain.runs == 2)
    }

    @Test func noMinterYieldsNoKey() async {
        let health = makeHealth(clock: ManualClock(), chain: nil)
        #expect(await health.fallbackKey() == nil)
    }

    @Test func failedMintIsGuardedByARetryCooldown() async {
        let clock = ManualClock()
        let chain = ScriptedMintChain()
        chain.fail = true
        let health = makeHealth(clock: clock, chain: chain)

        #expect(await health.fallbackKey() == nil)
        // A second request within the cooldown does not re-run the chain.
        clock.advance(59)
        #expect(await health.fallbackKey() == nil)
        #expect(chain.runs == 0)  // the failing run never reached info completion
        chain.fail = false
        clock.advance(1)
        #expect(await health.fallbackKey() == "apiKey-1.secret-1")
    }

    @Test func noBalanceCoolsTheKeyForOneHour() async {
        let clock = ManualClock()
        let chain = ScriptedMintChain()
        let health = makeHealth(clock: clock, chain: chain)

        _ = await health.fallbackKey()
        await health.noteFallbackKeyNoBalance()

        #expect(await health.isFallbackKeyCooling() == true)
        clock.advance(3599.9)
        #expect(await health.fallbackKey() == nil)
        // The mint-failure cooldown must not own this: after the key
        // cooldown lifts the CACHED key serves again without a new run.
        clock.advance(0.1)
        #expect(await health.fallbackKey() == "apiKey-1.secret-1")
        #expect(chain.runs == 1)
        #expect(await health.isFallbackKeyCooling() == false)
    }

    @Test func concurrentFallbackKeyCallsShareOneMint() async {
        let chain = ScriptedMintChain()
        chain.delaySeconds = 0.05
        let health = makeHealth(clock: ManualClock(), chain: chain)

        async let first = health.fallbackKey()
        async let second = health.fallbackKey()
        let keys = await [first, second]

        #expect(keys == ["apiKey-1.secret-1", "apiKey-1.secret-1"])
        #expect(chain.runs == 1)
    }

    // MARK: - Never launder

    @Test func fallbackPlaneNeverTouchesTheRelayMachine() async {
        let clock = ManualClock()
        let chain = ScriptedMintChain()
        let health = makeHealth(clock: clock, chain: chain)

        // Mint, cool the key, force a re-mint: the relay machine stays healthy.
        _ = await health.fallbackKey()
        await health.noteFallbackKeyNoBalance()
        clock.advance(3601)
        _ = await health.fallbackKey(forceRemint: true)
        #expect(await health.currentState() == .healthy)

        // And a failed mint (worst fallback outcome) still leaves it healthy.
        chain.fail = true
        clock.advance(61)
        _ = await health.fallbackKey(forceRemint: true)
        #expect(await health.currentState() == .healthy)
    }

    @Test func relayMachineNeverTouchesTheKeyPlane() async {
        let clock = ManualClock()
        let chain = ScriptedMintChain()
        let health = makeHealth(clock: clock, chain: chain)

        _ = await health.fallbackKey()
        await health.noteSigningFailure()
        await health.noteRiskControl()

        // Key still cached and servable through every relay-state change.
        #expect(await health.fallbackKey() == "apiKey-1.secret-1")
        #expect(chain.runs == 1)
        #expect(await health.currentState() == .riskCooldown(untilMs: 1_763_000_900_000))
    }
}

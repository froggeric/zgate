import Foundation
import Testing
@testable import ZGate

/// Writes a stub executable; `ignoreTerm` makes it trap SIGTERM. Free
/// function so @Sendable binaryPathProvider closures can capture it without
/// dragging the suite struct in.
func writeSplashStub(ignoreTerm: Bool = false) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("splash-stub-\(UUID().uuidString).sh")
    let body = ignoreTerm
        ? #"""
        #!/bin/sh
        echo "stub up"
        trap '' TERM
        while :; do sleep 0.05; done
        """#
        : #"""
        #!/bin/sh
        echo "stub up"
        while :; do sleep 0.05; done
        """#
    try body.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

@Suite(.serialized) @MainActor struct SplashManagerTests {

    /// Virtual clock: sleep() advances time instantly — the readiness loop
    /// and backoff schedule run at full virtual speed. @MainActor matches the
    /// SplashClock requirement, so manager-side clock calls execute without
    /// suspension and state transitions stay atomic per main-actor turn.
    @MainActor final class ManualClock: SplashClock, @unchecked Sendable {
        let lock = NSLock(); var current = Date(timeIntervalSince1970: 1_700_000_000)
        nonisolated init() {}   // default-arg expressions are checked nonisolated
        func now() -> Date { lock.withLock { current } }
        func sleep(seconds: TimeInterval) async throws {
            lock.withLock { current = current.addingTimeInterval(seconds) }
        }
    }

    func makeManager(
        clock: ManualClock = ManualClock(),
        probeResult: @Sendable @escaping () async -> Bool
    ) -> SplashManager {
        SplashManager(
            binaryPathProvider: { try! writeSplashStub() },   // fresh stub per launch
            clock: clock,
            probe: probeResult)
    }

    /// Bounded real-time wait for the stub's first stdout line to reach the
    /// log ring. stdout arrival proves the script is executing (trap line is
    /// the next statement), so signals land post-startup regardless of
    /// machine load — fixed sleeps flaked under full-suite parallel load.
    func waitForStubStdout(_ m: SplashManager, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !m.log.lines.contains("stub up"), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @Test func plannerCoversOwnershipMatrix() {
        #expect(SplashStartupPlanner.plan(keepRunning: false, portAnswers: true, hasChild: false) == .none)
        #expect(SplashStartupPlanner.plan(keepRunning: true, portAnswers: true, hasChild: false) == .adoptExternal)
        #expect(SplashStartupPlanner.plan(keepRunning: true, portAnswers: true, hasChild: true) == .none)
        #expect(SplashStartupPlanner.plan(keepRunning: true, portAnswers: false, hasChild: true) == .none)
        #expect(SplashStartupPlanner.plan(keepRunning: true, portAnswers: false, hasChild: false) == .startOwned)
        // Reviewer hardening: the doubling schedule saturates at the 60 s cap.
        #expect(SplashBackoff.delay(attempt: 100) == 60)
    }

    @Test func startReachesRunningAndPipesStdout() async throws {
        let m = makeManager { true }
        try await m.start(profile: SplashProfile(name: "p", model: "m"))
        #expect(m.state == .running(profile: "p", since: m.stateRunningSince!, adopted: false))
        #expect(m.launchCount == 1)
        try await waitForStubStdout(m)
        #expect(m.log.lines.contains("stub up"))
        try await m.stop()
    }

    @Test func readinessTimeoutFailsToCrashed() async throws {
        let m = makeManager { false }
        try await m.start(profile: SplashProfile(name: "p", model: "m"))
        if case .crashed = m.state {} else { Issue.record("expected crashed, got \(m.state)") }
        #expect(m.child == nil)
    }

    @Test func stopReapsTermObeyingChild() async throws {
        let m = makeManager { true }
        try await m.start(profile: SplashProfile(name: "p", model: "m"))
        // Wait for the stub to come up so TERM lands on a running shell
        // (not a pre-exec fork) and the reaping path is exercised.
        try await waitForStubStdout(m)
        try await m.stop()
        #expect(m.state == .stopped)
        #expect(m.child == nil)
    }

    @Test func stopEscalatesToKillWhenTermIgnored() async throws {
        let clock = ManualClock()
        // one stub shared: binaryPathProvider must return the TERM-ignorer
        let stub = try writeSplashStub(ignoreTerm: true)
        let m = SplashManager(
            binaryPathProvider: { stub }, clock: clock, probe: { true })
        try await m.start(profile: SplashProfile(name: "p", model: "m"))
        // TERM must land AFTER the stub's `trap '' TERM` line executes or the
        // child dies pre-trap and the escalation path is never exercised.
        // stdout arrival (next statement after the echo) proves it.
        try await waitForStubStdout(m)
        let childProcess = m.child
        let t0 = clock.now()
        try await m.stop()   // virtual grace elapses instantly via ManualClock
        // Escalation pins: the grace loop must actually elapse stopGrace on
        // the virtual clock, and the child must have died to SIGKILL as an
        // uncaught signal — deleting the grace loop or killChild now fails.
        #expect(clock.now().timeIntervalSince(t0) >= SplashManager.stopGrace)
        #expect(childProcess?.terminationReason == .uncaughtSignal)
        #expect(childProcess?.terminationStatus == Int32(SIGKILL))
        #expect(m.state == .stopped)
        #expect(m.child == nil)
    }

    @Test func unexpectedExitRelaunchesWithBackoff() async throws {
        let clock = ManualClock()
        let stubURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("splash-quickexit-\(UUID().uuidString).sh")
        try #"""
        #!/bin/sh
        echo "dying"
        """#.write(to: stubURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: stubURL.path)
        // Probe silent at configure time (plan = startOwned) and answering
        // from then on (readiness + retries succeed). A constant-true probe
        // would make configure adopt the port instead of ever launching, so
        // no child could exit and launchCount could never reach 2.
        let box = LockedBox(value: false)
        let m = SplashManager(binaryPathProvider: { stubURL }, clock: clock, probe: { box.load() })
        let settings = SplashSettings(keepRunning: true, profiles: [SplashProfile(name: "p", model: "m")])
        await m.configure(settings: settings)
        box.store(true)
        // child exits after ~50-200 ms of sh startup per cycle (more under
        // parallel-suite load); backoff sleeps are virtual; probe true on
        // retry. 2 s fits several full relaunch cycles so launchCount >= 2
        // has margin.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        #expect(m.launchCount >= 2)
        if case .running = m.state {} else if case .starting = m.state {} else {
            Issue.record("expected running/starting after relaunch, got \(m.state)")
        }
        await m.terminateFromApp()
    }

    @Test func consecutivePreReadinessDeathsAccumulateBackoff() async throws {
        // Regression pin (review round 1): the exit-time stability reset must
        // only consult the EXITED lifecycle's stability. With a stale
        // stableSince from a previous ≥5-min-stable run, every pre-readiness
        // death reset attempts to 0 → attempt 1 → ~1 s relaunch loop forever,
        // 60 s cap unreachable (each cycle can mmap a 28 GB model).
        let clock = ManualClock()
        let stableURL = try writeSplashStub()   // stay-alive: accrues stability
        let poisonURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("splash-quickexit-\(UUID().uuidString).sh")
        try #"""
        #!/bin/sh
        echo "dying"
        """#.write(to: poisonURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: poisonURL.path)
        let probeBox = LockedBox(value: false)
        let poison = LockedBox(value: false)
        let m = SplashManager(
            binaryPathProvider: { poison.load() ? poisonURL : stableURL },
            clock: clock, probe: { probeBox.load() })
        let settings = SplashSettings(keepRunning: true, profiles: [SplashProfile(name: "p", model: "m")])
        await m.configure(settings: settings)   // startOwned (probe silent) → stable stub
        probeBox.store(true)                    // readiness resolves → becameRunning
        try await Task.sleep(nanoseconds: 300_000_000)   // let launch #1 settle
        #expect(m.crashAttempts == 0)
        try await clock.sleep(seconds: SplashBackoff.stableReset)   // virtual +5 min
        // Now the "binary breaks": probe never answers, launches die pre-readiness.
        probeBox.store(false)
        poison.store(true)
        m.child?.terminate()                    // crash the stable lifecycle (own stub)
        try await Task.sleep(nanoseconds: 3_000_000_000)   // several poison cycles
        #expect(m.launchCount >= 3)
        // The fix: beginStart clears stableSince, so pre-readiness deaths
        // accumulate (1, 2, 3, …). The stale-stableSince bug held this at 1.
        #expect(m.crashAttempts >= 3)
        await m.terminateFromApp()
    }

    @Test func adoptExternalWhenPortAnswers() async throws {
        let m = makeManager { true }
        let settings = SplashSettings(keepRunning: true, profiles: [SplashProfile(name: "p", model: "m")])
        await m.configure(settings: settings)
        #expect(m.state == .running(profile: "p", since: m.stateRunningSince!, adopted: true))
        #expect(m.launchCount == 0)
        #expect(m.canStop == false)
    }

    @Test func adoptedDeathTakesOverWithOwnedStart() async throws {
        // probe answers for the first sweep(s), then stops answering
        let box = LockedBox(value: true)
        let m = makeManager { box.load() }
        let settings = SplashSettings(keepRunning: true, profiles: [SplashProfile(name: "p", model: "m")])
        await m.configure(settings: settings)
        #expect(m.state == .running(profile: "p", since: m.stateRunningSince!, adopted: true))
        box.store(false)
        await m.runAdoptedSweepNow()   // test hook: two sweeps = takeover
        await m.runAdoptedSweepNow()
        #expect(m.launchCount == 1)
        if case .starting = m.state {} else {
            Issue.record("expected owned start after adopted death, got \(m.state)")
        }
        await m.terminateFromApp()
    }
}

/// Tiny atomic box for probe closures shared across sendable closures.
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(value: T) { v = value }
    func load() -> T { lock.withLock { v } }
    func store(_ n: T) { lock.withLock { v = n } }
}

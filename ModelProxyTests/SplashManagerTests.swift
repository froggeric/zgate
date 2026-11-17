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

/// Clock whose FIRST sleep parks on a gate the test opens — makes a
/// stop-vs-replacement-start interleave deterministic (the stop is held
/// inside its grace window while the replacement start runs to completion;
/// no wake-order race between two parked grace loops).
@MainActor final class GatedSplashClock: SplashClock, @unchecked Sendable {
    let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_700_000_000)
    private var gate: CheckedContinuation<Void, Never>?
    private var gateOpened = false
    private var sleeps = 0
    /// True once the gated first sleep is parked.
    var gateParked: Bool { lock.withLock { gate != nil } }
    nonisolated init() {}   // default-arg expressions are checked nonisolated
    func now() -> Date { lock.withLock { current } }
    func sleep(seconds: TimeInterval) async throws {
        let gated = lock.withLock { () -> Bool in
            sleeps += 1
            if sleeps == 1 && !gateOpened { return true }
            current = current.addingTimeInterval(seconds)
            return false
        }
        if gated {
            await withCheckedContinuation { c in lock.withLock { gate = c } }
            lock.withLock { current = current.addingTimeInterval(seconds) }
        }
    }
    /// Release the parked first sleep (idempotent).
    func openGate() {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            gateOpened = true
            let w = gate
            gate = nil
            return w
        }
        waiter?.resume()
    }
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

    @Test func stopRacingReplacementStartKeepsReplacementChild() async throws {
        // I2 regression (fix round 1): a stop parked in its grace window
        // while a replacement start spawns a new child must not erase (or
        // signal) that child in its epilogue — the old unconditional
        // `child = nil` orphaned the replacement (UI .stopped + canStop
        // false while it still served on :8000; quit-time cleanup then saw
        // child == nil and let it survive the app). The gated clock parks
        // the stop's FIRST grace poll until the test opens the gate, so the
        // replacement start provably completes inside the grace window.
        let clock = GatedSplashClock()
        let ignoreTerm = LockedBox(value: true)
        let m = SplashManager(
            binaryPathProvider: { try! writeSplashStub(ignoreTerm: ignoreTerm.load()) },
            clock: clock, probe: { true })
        try await m.start(profile: SplashProfile(name: "a", model: "m"))
        try await waitForStubStdout(m)   // A executing; TERM trap armed
        ignoreTerm.store(false)          // the replacement child obeys TERM
        let stopTask = Task { await m.stop() }
        // Wait for the stop to park inside its grace window (first clock sleep).
        let parkedBy = Date().addingTimeInterval(5)
        while !clock.gateParked, Date() < parkedBy {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(clock.gateParked)
        // Replacement start INSIDE the grace window: its own stopChildIfAny
        // escalates to SIGKILL on A, then B spawns and reaches running.
        try await m.start(profile: SplashProfile(name: "b", model: "m"))
        clock.openGate()
        await stopTask.value
        // The stop's epilogue must not erase the replacement child: B stays
        // tracked, running and stoppable.
        #expect(m.child != nil)
        #expect(m.canStop)
        #expect(m.state == .running(profile: "b", since: m.stateRunningSince!, adopted: false))
        try await m.stop()   // cleanup: replacement obeys TERM, reaps cleanly
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

    @Test func togglingKeepRunningOffStandsDownSupervision() async throws {
        // F1 regression (final review): settings reached the manager only at
        // launch, so after the UI toggle flipped keepRunning OFF the adopted
        // takeover and backoff-relaunch guards still read a stale true and
        // respawned against user intent. Two windows, both pinned here:
        // (a) adopted — toggle off, external dies, sweeps must NOT take over;
        // (b) crashed-in-backoff — toggle off while the relaunch is parked in
        //     its backoff sleep; waking it must NOT spawn.
        let on = SplashSettings(keepRunning: true, profiles: [SplashProfile(name: "p", model: "m")])
        let off = SplashSettings(keepRunning: false, profiles: [SplashProfile(name: "p", model: "m")])

        // (a) adopted window: probe answers at configure, dies after OFF.
        let box = LockedBox(value: true)
        let adopted = makeManager { box.load() }
        await adopted.configure(settings: on)
        if case .running(_, _, true) = adopted.state {} else {
            Issue.record("expected adopted running, got \(adopted.state)")
        }
        adopted.applySettings(off)   // the saveAndApply path's refresh
        #expect(adopted.state == .stopped)
        box.store(false)
        await adopted.runAdoptedSweepNow()
        await adopted.runAdoptedSweepNow()
        #expect(adopted.launchCount == 0)
        if case .stopped = adopted.state {} else {
            Issue.record("expected stopped after sweeps with keepRunning off, got \(adopted.state)")
        }

        // (b) crashed-in-backoff window: owned running (probe answers, so the
        // inline start resolves readiness without a clock sleep), crash it —
        // the backoff sleep is then the FIRST clock sleep and parks on the
        // gate; OFF while parked; open the gate and the relaunch must abort.
        let clock = GatedSplashClock()
        let stubURL = try writeSplashStub()   // stay-alive, TERM-obeying
        let parked = SplashManager(
            binaryPathProvider: { stubURL }, clock: clock, probe: { true })
        parked.applySettings(on)
        try await parked.start(profile: SplashProfile(name: "p", model: "m"))
        #expect(parked.launchCount == 1)
        if case .running = parked.state {} else {
            Issue.record("expected owned running, got \(parked.state)")
        }
        parked.child?.terminate()
        let parkedBy = Date().addingTimeInterval(5)
        while !clock.gateParked, Date() < parkedBy {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(clock.gateParked)   // exit handled; relaunch parked in backoff
        if case .crashed = parked.state {} else {
            Issue.record("expected crashed while parked in backoff, got \(parked.state)")
        }
        parked.applySettings(off)   // toggle OFF mid-backoff
        #expect(parked.state == .stopped)
        clock.openGate()   // wake the parked relaunch — must observe OFF
        #expect(parked.launchCount == 1)
        if case .stopped = parked.state {} else {
            Issue.record("expected stopped after backoff wake with keepRunning off, got \(parked.state)")
        }
        await adopted.terminateFromApp()
        await parked.terminateFromApp()
    }

    // MARK: Test-context suppression guard (Task 7, pure predicate)

    @Test func shouldSuperviseAllowsPlainEnvironment() {
        #expect(SplashManager.shouldSupervise(environment: [:]))
    }

    @Test func shouldSuperviseBlocksHostedXCTestRun() {
        // Any value counts: the runner sets a configuration-file path.
        #expect(!SplashManager.shouldSupervise(environment: [
            "XCTestConfigurationFilePath": "/var/folders/xx/test.xctestconfiguration"]))
        #expect(!SplashManager.shouldSupervise(environment: ["XCTestConfigurationFilePath": ""]))
    }

    @Test func shouldSuperviseBlocksExplicitOptOut() {
        #expect(!SplashManager.shouldSupervise(
            environment: ["ZGATE_DISABLE_SPLASH_SUPERVISION": "1"]))
    }

    @Test func shouldSuperviseIgnoresOtherValuesAndKeys() {
        #expect(SplashManager.shouldSupervise(
            environment: ["ZGATE_DISABLE_SPLASH_SUPERVISION": "0"]))
        #expect(SplashManager.shouldSupervise(environment: ["SOME_OTHER_KEY": "value"]))
    }
}

/// Tiny atomic box for probe closures shared across sendable closures.
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(value: T) { v = value }
    func load() -> T { lock.withLock { v } }
    func store(_ n: T) { lock.withLock { v = n } }
}

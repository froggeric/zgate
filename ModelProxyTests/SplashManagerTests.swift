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
        // Real settle: the stub's sh needs ~50-200 ms before its first line
        // reaches the pipe; wait so the stdout-piping criterion is observable.
        try await Task.sleep(nanoseconds: 300_000_000)
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
        // Real settle: let the stub's sh come up so TERM lands on a running
        // shell (not a pre-exec fork) and the reaping path is exercised.
        try await Task.sleep(nanoseconds: 300_000_000)
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
        // Real settle: TERM must land AFTER the stub's `trap '' TERM` line
        // executes (sh startup measured at ~50-200 ms here), or the child
        // dies pre-trap and the escalation path is never exercised.
        try await Task.sleep(nanoseconds: 300_000_000)
        try await m.stop()   // virtual grace elapses instantly via ManualClock
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
        // child exits ~instantly (after ~50-200 ms of sh startup per cycle);
        // backoff sleeps are virtual; probe true on retry. 1 s fits several
        // full relaunch cycles so launchCount >= 2 has margin.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(m.launchCount >= 2)
        if case .running = m.state {} else if case .starting = m.state {} else {
            Issue.record("expected running/starting after relaunch, got \(m.state)")
        }
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

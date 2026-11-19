import AppKit
import Darwin
import Foundation
import Observation

// MARK: - Seams

/// Clock seam. MainActor-isolated on purpose: the virtual test clock's
/// `sleep` only advances a date and must execute WITHOUT suspension so a
/// transition → backoff wait → next transition stays inside one main-actor
/// turn (intermediate states are then unobservable to samplers). The system
/// clock suspends for real, so production timing is unchanged.
@MainActor protocol SplashClock: Sendable {
    func now() -> Date
    func sleep(seconds: TimeInterval) async throws
}

struct SystemSplashClock: SplashClock {
    nonisolated init() {}   // default-arg expressions are checked nonisolated
    func now() -> Date { Date() }
    func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// One TCP/HTTP answer from 127.0.0.1:<port> = "splash is serving". Port
/// comes from SplashSettings (default 8123; was 8000 before 2026-11-18).
enum SplashPortProbe {
    static func answers(on port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/models") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.5
        return (try? await URLSession.shared.data(for: req)) != nil
    }
}

// MARK: - Ownership planning (pure)

// `nonisolated`: value type + pure logic; keeps the Equatable conformance
// usable outside the main actor (default actor isolation is MainActor here).
nonisolated enum SplashOwnership: Equatable, Sendable {
    case startOwned, adoptExternal, none
}

nonisolated enum SplashStartupPlanner: Sendable {
    static func plan(keepRunning: Bool, portAnswers: Bool, hasChild: Bool) -> SplashOwnership {
        switch (keepRunning, portAnswers, hasChild) {
        case (false, _, _): return .none
        case (true, true, false): return .adoptExternal
        case (true, true, true), (true, false, true): return .none
        case (true, false, false): return .startOwned
        }
    }
}

// MARK: - State

nonisolated enum SplashState: Equatable, Sendable {
    case stopped
    case starting(profile: String)
    case running(profile: String, since: Date, adopted: Bool)
    case crashed(profile: String, lastExit: Int32, nextRetry: Date?)
    case stopping
}

// MARK: - Manager

/// Sendable weak box so the willTerminate observer block captures nothing
/// non-Sendable across the thread boundary.
private final class WeakSplashManager: @unchecked Sendable {
    weak var manager: SplashManager?
    init(_ manager: SplashManager?) { self.manager = manager }
}

@MainActor
@Observable
final class SplashManager {
    private(set) var state: SplashState = .stopped
    private(set) var log = LogRingBuffer()
    private(set) var launchCount = 0
    private(set) var child: Process?
    /// Consecutive-failure counter feeding SplashBackoff. Visible for the
    /// accumulation pinning test (and future UI).
    private(set) var crashAttempts = 0

    static let readinessTimeout: TimeInterval = 120
    static let readinessPollInterval: TimeInterval = 0.5
    static let stopGrace: TimeInterval = 10
    static let adoptedProbeInterval: TimeInterval = 20

    /// Real-time floor between readiness polls (and between stop-grace
    /// checks): keeps a virtual clock from burning a whole deadline in
    /// microseconds and gives real children a chance to answer/exit.
    static let realPollFloorNanos: UInt64 = 2_000_000
    static let realStopFloorNanos: UInt64 = 5_000_000

    /// Stop is available only for an OWNED child (spec §3.1).
    var canStop: Bool { child != nil && state != .stopped && state != .stopping }
    var stateRunningSince: Date? {
        if case .running(_, let since, _) = state { return since }
        return nil
    }

    private var settings: SplashSettings?
    /// Running-start of the CURRENT lifecycle; nil until it reaches readiness.
    /// beginStart clears it so an exit never consults a previous lifecycle.
    private var stableSince: Date?
    private var suppressingRelaunch = false
    /// Monotonic lifecycle token; readiness loops compare it before acting so
    /// a superseded start (stop / restart / newer relaunch) never mutates state.
    private var generation = 0
    private var readinessTask: Task<Void, Never>?
    private var adoptedTask: Task<Void, Never>?
    /// Miss counter for the `runAdoptedSweepNow` test hook — same two-miss
    /// rule as the production monitor in `startAdoptedMonitoring`.
    private var adoptedMisses = 0

    private let binaryPathProvider: @Sendable () throws -> URL
    private let clock: any SplashClock
    private let probe: @Sendable (Int) async -> Bool

    init(
        binaryPathProvider: @escaping @Sendable () throws -> URL = {
            URL(fileURLWithPath: SplashManager.resolvedBinaryPath())
        },
        clock: any SplashClock = SystemSplashClock(),
        probe: @escaping @Sendable (Int) async -> Bool = { await SplashPortProbe.answers(on: $0) }
    ) {
        self.binaryPathProvider = binaryPathProvider
        self.clock = clock
        self.probe = probe
        let box = WeakSplashManager(self)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await box.manager?.terminateFromApp() }
        }
    }

    /// App-support bin dir; mirrors `AppPaths.appSupport` as a nonisolated
    /// constant so binary resolution works from any isolation.
    private static let fallbackBinDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first!.appendingPathComponent("ZGate", isDirectory: true)

    /// Binary resolution (spec §3.1): override (if present) →
    /// /opt/homebrew/bin/<chip binary> → ~/.local/bin/<chip binary> (the
    /// fork installer's fallback) → app-support bin/<chip binary>. A stale
    /// override falls through so it can never brick launches.
    nonisolated static func resolvedBinaryPath(
        override: String? = nil,
        chip: SplashChip? = SplashChip.current,
        fileExists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        homebrewBinDir: String = "/opt/homebrew/bin",
        localBinDir: String? = NSHomeDirectory() + "/.local/bin"
    ) -> String {
        if let override, fileExists(override) { return override }
        let name = (chip ?? .forkM1M2).binaryName
        let homebrew = "\(homebrewBinDir)/\(name)"
        if fileExists(homebrew) { return homebrew }
        if let localBinDir {
            let local = "\(localBinDir)/\(name)"
            if fileExists(local) { return local }
        }
        return fallbackBinDir.appendingPathComponent("bin/\(name)").path
    }

    /// Test-context suppression (owner ruling 2026-11-16: this machine cannot
    /// run two splash instances). A hosted XCTest run launches a second ZGate
    /// and XCUITest marks its app-under-test with the disable key; either way
    /// the copy in question must never supervise/stop the user's real splash.
    /// Pure so `ModelProxyApp` can guard its startup call with it.
    nonisolated static func shouldSupervise(environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] == nil
            && environment["ZGATE_DISABLE_SPLASH_SUPERVISION"] != "1"
    }

    // MARK: Configure (startup planning)

    func configure(settings: SplashSettings?) async {
        self.settings = settings
        guard let settings, settings.keepRunning else { return }
        let plan = SplashStartupPlanner.plan(
            keepRunning: settings.keepRunning,
            portAnswers: await probe(settings.port),
            hasChild: child != nil)
        switch plan {
        case .startOwned:
            // Fire-and-forget so configure never blocks startup on readiness.
            if let profile = settings.activeProfile {
                Task { await self.start(profile: profile) }
            }
        case .adoptExternal:
            if let profile = settings.activeProfile {
                state = .running(profile: profile.name, since: clock.now(), adopted: true)
                startAdoptedMonitoring(profile: profile)
            }
        case .none: break
        }
    }

    /// Settings refresh from the UI (`SplashTabModel.saveAndApply`): the
    /// manager's in-memory settings must track the persisted config, or the
    /// supervision guards below (adopted takeover, backoff relaunch) act on
    /// a stale `keepRunning == true` after the user toggles OFF — respawning
    /// against user intent while adopted or crashed-in-backoff (final-review
    /// F1). OFF stands supervision down WITHOUT signaling anything: the view
    /// owns stopping an owned child (`canStop`); adopted/external instances
    /// are never ours to signal. `beginStart` re-clears the suppression on
    /// the next deliberate start.
    func applySettings(_ newSettings: SplashSettings?) {
        settings = newSettings
        guard newSettings?.keepRunning == true else {
            suppressingRelaunch = true
            readinessTask?.cancel(); readinessTask = nil
            adoptedTask?.cancel(); adoptedTask = nil
            if child == nil { state = .stopped }
            return
        }
    }

    // MARK: Start / stop

    func start(profile: SplashProfile) async {
        await stopChildIfAny()   // restart semantics: never two children
        beginStart(profile: profile)
        // Direct starts resolve readiness inline; detached starts (configure,
        // sweep takeover) leave it to the background task.
        if let readinessTask { await readinessTask.value }
    }

    func stop() async {
        suppressingRelaunch = true
        await stopChildIfAny()
        // Only declare .stopped when no replacement child appeared while we
        // were parked stopping (rapid toggle off→on races through the grace
        // window; the newer start owns the state — and the child — now).
        if child == nil { state = .stopped }
        adoptedTask?.cancel(); adoptedTask = nil
    }

    func restart(profile: SplashProfile) async {
        await start(profile: profile)
    }

    /// App-quit path (spec §3.1): stop owned child, never relaunch.
    func terminateFromApp() async {
        suppressingRelaunch = true
        await stopChildIfAny()
        adoptedTask?.cancel(); adoptedTask = nil
        state = .stopped
    }

    /// Test hook: run one adopted-monitor sweep immediately. Mirrors one
    /// monitoring iteration with the same two-miss takeover rule as
    /// `startAdoptedMonitoring`; takeover begins the owned start without
    /// awaiting readiness so the sweep returns while still `.starting`.
    func runAdoptedSweepNow() async {
        guard adoptedTask != nil else { return }
        guard await probe(settings?.port ?? 8123) else {
            adoptedMisses += 1
            if adoptedMisses >= 2,
               case .running(_, _, true) = state,
               settings?.keepRunning == true,
               let next = settings?.activeProfile {
                adoptedMisses = 0
                beginStart(profile: next)   // owned takeover
            }
            return
        }
        adoptedMisses = 0
    }

    // MARK: Internals

    /// Spawn phase of a launch — synchronous on the main actor so `child`,
    /// `launchCount` and `state = .starting` become visible atomically.
    private func beginStart(profile: SplashProfile) {
        suppressingRelaunch = false
        adoptedTask?.cancel(); adoptedTask = nil
        adoptedMisses = 0
        // Fresh lifecycle: stability has not accrued yet. Without this, a
        // pre-readiness death would consult the PREVIOUS lifecycle's
        // stableSince and reset crashAttempts on every exit, defeating
        // backoff escalation (attempt stuck at 1 forever).
        stableSince = nil
        generation += 1
        let g = generation
        state = .starting(profile: profile.name)
        do {
            let p = Process()
            p.executableURL = try effectiveBinaryPath()
            p.arguments = profile.serveArguments(
                port: settings?.port ?? 8123, storage: settings?.storage)
            // Storage override (spec §3.6): HF_HUB_CACHE rides the inherited
            // environment; without this the child sees ZGate's env verbatim.
            if let env = settings?.storage?.environment {
                p.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
            }
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err
            Self.wire(pipe: out, into: self)
            Self.wire(pipe: err, into: self)
            wireExitWatch(for: p, profile: profile)   // before run: no exit race
            try p.run()
            child = p
            launchCount += 1
            spawnReadinessTask(profile: profile, generation: g)
        } catch {
            readinessTask?.cancel(); readinessTask = nil
            log.append("launch failed: \(error.localizedDescription)")
            state = .crashed(profile: profile.name, lastExit: -1, nextRetry: nil)
        }
    }

    private func effectiveBinaryPath() throws -> URL {
        if let override = settings?.binaryPathOverride {
            return URL(fileURLWithPath: Self.resolvedBinaryPath(override: override))
        }
        return try binaryPathProvider()
    }

    private func spawnReadinessTask(profile: SplashProfile, generation g: Int) {
        readinessTask?.cancel()
        readinessTask = Task { [weak self] in
            guard let self else { return }
            let deadline = self.clock.now().addingTimeInterval(Self.readinessTimeout)
            while self.clock.now() < deadline {
                if Task.isCancelled { return }
                if await self.probe(self.settings?.port ?? 8123) {
                    guard self.generation == g,
                          case .starting(profile.name) = self.state else { return }
                    self.becameRunning(profile: profile, adopted: false)
                    return
                }
                if Task.isCancelled { return }
                try? await self.clock.sleep(seconds: Self.readinessPollInterval)
                try? await Task.sleep(nanoseconds: Self.realPollFloorNanos)
            }
            guard self.generation == g,
                  case .starting(profile.name) = self.state else { return }
            self.killChild()
            self.state = .crashed(profile: profile.name, lastExit: -1, nextRetry: nil)
        }
    }

    private func becameRunning(profile: SplashProfile, adopted: Bool) {
        crashAttempts = 0
        stableSince = clock.now()
        state = .running(profile: profile.name, since: clock.now(), adopted: adopted)
    }

    /// Registers the exit watch. Uses `terminationHandler` — it fires on a
    /// Foundation background queue. `await p.waitUntilExit()` must NEVER run
    /// on the main actor: under nonsending async it executes inline there and
    /// the blocking call deadlocks the app while the child is alive.
    /// Registered before `run` so an instant-exit child cannot race it.
    private func wireExitWatch(for p: Process, profile: SplashProfile) {
        p.terminationHandler = { [weak self] process in
            Task { @MainActor in
                await self?.handleChildExit(process, profile: profile)
            }
        }
    }

    /// Unexpected-exit handling and relaunch, run INLINE in the exit watch.
    /// `crashed → backoff sleep → start` is one uninterrupted main-actor turn
    /// under the virtual clock (the intermediate `crashed` sample is
    /// unobservable), while the system clock suspends for real so production
    /// shows crashed-with-retry for the whole backoff duration.
    private func handleChildExit(_ p: Process, profile: SplashProfile) async {
        guard p === child else { return }   // stopped-then-replaced: ignore
        child = nil
        let keepRunning = settings?.keepRunning ?? false
        guard !suppressingRelaunch, keepRunning else {
            if state != .stopped { state = .stopped }
            return
        }
        // Stability reset (spec §3.1): only THIS lifecycle's stability counts.
        // stableSince is nil unless this launch reached readiness (beginStart
        // clears it), so consecutive pre-readiness deaths keep accumulating
        // attempts up to the cap, and a crash after a genuinely stable run
        // (readiness + >= stableReset of running) restarts at attempt 1.
        if let stable = stableSince,
           clock.now().timeIntervalSince(stable) >= SplashBackoff.stableReset {
            crashAttempts = 0
        }
        crashAttempts += 1
        let delay = SplashBackoff.delay(attempt: crashAttempts)
        state = .crashed(
            profile: profile.name, lastExit: p.terminationStatus,
            nextRetry: clock.now().addingTimeInterval(delay))
        generation += 1   // stale readiness loops must not act
        try? await clock.sleep(seconds: delay)
        guard !suppressingRelaunch,
              case .crashed(let name, _, _) = state, name == profile.name,
              let next = settings?.activeProfile else { return }
        await start(profile: next)
    }

    private func startAdoptedMonitoring(profile: SplashProfile) {
        adoptedTask?.cancel()
        var misses = 0
        adoptedTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await self.clock.sleep(seconds: Self.adoptedProbeInterval)
                guard await self.probe(self.settings?.port ?? 8123) else {
                    misses += 1
                    if misses >= 2 {
                        guard case .running(_, _, true) = self.state,
                              self.settings?.keepRunning == true,
                              let next = self.settings?.activeProfile else { return }
                        await self.start(profile: next)   // owned takeover
                        return
                    }
                    continue
                }
                misses = 0
            }
        }
    }

    private func stopChildIfAny() async {
        generation += 1
        readinessTask?.cancel(); readinessTask = nil
        guard let p = child else { return }
        state = .stopping
        p.terminate()   // SIGTERM
        let deadline = clock.now().addingTimeInterval(Self.stopGrace)
        while p.isRunning && clock.now() < deadline {
            try? await clock.sleep(seconds: 0.2)
            // Real floor so a TERM-obeying child can actually exit before
            // escalation even under the instant virtual clock.
            try? await Task.sleep(nanoseconds: Self.realStopFloorNanos)
        }
        if p.isRunning {
            // Escalation hits OUR captured process only: the tracked child
            // may since have been replaced by a newer start that raced
            // through the grace window — never SIGKILL the replacement.
            if child === p { kill(p.processIdentifier, SIGKILL) }
        }
        _ = try? p.waitUntilExit()
        // Identity-guarded epilogue: erasing a replacement child here would
        // orphan it (UI .stopped + canStop false while it still serves on
        // :8000) and defeat quit-time cleanup, which consults `child`.
        if child === p { child = nil }
    }

    private func killChild() {
        guard let p = child, p.isRunning else { child = nil; return }
        kill(p.processIdentifier, SIGKILL)
        _ = try? p.waitUntilExit()
        child = nil
    }

    /// Pipes child output lines into the ring buffer (main-actor hops).
    nonisolated private static func wire(pipe: Pipe, into manager: SplashManager) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            guard !lines.isEmpty else { return }
            Task { @MainActor in
                for line in lines { manager.log.append(String(line)) }
            }
        }
    }
}

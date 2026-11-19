import Foundation
import Testing
@testable import ZGate

/// Apply side of locked decision 2 (spec §3.4): UpdateCenter drives the
/// tarball/brew apply through injected seams — one at a time, macOS-gated,
/// post-apply verified — while the SplashManager hooks decide WHEN. No
/// network, no subprocess: fetch is a URL-keyed stub, the apply seams
/// record, and the manager is a real one whose stub binary only spawns
/// where a test needs an owned child.
@MainActor
@Suite struct UpdateCenterApplyTests {

    // MARK: - Fixtures

    private func splashFixture(tag: String) -> Data {
        Data(
            #"{"tag_name":"\#(tag)","assets":[{"name":"splash-\#(tag)-arm64-macos26.tar.gz","browser_download_url":"https://github.com/paperniuk/splash/releases/download/\#(tag)/splash-\#(tag)-arm64-macos26.tar.gz"}]}"#
                .utf8)
    }

    private func zgateFixture(tag: String) -> Data {
        Data(
            #"{"tag_name":"\#(tag)","assets":[{"name":"ZGate-\#(tag).zip","browser_download_url":"https://github.com/froggeric/zgate/releases/download/\#(tag)/ZGate-\#(tag).zip","digest":"sha256:\#(String(repeating: "ab", count: 32))"}]}"#
                .utf8)
    }

    /// Serves an available splash update (fork tag by default) + an
    /// up-to-date ZGate release so `checkNow` completes both halves.
    private func serveUpdateAvailable(
        stub: FetchStub, tag: String = "1.7.0-m1", chip: SplashChip = .forkM1M2
    ) {
        stub.serve(splashFixture(tag: tag), for: SplashChip.releasesURL(for: chip))
        stub.serve(zgateFixture(tag: "v2.8.9"), for: UpdateCenter.zgateReleasesURL)
    }

    /// URL-keyed fetch stub (UpdateCenterTests' shape); an unserved URL
    /// throws — the nil-on-failure path.
    private final class FetchStub: @unchecked Sendable {
        private let lock = NSLock()
        private var fixtures: [URL: Data] = [:]

        func serve(_ data: Data, for url: URL) {
            lock.lock(); defer { lock.unlock() }
            fixtures[url] = data
        }

        func fetch(_ url: URL) throws -> Data {
            lock.lock(); defer { lock.unlock() }
            guard let data = fixtures[url] else {
                throw URLError(.notConnectedToInternet)
            }
            return data
        }
    }

    /// Thread-safe apply-seam recorder.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var forkCalls: [String] = []
        private var brewCalls: [[String]] = []
        var fork: [String] { lock.withLock { forkCalls } }
        var brew: [[String]] { lock.withLock { brewCalls } }
        func recordFork(_ tag: String) { lock.withLock { forkCalls.append(tag) } }
        func recordBrew(_ argv: [String]) { lock.withLock { brewCalls.append(argv) } }
    }

    private func makeCenter(
        stub: FetchStub,
        installed: LockedBox<String?>,
        os: OperatingSystemVersion = OperatingSystemVersion(
            majorVersion: 26, minorVersion: 4, patchVersion: 0),
        applyFork: @escaping @Sendable (SplashRelease) async throws -> String,
        applyBrew: @escaping @Sendable ([String]) async throws -> Void = { _ in }
    ) -> UpdateCenter {
        UpdateCenter(deps: UpdateCenter.Deps(
            fetch: { try stub.fetch($0) },
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            installedSplashVersion: { _ in installed.load() },
            currentZGateVersion: { (2, 8, 9) },
            osVersion: { os },
            applyFork: applyFork,
            applyBrew: applyBrew))
    }

    /// The success-path fork seam: records the attempt, makes the install
    /// "take" (the version seam answers the new tag), returns the tag.
    private func installingFork(
        installed: LockedBox<String?>, _ recorder: Recorder
    ) -> @Sendable (SplashRelease) async throws -> String {
        { release in
            recorder.recordFork(release.tag_name)
            installed.store(release.tag_name)
            return release.tag_name
        }
    }

    /// Real manager for its state machine only: fresh = .stopped (nothing
    /// ever spawned), `start` for owned-running, `configure` for adopted.
    private func makeManager() -> SplashManager {
        SplashManager(
            binaryPathProvider: { try! writeSplashStub() },
            clock: SplashManagerTests.ManualClock(),
            probe: { _ in true })
    }

    /// Bounded real-time poll (fire-and-forget hooks land as Tasks).
    private func waitUntil(
        timeout: TimeInterval = 10, _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Auto-apply matrix (stopped / owned / adopted)

    @Test func stoppedAndAutoApplyAppliesImmediately() async throws {
        let stub = FetchStub()
        serveUpdateAvailable(stub: stub)
        let installed = LockedBox<String?>(value: "1.6.1-m1.1")
        let recorder = Recorder()
        let center = makeCenter(
            stub: stub, installed: installed,
            applyFork: installingFork(installed: installed, recorder))
        let manager = makeManager()   // .stopped — never started
        center.attach(to: manager)

        // checkNow → evaluateAutoApply → apply → verify → checkNow runs
        // awaited inline; nothing on this path is fire-and-forget.
        await center.checkNow(chip: .forkM1M2)

        #expect(recorder.fork == ["1.7.0-m1"])
        #expect(center.splashState == .upToDate(installed: "1.7.0-m1"))
        #expect(!center.splashAlert)
    }

    @Test func runningOwnedDefersUntilStopHook() async throws {
        let stub = FetchStub()
        serveUpdateAvailable(stub: stub)
        let installed = LockedBox<String?>(value: "1.6.1-m1.1")
        let recorder = Recorder()
        let center = makeCenter(
            stub: stub, installed: installed,
            applyFork: installingFork(installed: installed, recorder))
        let manager = makeManager()
        try await manager.start(profile: SplashProfile(name: "p", model: "m"))
        if case .running(_, _, false) = manager.state {} else {
            Issue.record("expected owned running, got \(manager.state)")
        }
        center.attach(to: manager)

        await center.checkNow(chip: .forkM1M2)
        #expect(recorder.fork.isEmpty)   // deferred: engine still running

        // Deliberate owned stop → ownedStoppedHook (fire-and-forget) → apply.
        try await waitUntil { manager.log.lines.contains("stub up") }
        await manager.stop()
        try await waitUntil { !recorder.fork.isEmpty }
        #expect(recorder.fork == ["1.7.0-m1"])
        #expect(center.splashState == .upToDate(installed: "1.7.0-m1"))
    }

    @Test func runningAdoptedNeverApplies() async throws {
        let stub = FetchStub()
        serveUpdateAvailable(stub: stub)
        let installed = LockedBox<String?>(value: "1.6.1-m1.1")
        let recorder = Recorder()
        let center = makeCenter(
            stub: stub, installed: installed,
            applyFork: installingFork(installed: installed, recorder))
        let manager = makeManager()
        await manager.configure(
            settings: SplashSettings(
                keepRunning: true, profiles: [SplashProfile(name: "p", model: "m")]))
        if case .running(_, _, true) = manager.state {} else {
            Issue.record("expected adopted running, got \(manager.state)")
        }
        center.attach(to: manager)

        await center.checkNow(chip: .forkM1M2)
        #expect(recorder.fork.isEmpty)
        await center.evaluateAutoApply()   // even a direct nudge must not touch it
        #expect(recorder.fork.isEmpty)
        // Banner only — the availability verdict itself stands.
        #expect(center.splashState == .available(installed: "1.6.1-m1.1", latest: "1.7.0-m1"))
        await manager.terminateFromApp()
    }

    @Test func autoApplyDisabledNeverApplies() async throws {
        let stub = FetchStub()
        serveUpdateAvailable(stub: stub)
        let installed = LockedBox<String?>(value: "1.6.1-m1.1")
        let recorder = Recorder()
        let center = makeCenter(
            stub: stub, installed: installed,
            applyFork: installingFork(installed: installed, recorder))
        center.attach(
            configLoad: { UpdateSettings(splashAutoApply: false) },
            configWrite: { _ in })
        let manager = makeManager()   // stopped — but auto-apply is OFF
        center.attach(to: manager)

        await center.checkNow(chip: .forkM1M2)
        #expect(recorder.fork.isEmpty)
        #expect(center.splashState == .available(installed: "1.6.1-m1.1", latest: "1.7.0-m1"))
    }

    // MARK: - Guards

    /// Post-apply verify (spec §3.4): the seam "installed" but the version
    /// still answers the OLD tag → .failed, never a stale available banner.
    @Test func verifyMismatchFails() async throws {
        let stub = FetchStub()
        serveUpdateAvailable(stub: stub)
        let installed = LockedBox<String?>(value: "1.6.1-m1.1")
        let recorder = Recorder()
        let center = makeCenter(
            stub: stub, installed: installed,
            applyFork: { release in   // reports success, changes nothing
                recorder.recordFork(release.tag_name)
                return release.tag_name
            })
        // Strong local: the center holds the manager WEAKLY (production
        // wiring keeps it alive in the app context).
        let manager = makeManager()
        center.attach(to: manager)

        await center.checkNow(chip: .forkM1M2)

        #expect(recorder.fork == ["1.7.0-m1"])   // attempted exactly once
        guard case .failed(let message) = center.splashState else {
            Issue.record("expected failed, got \(center.splashState)")
            return
        }
        #expect(message.contains("1.6.1-m1.1"))
        #expect(!center.splashAlert)
        #expect(!center.hasActiveAlert)
    }

    @Test func concurrentApplyIsGuarded() async throws {
        let stub = FetchStub()
        serveUpdateAvailable(stub: stub)
        let installed = LockedBox<String?>(value: "1.6.1-m1.1")
        let recorder = Recorder()
        let center = makeCenter(
            stub: stub, installed: installed,
            applyFork: { release in
                recorder.recordFork(release.tag_name)
                // Hold the in-flight window so the sibling call reaches the
                // guard while this apply is still running.
                try await Task.sleep(for: .seconds(0.5))
                installed.store(release.tag_name)
                return release.tag_name
            })
        // No manager attached: the trailing evaluateAutoApply can't apply,
        // so the state sits at .available for the two direct calls.
        await center.checkNow(chip: .forkM1M2)
        #expect(center.splashState == .available(installed: "1.6.1-m1.1", latest: "1.7.0-m1"))

        async let first: Void = center.applySplashUpdate()
        async let second: Void = center.applySplashUpdate()
        await first
        await second

        #expect(recorder.fork.count == 1)   // one apply at a time
        #expect(center.splashState == .upToDate(installed: "1.7.0-m1"))
    }

    /// Both repos need macOS 26.4 (spec §3.2): below it the apply refuses
    /// without ever reaching a download.
    @Test func macOSSuppressedRefuses() async throws {
        let stub = FetchStub()
        serveUpdateAvailable(stub: stub)
        let installed = LockedBox<String?>(value: "1.6.1-m1.1")
        let recorder = Recorder()
        let center = makeCenter(
            stub: stub, installed: installed,
            os: OperatingSystemVersion(majorVersion: 15, minorVersion: 7, patchVersion: 0),
            applyFork: installingFork(installed: installed, recorder))
        await center.checkNow(chip: .forkM1M2)   // no manager → no auto path

        await center.applySplashUpdate()

        #expect(recorder.fork.isEmpty)   // never downloaded
        guard case .failed(let message) = center.splashState else {
            Issue.record("expected failed, got \(center.splashState)")
            return
        }
        #expect(message == "needs macOS 26.4+")
        #expect(!center.splashAlert)
    }

    // MARK: - Brew branch (official chip)

    @Test func officialChipAppliesViaBrew() async throws {
        let stub = FetchStub()
        serveUpdateAvailable(stub: stub, tag: "1.7.0", chip: .officialM3Plus)
        let installed = LockedBox<String?>(value: "1.6.1")
        let recorder = Recorder()
        let center = makeCenter(
            stub: stub, installed: installed,
            applyFork: { release in
                recorder.recordFork(release.tag_name)
                return release.tag_name
            },
            applyBrew: { argv in
                recorder.recordBrew(argv)
                installed.store("1.7.0")   // brew upgrade answers
            })
        let manager = makeManager()
        center.attach(to: manager)   // stopped

        await center.checkNow(chip: .officialM3Plus)

        #expect(recorder.fork.isEmpty)   // the fork seam is never touched
        // .available implies an installed version → the upgrade verb.
        #expect(recorder.brew == [SplashInstaller.brewArguments(installed: true)])
        #expect(center.splashState == .upToDate(installed: "1.7.0"))
    }
}

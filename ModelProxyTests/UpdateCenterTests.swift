import Foundation
import Testing
@testable import ZGate

/// UpdateCenter behavior (spec §3.4) through the pure seams: a URL-keyed
/// fetch stub, a fixed clock, injected installed/current versions. No
/// network, no subprocess; the 24 h repeat timer is parked on a real 1 h
/// sleep (cancelled when the center deallocates).
@MainActor
@Suite struct UpdateCenterTests {

    // MARK: - Fixtures

    private func splashFixture(tag: String) -> Data {
        Data(
            #"{"tag_name":"\#(tag)","assets":[{"name":"splash-\#(tag)-arm64-macos26.tar.gz","browser_download_url":"https://github.com/paperniuk/splash/releases/download/\#(tag)/splash-\#(tag)-arm64-macos26.tar.gz"}]}"#
                .utf8)
    }

    /// `digest: nil` omits the key — the cannotCheck asset shape.
    private func zgateFixture(
        tag: String,
        digest: String? = "sha256:" + String(repeating: "ab", count: 32)
    ) -> Data {
        var asset = #"{"name":"ZGate-\#(tag).zip","browser_download_url":"https://github.com/froggeric/zgate/releases/download/\#(tag)/ZGate-\#(tag).zip""#
        if let digest { asset += #","digest":"\#(digest)""# }
        asset += "}"
        return Data(#"{"tag_name":"\#(tag)","assets":[\#(asset)]}"#.utf8)
    }

    /// URL-keyed fetch stub + request log. An unserved URL throws (the
    /// nil-on-failure path). Lock-guarded: the fetch seam is @Sendable.
    private final class FetchStub: @unchecked Sendable {
        private let lock = NSLock()
        private var fixtures: [URL: Data] = [:]
        private var requests: [URL] = []

        var requested: [URL] {
            lock.lock(); defer { lock.unlock() }
            return requests
        }

        func serve(_ data: Data, for url: URL) {
            lock.lock(); defer { lock.unlock() }
            fixtures[url] = data
        }

        func fetch(_ url: URL) throws -> Data {
            lock.lock(); defer { lock.unlock() }
            requests.append(url)
            guard let data = fixtures[url] else {
                throw URLError(.notConnectedToInternet)
            }
            return data
        }
    }

    private func makeCenter(
        stub: FetchStub,
        installed: String? = "1.6.1-m1.1",
        current: (Int, Int, Int)? = (2, 8, 9),
        now: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> UpdateCenter {
        UpdateCenter(deps: UpdateCenter.Deps(
            fetch: { try stub.fetch($0) },
            now: { now },
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            installedSplashVersion: { _ in installed },
            currentZGateVersion: { current }))
    }

    /// Steppable sleep seam — a virtual 24 h clock for the repeat loop:
    /// each `step()` releases exactly one parked sleep (or arms the next
    /// one to pass straight through), so a test walks cycle boundaries
    /// deterministically. Task cancellation is honored like Task.sleep
    /// (parked waiters resume and throw).
    private final class StepClock: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        var isParked: Bool {
            lock.lock(); defer { lock.unlock() }
            return !waiters.isEmpty
        }

        func sleep(_ seconds: TimeInterval) async throws {
            await withTaskCancellationHandler {
                await withCheckedContinuation { c in
                    lock.lock()
                    if armed {
                        armed = false
                        lock.unlock()
                        c.resume()
                        return
                    }
                    waiters.append(c)
                    lock.unlock()
                }
            } onCancel: {
                self.resumeAll()
            }
            if Task.isCancelled { throw CancellationError() }
        }

        /// Let exactly one sleep pass: resume the parked waiter, or arm
        /// the next sleep call to return immediately.
        func step() {
            lock.lock()
            if waiters.isEmpty {
                armed = true
                lock.unlock()
                return
            }
            let all = waiters
            waiters = []
            lock.unlock()
            all.forEach { $0.resume() }
        }

        private func resumeAll() {
            lock.lock()
            let all = waiters
            waiters = []
            lock.unlock()
            all.forEach { $0.resume() }
        }
    }

    /// Bounded poll for MainActor state the repeat loop flips from its
    /// own task (same shape as UpdateCenterApplyTests.waitUntil).
    private func waitFor(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Splash check

    @Test func forkUpdateAvailableFromTags() async {
        let stub = FetchStub()
        stub.serve(splashFixture(tag: "1.7.0-m1"), for: SplashChip.releasesURL(for: .forkM1M2))
        stub.serve(zgateFixture(tag: "v2.8.9"), for: UpdateCenter.zgateReleasesURL)
        let center = makeCenter(stub: stub)
        await center.checkNow(chip: .forkM1M2)
        #expect(center.splashState == .available(installed: "1.6.1-m1.1", latest: "1.7.0-m1"))
        #expect(center.splashAlert)
    }

    @Test func upToDateWhenTagsEqual() async {
        let stub = FetchStub()
        stub.serve(splashFixture(tag: "1.6.1-m1.1"), for: SplashChip.releasesURL(for: .forkM1M2))
        stub.serve(zgateFixture(tag: "v2.8.9"), for: UpdateCenter.zgateReleasesURL)
        let center = makeCenter(stub: stub)
        await center.checkNow(chip: .forkM1M2)
        #expect(center.splashState == .upToDate(installed: "1.6.1-m1.1"))
        #expect(!center.splashAlert)
    }

    @Test func notInstalledWhenNoBinaryAndNoReleaseJSON() async {
        let stub = FetchStub()
        stub.serve(splashFixture(tag: "1.7.0-m1"), for: SplashChip.releasesURL(for: .forkM1M2))
        stub.serve(zgateFixture(tag: "v2.8.9"), for: UpdateCenter.zgateReleasesURL)
        let center = makeCenter(stub: stub, installed: nil)
        await center.checkNow(chip: .forkM1M2)
        #expect(center.splashState == .notInstalled)
        #expect(!center.splashAlert)
    }

    /// Per-chip repo selection (spec §3.1): the official chip checks incoai.
    @Test func splashRepoFollowsChip() async {
        let stub = FetchStub()
        stub.serve(splashFixture(tag: "1.7.0"), for: SplashChip.releasesURL(for: .officialM3Plus))
        stub.serve(zgateFixture(tag: "v2.8.9"), for: UpdateCenter.zgateReleasesURL)
        let center = makeCenter(stub: stub, installed: "1.6.1")
        await center.checkNow(chip: .officialM3Plus)
        #expect(center.splashState == .available(installed: "1.6.1", latest: "1.7.0"))
        #expect(stub.requested.contains { $0.path.hasSuffix("repos/incoai/splash/releases/latest") })
    }

    // MARK: - Failure never alerts

    @Test func fetchFailureNeverAlerts() async {
        let stub = FetchStub()  // nothing served — every fetch throws
        let center = makeCenter(stub: stub, installed: nil)
        await center.checkNow(chip: .forkM1M2)
        #expect(center.splashState == .unknown)
        #expect(center.zgateState == .cannotCheck)
        #expect(!center.hasActiveAlert)
    }

    // MARK: - Dismissal

    @Test func dismissedTagSuppressesUntilNewer() async {
        let stub = FetchStub()
        stub.serve(splashFixture(tag: "1.7.0-m1"), for: SplashChip.releasesURL(for: .forkM1M2))
        stub.serve(zgateFixture(tag: "v2.8.9"), for: UpdateCenter.zgateReleasesURL)
        let center = makeCenter(stub: stub)
        await center.checkNow(chip: .forkM1M2)
        #expect(center.hasActiveAlert)

        center.dismissSplash(tag: "1.7.0-m1")
        #expect(!center.splashAlert)
        #expect(!center.hasActiveAlert)

        // A newer tag expires the dismissal automatically.
        stub.serve(splashFixture(tag: "1.8.0-m1"), for: SplashChip.releasesURL(for: .forkM1M2))
        await center.checkNow(chip: .forkM1M2)
        #expect(center.splashState == .available(installed: "1.6.1-m1.1", latest: "1.8.0-m1"))
        #expect(center.splashAlert)
        #expect(center.hasActiveAlert)
    }

    // MARK: - ZGate check

    @Test func zgateTripleCompare() async {
        let stub = FetchStub()
        stub.serve(zgateFixture(tag: "v2.8.9"), for: UpdateCenter.zgateReleasesURL)
        let center = makeCenter(stub: stub)
        await center.checkNow(splash: false)
        #expect(center.zgateState == .upToDate)

        stub.serve(zgateFixture(tag: "v2.9.0"), for: UpdateCenter.zgateReleasesURL)
        await center.checkNow(splash: false)
        #expect(center.zgateState == .available(tag: "v2.9.0", current: "2.8.9"))
        #expect(center.zgateAlert)
    }

    @Test func zgateAssetWithoutDigestCannotCheck() async {
        let stub = FetchStub()
        stub.serve(zgateFixture(tag: "v2.9.0", digest: nil), for: UpdateCenter.zgateReleasesURL)
        let center = makeCenter(stub: stub)
        await center.checkNow(splash: false)
        #expect(center.zgateState == .cannotCheck)
        #expect(!center.hasActiveAlert)
    }

    /// Regression (2026-11-23): the check answered `cannotCheck` from the day
    /// it shipped — it looked for `ZGate-v<tag>.zip`, while every published
    /// release names its asset `ZGate-<version>.zip` (no `v`). The fixtures
    /// above were written in the invented shape, so they stayed green. This
    /// is the real `releases/latest` shape captured from the wire on
    /// 2026-11-23 (GitHub's extra fields omitted: the decoder reads name,
    /// browser_download_url and digest only).
    private func publishedV2113Payload() -> Data {
        Data(
            #"{"tag_name":"v2.11.3","assets":[{"name":"ZGate-2.11.3.zip","browser_download_url":"https://github.com/froggeric/zgate/releases/download/v2.11.3/ZGate-2.11.3.zip","digest":"sha256:\#(String(repeating: "ab", count: 32))","size":27959525,"content_type":"application/zip","state":"uploaded"}]}"#
                .utf8)
    }

    @Test func publishedAssetNameChecksCleanly() async {
        let stub = FetchStub()
        stub.serve(publishedV2113Payload(), for: UpdateCenter.zgateReleasesURL)

        // Behind the release: a real verdict and the alert, not cannotCheck.
        let behind = makeCenter(stub: stub, current: (2, 11, 2))
        await behind.checkNow(splash: false)
        #expect(behind.zgateState == .available(tag: "v2.11.3", current: "2.11.2"))
        #expect(behind.zgateAlert)

        // On the release: up to date.
        let current = makeCenter(stub: stub, current: (2, 11, 3))
        await current.checkNow(splash: false)
        #expect(current.zgateState == .upToDate)
        #expect(!current.hasActiveAlert)
    }

    /// Review fix 1: a failed current-version read must never fabricate an
    /// update alert — unparseable running version + valid latest → the
    /// honest degraded state, no alert.
    @Test func unparseableCurrentVersionNeverAlerts() async {
        let stub = FetchStub()
        stub.serve(zgateFixture(tag: "v2.9.0"), for: UpdateCenter.zgateReleasesURL)
        let center = makeCenter(stub: stub, current: nil)
        await center.checkNow(splash: false)
        #expect(center.zgateState == .cannotCheck)
        #expect(!center.zgateAlert)
        #expect(!center.hasActiveAlert)
    }

    @Test func zgateTagParse() {
        #expect(ZGateVersion.parse(tag: "v2.8.9")! == (2, 8, 9))
        #expect(ZGateVersion.parse(tag: "2.8.9")! == (2, 8, 9))
        #expect(ZGateVersion.parse(tag: "v2.8") == nil)
        #expect(ZGateVersion.parse(tag: "v2.8.9-beta") == nil)
        #expect(ZGateVersion.isNewer((2, 9, 0), than: (2, 8, 9)))
        #expect(ZGateVersion.isNewer((2, 8, 10), than: (2, 8, 9)))
        #expect(!ZGateVersion.isNewer((2, 8, 9), than: (2, 8, 9)))
        #expect(!ZGateVersion.isNewer((2, 8, 8), than: (2, 8, 9)))
    }

    // MARK: - Cadence

    @Test func cadenceGatesLaunchCheck() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(UpdateCadence.shouldCheck(lastCheckAt: nil, now: now))
        #expect(!UpdateCadence.shouldCheck(
            lastCheckAt: now.addingTimeInterval(-3600), now: now))
        #expect(UpdateCadence.shouldCheck(
            lastCheckAt: now.addingTimeInterval(-7 * 3600), now: now))
    }

    @Test func startChecksOnlyWhenCadenceDue() async {
        let stub = FetchStub()
        stub.serve(splashFixture(tag: "1.7.0-m1"), for: SplashChip.releasesURL(for: .forkM1M2))
        stub.serve(zgateFixture(tag: "v2.8.9"), for: UpdateCenter.zgateReleasesURL)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        // 1 h ago — launch check gated, no fetch at all.
        let recent = makeCenter(stub: stub, now: now)
        recent.attach(
            configLoad: { UpdateSettings(lastCheckAt: now.addingTimeInterval(-3600)) },
            configWrite: { _ in })
        await recent.start(splashChecksEnabled: true)
        #expect(recent.splashState == .unknown)
        #expect(stub.requested.isEmpty)

        // 7 h ago — check runs (splash + zgate fetches).
        let stale = makeCenter(stub: stub, now: now)
        stale.attach(
            configLoad: { UpdateSettings(lastCheckAt: now.addingTimeInterval(-7 * 3600)) },
            configWrite: { _ in })
        await stale.start(splashChecksEnabled: true)
        #expect(stale.splashState == .available(installed: "1.6.1-m1.1", latest: "1.7.0-m1"))
        #expect(stub.requested.count == 2)
    }

    /// Spec §4: the check-for-updates toggle gates every automatic check;
    /// manual `checkNow` is unaffected.
    @Test func autoCheckOffSkipsAutomaticChecks() async {
        let stub = FetchStub()
        stub.serve(splashFixture(tag: "1.7.0-m1"), for: SplashChip.releasesURL(for: .forkM1M2))
        stub.serve(zgateFixture(tag: "v2.8.9"), for: UpdateCenter.zgateReleasesURL)
        let center = makeCenter(stub: stub)
        center.attach(
            configLoad: { UpdateSettings(autoCheck: false) },
            configWrite: { _ in })
        await center.start(splashChecksEnabled: true)
        #expect(stub.requested.isEmpty)

        await center.checkNow(chip: .forkM1M2)
        #expect(center.splashState == .available(installed: "1.6.1-m1.1", latest: "1.7.0-m1"))
    }

    /// Fix pass: the autoCheck toggle is LIVE mid-session — the repeat
    /// loop re-reads the adopted settings every cycle, so OFF stops the
    /// scheduled checks at the next cycle boundary and ON resumes them,
    /// without a relaunch and without a timer restart.
    @Test func autoCheckToggleIsLiveInTheRepeatLoop() async throws {
        let stub = FetchStub()
        stub.serve(splashFixture(tag: "1.7.0-m1"), for: SplashChip.releasesURL(for: .forkM1M2))
        stub.serve(zgateFixture(tag: "v2.8.9"), for: UpdateCenter.zgateReleasesURL)
        let clock = StepClock()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let center = UpdateCenter(deps: UpdateCenter.Deps(
            fetch: { try stub.fetch($0) },
            now: { now },
            sleep: { try await clock.sleep($0) },
            installedSplashVersion: { _ in "1.6.1-m1.1" },
            currentZGateVersion: { (2, 8, 9) }))
        // Recent lastCheckAt: the launch check is cadence-gated, the
        // repeat loop parks in its first 24 h sleep.
        center.attach(
            configLoad: { UpdateSettings(lastCheckAt: now.addingTimeInterval(-3600)) },
            configWrite: { _ in })
        await center.start(splashChecksEnabled: true)
        try await waitFor { clock.isParked }
        #expect(stub.requested.isEmpty)

        // Toggle OFF mid-session (General tab: persist + adoptSettings)…
        center.adoptSettings(UpdateSettings(
            autoCheck: false, lastCheckAt: now.addingTimeInterval(-3600)))
        clock.step()   // 24 h pass → the cycle wakes → no fetch → sleeps again
        try await waitFor { clock.isParked }
        #expect(stub.requested.isEmpty)

        // Toggle back ON → the next cycle checks again (splash + zgate).
        center.adoptSettings(UpdateSettings(
            autoCheck: true, lastCheckAt: now.addingTimeInterval(-3600)))
        clock.step()
        try await waitFor { clock.isParked }
        #expect(stub.requested.count == 2)

        center.stop()
    }

    // MARK: - Persistence

    @Test func persistedFieldsWritten() async {
        let stub = FetchStub()
        stub.serve(splashFixture(tag: "1.7.0-m1"), for: SplashChip.releasesURL(for: .forkM1M2))
        stub.serve(zgateFixture(tag: "v2.9.0"), for: UpdateCenter.zgateReleasesURL)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let center = makeCenter(stub: stub, now: now)
        var captured: UpdateSettings?
        center.attach(configLoad: { nil }, configWrite: { captured = $0 })
        await center.checkNow(chip: .forkM1M2)
        #expect(captured?.lastSplashTag == "1.7.0-m1")
        #expect(captured?.lastZGateTag == "v2.9.0")
        #expect(captured?.lastCheckAt == now)
    }

    /// Review Focus #4: old configs carry no `update` object; a partial
    /// one decodes with defaults (tolerant, never resets).
    @Test func updateSettingsTolerantDecode() throws {
        let none = try JSONDecoder().decode(
            AppConfig.self, from: Data(#"{"vendors":[],"clients":[]}"#.utf8))
        #expect(none.update == nil)

        let partial = try JSONDecoder().decode(
            AppConfig.self,
            from: Data(#"{"vendors":[],"clients":[],"update":{"autoCheck":false}}"#.utf8))
        #expect(partial.update?.autoCheck == false)
        #expect(partial.update?.splashAutoApply == true)
        #expect(partial.update?.lastSplashTag == nil)
        #expect(partial.update?.dismissedZGateTag == nil)
    }

    // MARK: - Installed version reader (release.json, no process)

    @Test func installedVersionPrefersForkReleaseJSON() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("zgate-uc-\(UUID().uuidString)", isDirectory: true)
        let fork = tmp.appendingPathComponent("Splash-M1", isDirectory: true)
        try FileManager.default.createDirectory(
            at: fork.appendingPathComponent("current", isDirectory: true),
            withIntermediateDirectories: true)
        try Data(#"{"version":"1.6.1-m1.1"}"#.utf8)
            .write(to: fork.appendingPathComponent("current/release.json"))
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Binary path is not consulted once the fork root answers.
        #expect(SplashInstalledVersionReader.releaseJSONVersion(
            forkRoot: fork, binaryPath: nil) == "1.6.1-m1.1")
        #expect(SplashInstalledVersionReader.releaseJSONVersion(
            forkRoot: fork, binaryPath: "/opt/homebrew/bin/splash-m1") == "1.6.1-m1.1")
    }

    @Test func installedVersionWalksUpFromBinary() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("zgate-uc-\(UUID().uuidString)", isDirectory: true)
        // Cellar shape: package root 2 hops above the binary, plus a decoy
        // release.json in the binary's own directory.
        let bin = tmp.appendingPathComponent("pkg/sub/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data(#"{"version":"1.7.0"}"#.utf8)
            .write(to: tmp.appendingPathComponent("pkg/release.json"))
        try Data(#"{"version":"9.9.9"}"#.utf8)
            .write(to: bin.appendingPathComponent("release.json"))
        defer { try? FileManager.default.removeItem(at: tmp) }

        let noFork = tmp.appendingPathComponent("no-fork", isDirectory: true)
        // Parents first: the package root (2 up) outranks the binary dir.
        #expect(SplashInstalledVersionReader.releaseJSONVersion(
            forkRoot: noFork,
            binaryPath: bin.appendingPathComponent("splash").path) == "1.7.0")
        // Nothing anywhere → nil (--version fallback is the caller's job).
        #expect(SplashInstalledVersionReader.releaseJSONVersion(
            forkRoot: noFork, binaryPath: nil) == nil)
    }
}

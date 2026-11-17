import Foundation
import Testing
@testable import ZGate

@Suite @MainActor struct SplashTabModelTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func stateLineFormats() {
        #expect(SplashTabModel.stateLine(
            .running(profile: "p", since: t0, adopted: false), now: t0.addingTimeInterval(7_980))
            == "running · p · 2h 13m")
        #expect(SplashTabModel.stateLine(
            .running(profile: "p", since: t0, adopted: true), now: t0)
            == "running · p · external")
        #expect(SplashTabModel.stateLine(.starting(profile: "p"), now: t0) == "starting · p")
        #expect(SplashTabModel.stateLine(
            .crashed(profile: "p", lastExit: 1, nextRetry: t0.addingTimeInterval(12.4)), now: t0)
            == "crashed · exit 1 · retry in 12 s")
        #expect(SplashTabModel.stateLine(.stopped, now: t0) == "stopped")
        #expect(SplashTabModel.stateLine(.stopping, now: t0) == "stopping…")
    }

    @Test func buttonStatesFollowOwnership() {
        let owned = SplashTabModel.buttonStates(.running(profile: "p", since: t0, adopted: false))
        #expect(owned == (start: false, stop: true, restart: true))
        let adopted = SplashTabModel.buttonStates(.running(profile: "p", since: t0, adopted: true))
        #expect(adopted.stop == false)
        let stopped = SplashTabModel.buttonStates(.stopped)
        #expect(stopped == (start: true, stop: false, restart: false))
        let crashed = SplashTabModel.buttonStates(.crashed(profile: "p", lastExit: 1, nextRetry: nil))
        #expect(crashed.start && crashed.restart)
    }

    @Test func savePersistsAssembledSettings() async throws {
        // real manager with inert seams (probe false, no binary needed while stopped)
        let manager = SplashManager(
            binaryPathProvider: { URL(fileURLWithPath: "/nonexistent") },
            clock: ManualSplashClock(), probe: { false })
        var persisted: [SplashSettings] = []
        let model = SplashTabModel(
            manager: manager, settings: SplashSettings.defaultSeeded(),
            persist: { persisted.append($0) })
        model.keepRunning = false
        model.profiles[0].name = "renamed"
        try await model.saveAndApply()
        #expect(persisted.count == 1)
        #expect(persisted[0].keepRunning == false)
        #expect(persisted[0].profiles[0].name == "renamed")
        #expect(manager.state == .stopped)   // save alone doesn't start anything
    }

    @Test func extraArgsSplitOnWhitespace() {
        #expect(SplashProfile.parseExtraArgs(
            "--persistent-cache   --max-cache-disk 20G")
            == ["--persistent-cache", "--max-cache-disk", "20G"])
        #expect(SplashProfile.parseExtraArgs("  ") == [])
    }

    @Test func installLineComposes() {
        #expect(SplashTabModel.installLine(
            chip: "M2 Max", variant: "fork", installed: "1.6.1-m1", latest: "v1.6.2")
            == "M2 Max · fork 1.6.1-m1 installed · v1.6.2 available")
        #expect(SplashTabModel.installLine(
            chip: "M2 Max", variant: "fork", installed: nil, latest: nil)
            == "M2 Max · fork · not installed")
    }
}

/// Deterministic clock for tab-model tests.
@MainActor struct ManualSplashClock: SplashClock {
    func now() -> Date { Date(timeIntervalSince1970: 1_700_000_000) }
    func sleep(seconds: TimeInterval) async throws {}
}

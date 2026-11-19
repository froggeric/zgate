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
            clock: ManualSplashClock(), probe: { _ in false })
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

    /// Review finding 2 (2026-11-18 wave): an invalid (mid-typing) port must
    /// never reach the config — saveAndApply is a no-op until the port is
    /// valid, whatever caller invoked it.
    @Test func saveAndApplyIgnoresInvalidPort() async throws {
        let manager = SplashManager(
            binaryPathProvider: { URL(fileURLWithPath: "/nonexistent") },
            clock: ManualSplashClock(), probe: { _ in false })
        var persisted: [SplashSettings] = []
        let model = SplashTabModel(
            manager: manager, settings: SplashSettings.defaultSeeded(),
            persist: { persisted.append($0) })
        model.port = 81   // mid-typing "81": parseable Int, invalid port
        try await model.saveAndApply()
        #expect(persisted.isEmpty)   // nothing written, nothing applied
        model.port = 8123
        try await model.saveAndApply()
        #expect(persisted.count == 1 && persisted[0].port == 8123)
    }

    @Test func extraArgsSplitOnWhitespace() {
        #expect(SplashProfile.parseExtraArgs(
            "--persistent-cache   --max-cache-disk 20G")
            == ["--persistent-cache", "--max-cache-disk", "20G"])
        #expect(SplashProfile.parseExtraArgs("  ") == [])
    }

    @Test func installLineComposes() {
        #expect(SplashTabModel.installLine(
            chip: "M2 Max", variant: "fork", repo: "paperniuk/splash",
            installed: "1.6.2-m1", latest: "1.6.2-m1")
            == "M2 Max · fork · paperniuk/splash · 1.6.2-m1 installed · 1.6.2-m1 available")
        #expect(SplashTabModel.installLine(
            chip: "M2 Max", variant: "fork", repo: "paperniuk/splash", installed: nil, latest: nil)
            == "M2 Max · fork · paperniuk/splash · not installed")
        // Equal versions (and unparseable tokens, below) never append a verdict.
        #expect(SplashTabModel.installLine(
            chip: "M2 Max", variant: "fork", repo: "paperniuk/splash",
            installed: "unknown", latest: "1.7.0-m1")
            == "M2 Max · fork · paperniuk/splash · unknown installed · 1.7.0-m1 available")
    }

    // MARK: Profile delete (spec §5.2)

    private func tabModel(_ settings: SplashSettings) -> SplashTabModel {
        SplashTabModel(
            manager: SplashManager(
                binaryPathProvider: { URL(fileURLWithPath: "/nonexistent") },
                clock: ManualSplashClock(), probe: { _ in false }),
            settings: settings, persist: { _ in })
    }

    @Test func deleteActiveProfileClearsActiveID() {
        let a = SplashProfile(name: "a", model: "m-a")
        let b = SplashProfile(name: "b", model: "m-b")
        let model = tabModel(SplashSettings(
            keepRunning: false, activeProfileID: a.id, profiles: [a, b]))
        model.deleteProfile(id: a.id)
        let s = model.settings()
        #expect(s.profiles.map(\.id) == [b.id])
        #expect(s.activeProfileID == nil)
    }

    @Test func deleteInactiveProfileKeepsActiveID() {
        let a = SplashProfile(name: "a", model: "m-a")
        let b = SplashProfile(name: "b", model: "m-b")
        let model = tabModel(SplashSettings(
            keepRunning: false, activeProfileID: a.id, profiles: [a, b]))
        model.deleteProfile(id: b.id)
        let s = model.settings()
        #expect(s.profiles.map(\.id) == [a.id])
        #expect(s.activeProfileID == a.id)
    }

    @Test func deleteLastProfileLeavesNilActive() {
        let model = tabModel(SplashSettings.defaultSeeded())   // one profile, active
        model.deleteProfile(id: model.profiles[0].id)
        let s = model.settings()
        #expect(s.profiles.isEmpty)
        #expect(s.activeProfileID == nil)
        #expect(s.activeProfile == nil)   // the nil-active path Start keys on
    }

    // MARK: Install variant (spec §5.3)

    @Test func installVariantFavorsForkOnM1M2AndUnknownChips() {
        #expect(SplashTabModel.installVariant(chipKind: .forkM1M2) == .fork)
        #expect(SplashTabModel.installVariant(chipKind: nil) == .fork)
    }

    @Test func installVariantBrewsOfficialOnM3Plus() {
        #expect(SplashTabModel.installVariant(chipKind: .officialM3Plus) == .brewOfficial)
    }

    // MARK: Install row truth (spec §5, Task 9)

    @Test func installLineIncludesRepoAndVerdict() {
        #expect(SplashTabModel.installLine(
            chip: "Apple M2 Max", variant: "fork", repo: "paperniuk/splash",
            installed: "1.6.1-m1.1", latest: "1.7.0-m1") ==
            "Apple M2 Max · fork · paperniuk/splash · 1.6.1-m1.1 installed · 1.7.0-m1 available · update available")
        #expect(SplashTabModel.installLine(
            chip: "Apple M3", variant: "official", repo: "incoai/splash",
            installed: nil, latest: nil).contains("not installed"))
    }

    @Test func installButtonState() {
        let osOK = SplashChip.macOSSupportsSplash(OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 1))
        #expect(SplashTabModel.installButtonState(supportsOS: osOK, installed: nil) == (label: "Install", enabled: true))
        #expect(SplashTabModel.installButtonState(supportsOS: osOK, installed: "1.6.1-m1.1") == (label: "Update", enabled: true))
        #expect(SplashTabModel.installButtonState(supportsOS: false, installed: nil).enabled == false)
    }

    @Test func macOSGateLineOnlyBelow264() {
        #expect(SplashTabModel.macOSGateLine(
            os: OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 0)) == nil)
        #expect(SplashTabModel.macOSGateLine(
            os: OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 1)) == nil)
        #expect(SplashTabModel.macOSGateLine(
            os: OperatingSystemVersion(majorVersion: 26, minorVersion: 3, patchVersion: 1))
            == "splash needs macOS 26.4+ (this Mac: 26.3.1)")
        #expect(SplashTabModel.macOSGateLine(
            os: OperatingSystemVersion(majorVersion: 15, minorVersion: 7, patchVersion: 0)) != nil)
    }

    /// Companion fix A (Task 3 review): a legacy direct-binary override is
    /// cleared after a successful fork install unless it names a managed
    /// shim path — nil override is never touched.
    @Test func staleOverrideClearedUnlessManaged() {
        let managed = ["/opt/homebrew/bin/splash-m1", "/Users/x/.local/bin/splash-m1"]
        #expect(SplashTabModel.shouldClearOverride(current: nil, managedPaths: managed) == false)
        #expect(SplashTabModel.shouldClearOverride(
            current: "/opt/homebrew/bin/splash-m1", managedPaths: managed) == false)
        #expect(SplashTabModel.shouldClearOverride(
            current: "/Users/x/.local/bin/splash-m1", managedPaths: managed) == false)
        #expect(SplashTabModel.shouldClearOverride(
            current: "/Users/x/Library/Application Support/ZGate/bin/splash-m1",
            managedPaths: managed) == true)
    }
}

/// Deterministic clock for tab-model tests.
@MainActor struct ManualSplashClock: SplashClock {
    func now() -> Date { Date(timeIntervalSince1970: 1_700_000_000) }
    func sleep(seconds: TimeInterval) async throws {}
}

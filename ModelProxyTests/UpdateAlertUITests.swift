import AppKit
import Foundation
import Testing
@testable import ZGate

/// Task 8 alert layer (spec §5): the badge dot on the quota ring
/// (pixel-level flip + template-safe geometry constants), the menu-bar
/// accessibility string, and the banner-visibility matrix the popover
/// renders off UpdateCenter's alert accessors.
@Suite
struct UpdateAlertUITests {

    @Test("badge flips pixels on the healthy ring and the no-data ring, both template")
    func badgeChangesPixels() {
        let a = QuotaMenuBarIcon.image(weeklyFraction: 0.5, stale: false, updateAvailable: false)
        let b = QuotaMenuBarIcon.image(weeklyFraction: 0.5, stale: false, updateAvailable: true)
        #expect(a.isTemplate && b.isTemplate)
        #expect(a.tiffRepresentation != b.tiffRepresentation)
        let c = QuotaMenuBarIcon.image(weeklyFraction: nil, stale: false, updateAvailable: true)
        #expect(c.isTemplate)
        #expect(c.tiffRepresentation != a.tiffRepresentation)   // no-data ring also badged
    }

    @Test("badge geometry stays inside the canvas; alpha is template-safe black+alpha")
    func badgeConstantsStayTemplateSafe() {
        #expect(QuotaRingSpec.badgeAlpha > 0 && QuotaRingSpec.badgeAlpha <= 1)
        #expect(QuotaRingSpec.badgeRadius + QuotaRingSpec.badgeOffset <= QuotaRingSpec.canvas)
    }

    @Test("accessibility text appends 'update available' only when the flag is set")
    func accessibilityMentionsUpdate() {
        #expect(MenuBarLabel.accessibilityText(
            running: true, quotaPercent: "42%", updateAvailable: true)
            .contains("update available"))
        #expect(!MenuBarLabel.accessibilityText(
            running: true, quotaPercent: "42%", updateAvailable: false)
            .contains("update available"))
        // The no-data tail keeps its wording beside the update suffix.
        #expect(MenuBarLabel.accessibilityText(
            running: false, quotaPercent: nil, updateAvailable: true)
            .contains("quota data unavailable"))
    }

    // MARK: - Banner visibility matrix (what the popover reads)

    /// The update banners render off `splashAlert`/`zgateAlert` (and the
    /// menu-bar badge off `hasActiveAlert`); dismissal is per-tag. This
    /// pins the exact accessor matrix through a full stubbed check —
    /// no network, no manager wiring.
    @Test("banner visibility matrix: both alerts, dismiss one, dismiss both")
    @MainActor
    func bannerVisibilityMatrix() async {
        let splashURL = SplashChip.releasesURL(for: .forkM1M2)
        let splashFixture = Data(
            #"{"tag_name":"1.7.0-m1","assets":[{"name":"splash-1.7.0-m1-arm64-macos26.tar.gz","browser_download_url":"https://example.com/splash-1.7.0-m1-arm64-macos26.tar.gz"}]}"#
                .utf8)
        let zgateFixture = Data(
            #"{"tag_name":"v2.9.0","assets":[{"name":"ZGate-v2.9.0.zip","browser_download_url":"https://example.com/ZGate-v2.9.0.zip","digest":"sha256:\#(String(repeating: "ab", count: 32))"}]}"#
                .utf8)
        let center = UpdateCenter(deps: UpdateCenter.Deps(
            fetch: { url in
                if url == splashURL { return splashFixture }
                if url == UpdateCenter.zgateReleasesURL { return zgateFixture }
                throw URLError(.notConnectedToInternet)
            },
            installedSplashVersion: { _ in "1.6.1-m1.1" },
            currentZGateVersion: { (2, 8, 9) }))

        // Both targets available → both banners + the menu-bar badge.
        await center.checkNow(chip: .forkM1M2)
        #expect(center.splashAlert && center.zgateAlert && center.hasActiveAlert)

        // Dismiss one → the other banner (and the badge) stay.
        center.dismissSplash(tag: "1.7.0-m1")
        #expect(!center.splashAlert && center.zgateAlert && center.hasActiveAlert)

        // Dismiss the other → nothing renders; the badge clears.
        center.dismissZGate(tag: "v2.9.0")
        #expect(!center.splashAlert && !center.zgateAlert && !center.hasActiveAlert)
    }

    // MARK: - About Updates row (Task 11)

    @Test("About updates state line maps every ZGate verdict")
    func aboutUpdatesStateLine() {
        #expect(AboutTabView.updatesStateLine(.unknown) == "not checked yet")
        #expect(AboutTabView.updatesStateLine(.upToDate) == "up to date")
        #expect(AboutTabView.updatesStateLine(.available(tag: "v2.9.0", current: "2.8.9")) == "v2.9.0 available")
        #expect(AboutTabView.updatesStateLine(.cannotCheck) == "cannot check — repo unreachable or private")
        #expect(AboutTabView.updatesStateLine(.failed("staging")) == "update failed — staging")
    }

    /// The shared install helper behind the popover banner and the About
    /// row: request presents the tag, a stale/absent release degrades to
    /// the error line (no stage attempt, no busy flip), and the next
    /// request clears the failure. No network — stage/swap never runs
    /// without a matching lastCheckedRelease.
    @Test("install flow: request presents; stale release degrades to the error line")
    @MainActor
    func installFlowRequestAndStaleRelease() {
        let flow = ZGateInstallFlow()
        let service = AppUpdateService()   // lastCheckedRelease == nil
        flow.request(tag: "v2.9.0")
        #expect(flow.confirmTag == "v2.9.0" && flow.error == nil)
        flow.confirmInstall(appUpdate: service)
        #expect(flow.confirmTag == nil)
        #expect(flow.error == "release details unavailable — check again later")
        #expect(!flow.busy)
        flow.request(tag: "v2.9.1")
        #expect(flow.error == nil)
        flow.cancel()
        #expect(flow.confirmTag == nil)
    }

    /// Two-writer sync (General tab ↔ center): after adoptSettings the
    /// center's next persist round-trips the USER's toggle, not the
    /// stale pre-toggle copy — pinned through configWrite end to end.
    @Test("toggle sync: adopted settings survive the center's next persist")
    @MainActor
    func toggleSyncAdoptedSettingsSurvivePersist() async {
        let center = UpdateCenter(deps: UpdateCenter.Deps(
            fetch: { _ in throw URLError(.notConnectedToInternet) },
            installedSplashVersion: { _ in nil },
            currentZGateVersion: { (2, 8, 9) }))
        var persisted: UpdateSettings? = UpdateSettings(autoCheck: true)
        center.attach(
            configLoad: { persisted },
            configWrite: { persisted = $0 })

        // User flips the General toggle off (configStore-side write)…
        persisted?.autoCheck = false
        // …and the tab syncs the center's copy (adoptSettings).
        center.adoptSettings(persisted)

        await center.checkNow(splash: false)   // bumps lastCheckAt → persist
        #expect(persisted?.autoCheck == false)
    }

    // MARK: - Fix round 1

    /// Controller ruling: dismissal suppresses ALERTS (badge + popover
    /// banner, both `zgateAlert`-gated) but not the About capability —
    /// after dismissing tag T, About still offers the install action
    /// because the state verdict stays `.available` (a `zgateAlert` gate
    /// would dead-end: only a newer tag re-arms the alert).
    @Test("About offers the install action for any available release — dismissal gates alerts, not capability")
    @MainActor
    func aboutInstallOfferedRegardlessOfDismissal() async {
        let zgateFixture = Data(
            #"{"tag_name":"v2.9.0","assets":[{"name":"ZGate-v2.9.0.zip","browser_download_url":"https://example.com/ZGate-v2.9.0.zip","digest":"sha256:\#(String(repeating: "ab", count: 32))"}]}"#
                .utf8)
        let center = UpdateCenter(deps: UpdateCenter.Deps(
            fetch: { url in
                if url == UpdateCenter.zgateReleasesURL { return zgateFixture }
                throw URLError(.notConnectedToInternet)
            },
            installedSplashVersion: { _ in nil },
            currentZGateVersion: { (2, 8, 9) }))

        await center.checkNow(splash: false)
        #expect(center.zgateAlert)
        center.dismissZGate(tag: "v2.9.0")
        #expect(!center.zgateAlert)   // alert surfaces off…
        #expect(AboutTabView.aboutInstallOffered(center.zgateState))   // …capability on

        // Non-available verdicts offer nothing.
        #expect(!AboutTabView.aboutInstallOffered(.unknown))
        #expect(!AboutTabView.aboutInstallOffered(.upToDate))
        #expect(!AboutTabView.aboutInstallOffered(.cannotCheck))
    }

    /// Parks one fetch call until the test releases it, so the suite can
    /// observe mid-flight state (`isChecking`) at a deterministic point —
    /// no clock, no polling deadline. Lock-guarded like FetchStub: the
    /// fetch seam is @Sendable.
    private final class ParkedFetch: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?

        var isParked: Bool {
            lock.lock(); defer { lock.unlock() }
            return continuation != nil
        }

        func park() async {
            await withCheckedContinuation { c in
                lock.lock()
                continuation = c
                lock.unlock()
            }
        }

        func release() {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume()
        }
    }

    /// `isChecking` (the Check Now disable source) brackets a full
    /// checkNow cycle: false before, true while the check parks in its
    /// fetch, false again on every exit path (defer).
    @Test("isChecking brackets a checkNow run")
    @MainActor
    func isCheckingBracketsCheckNow() async {
        let park = ParkedFetch()
        let center = UpdateCenter(deps: UpdateCenter.Deps(
            fetch: { _ in
                await park.park()
                throw URLError(.notConnectedToInternet)
            },
            installedSplashVersion: { _ in nil },
            currentZGateVersion: { (2, 8, 9) }))
        #expect(!center.isChecking)
        async let done = center.checkNow(splash: false)
        while !park.isParked { await Task.yield() }   // deterministic mid-flight point
        #expect(center.isChecking)
        park.release()   // fetch throws → degraded cycle → defer clears
        await done
        #expect(!center.isChecking)
    }
}

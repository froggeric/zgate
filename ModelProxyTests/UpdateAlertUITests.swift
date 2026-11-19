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
}

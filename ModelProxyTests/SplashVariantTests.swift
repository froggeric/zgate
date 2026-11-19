import Foundation
import Testing
@testable import ZGate

@Suite struct SplashVariantTests {
    // -- variant table --
    @Test func variantTable() {
        #expect(SplashChip.forkM1M2.binaryName == "splash-m1")
        #expect(SplashChip.officialM3Plus.binaryName == "splash")
        #expect(SplashChip.forkM1M2.repoSlug == "paperniuk/splash")
        #expect(SplashChip.officialM3Plus.repoSlug == "incoai/splash")
        #expect(SplashChip.releasesURL(for: .forkM1M2).absoluteString
            == "https://api.github.com/repos/paperniuk/splash/releases/latest")
        #expect(SplashChip.releasesURL(for: .officialM3Plus).absoluteString
            == "https://api.github.com/repos/incoai/splash/releases/latest")
        #expect(SplashChip.releasesURL(for: nil).absoluteString
            == "https://api.github.com/repos/paperniuk/splash/releases/latest")
    }

    // -- macOS gate (both repos floor at 26.4; ZGate itself targets 15.7) --
    @Test func macOSGate() {
        #expect(!SplashChip.macOSSupportsSplash(OperatingSystemVersion(majorVersion: 15, minorVersion: 7, patchVersion: 0)))
        #expect(!SplashChip.macOSSupportsSplash(OperatingSystemVersion(majorVersion: 26, minorVersion: 3, patchVersion: 1)))
        #expect(SplashChip.macOSSupportsSplash(OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 0)))
        #expect(SplashChip.macOSSupportsSplash(OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 1)))
    }

    // -- resolution: per-chip name in every hop, ~/.local/bin hop, stale override --
    @Test func resolutionFindsOfficialBrewBinary() {
        let existing: Set<String> = ["/opt/homebrew/bin/splash"]
        let path = SplashManager.resolvedBinaryPath(
            override: nil, chip: .officialM3Plus,
            fileExists: { existing.contains($0) },
            homebrewBinDir: "/opt/homebrew/bin", localBinDir: nil)
        #expect(path == "/opt/homebrew/bin/splash")
    }

    @Test func resolutionFallsThroughToForkLocalBin() {
        let existing: Set<String> = [NSHomeDirectory() + "/.local/bin/splash-m1"]
        let path = SplashManager.resolvedBinaryPath(
            override: nil, chip: .forkM1M2,
            fileExists: { existing.contains($0) },
            homebrewBinDir: "/opt/homebrew/bin",
            localBinDir: NSHomeDirectory() + "/.local/bin")
        #expect(path.hasSuffix(".local/bin/splash-m1"))
    }

    @Test func resolutionStaleOverrideFallsThrough() {
        let path = SplashManager.resolvedBinaryPath(
            override: "/gone/splash-m1", chip: .forkM1M2,
            fileExists: { _ in false },
            homebrewBinDir: "/opt/homebrew/bin", localBinDir: nil)
        #expect(path.hasSuffix("ZGate/bin/splash-m1"))
    }

    @Test func resolutionOverrideWinsWhenPresent() {
        let path = SplashManager.resolvedBinaryPath(
            override: "/custom/splash", chip: .officialM3Plus,
            fileExists: { $0 == "/custom/splash" },
            homebrewBinDir: "/opt/homebrew/bin", localBinDir: nil)
        #expect(path == "/custom/splash")
    }
}

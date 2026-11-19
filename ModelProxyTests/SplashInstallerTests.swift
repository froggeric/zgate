import Testing
@testable import ZGate

@Suite struct SplashInstallerTests {

    @Test func chipParse() {
        #expect(SplashChip.from(brandString: "Apple M2 Max") == .forkM1M2)
        #expect(SplashChip.from(brandString: "Apple M1 Ultra") == .forkM1M2)
        #expect(SplashChip.from(brandString: "Apple M3") == .officialM3Plus)
        #expect(SplashChip.from(brandString: "Apple M4 Pro") == .officialM3Plus)
        #expect(SplashChip.from(brandString: "Intel(R) Core(TM) i9") == nil)
    }

    @Test func versionParseAndCompare() {
        #expect(SplashVersion.parse("Splash 1.6.1-m1\n") == [1, 6, 1])
        #expect(SplashVersion.isOlder([1, 6, 1], than: [1, 6, 2]))
        #expect(!SplashVersion.isOlder([1, 6, 1], than: [1, 6, 1]))
        #expect(!SplashVersion.isOlder([1, 7, 0], than: [1, 6, 9]))
        #expect(SplashVersion.parse("nope") == nil)
    }

    // Fork patch as a 4th component (spec §3.4, Review Focus #1).
    @Test func forkPatchOrders() {
        #expect(SplashVersion.isOlder(SplashVersion.parse("Splash 1.6.1-m1")!, than: SplashVersion.parse("Splash 1.6.1-m1.1")!))
        #expect(SplashVersion.isOlder(SplashVersion.parse("Splash 1.6.1-m1.1")!, than: SplashVersion.parse("Splash 1.6.2-m1")!))
        #expect(!SplashVersion.isOlder(SplashVersion.parse("Splash 1.6.1-m1.1")!, than: SplashVersion.parse("Splash 1.6.1-m1")!))
        #expect(SplashVersion.parse("Splash 1.6.1")! == [1, 6, 1])
        #expect(SplashVersion.parseTag("1.7.0") == [1, 7, 0])
    }

    @Test func brewArguments() {
        #expect(SplashInstaller.brewArguments(installed: false)
                == ["/opt/homebrew/bin/brew", "install", "incoai/tap/splash"])
        #expect(SplashInstaller.brewArguments(installed: true)
                == ["/opt/homebrew/bin/brew", "upgrade", "incoai/tap/splash"])
    }
}

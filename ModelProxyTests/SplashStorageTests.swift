import Testing
import Foundation
@testable import ZGate

@MainActor
@Suite struct SplashStorageTests {
    @Test func defaultsEmitNothing() {
        #expect(SplashStorage().launchFlags.isEmpty)
        #expect(SplashStorage().environment == nil)
    }

    @Test func fullFlags() {
        let s = SplashStorage(
            modelCacheLocation: "/Volumes/ssd/ai/cache/misc/hub",
            persistentCache: true, cacheDir: "/Volumes/ssd/ai/cache/splash",
            maxCacheDisk: "20G", maxCacheDiskWrites: "200G")
        #expect(s.launchFlags == [
            "--persistent-cache", "--cache-dir", "/Volumes/ssd/ai/cache/splash",
            "--max-cache-disk", "20G", "--max-cache-disk-writes", "200G"])
        #expect(s.environment == ["HF_HUB_CACHE": "/Volumes/ssd/ai/cache/misc/hub"])
    }

    @Test func cacheDirSuppressedWithoutPersistent() {
        let s = SplashStorage(persistentCache: false, cacheDir: "/x")
        #expect(!s.launchFlags.contains("--persistent-cache"))
        #expect(!s.launchFlags.contains { $0.hasPrefix("--cache-dir") })
    }

    @Test func serveArgumentsOrder() {
        let profile = SplashProfile(
            name: "p", model: "m", extraArgs: ["--max-cache-disk", "999G", "--port", "9001"])
        let storage = SplashStorage(persistentCache: true, maxCacheDisk: "20G")
        let args = profile.serveArguments(port: 8123, storage: storage)
        #expect(args.first == "serve")
        // storage BEFORE extraArgs …
        #expect(args.firstIndex(of: "--max-cache-disk")! < args.lastIndex(of: "--max-cache-disk")!)
        // … but extraArgs win (their 999G is the LAST --max-cache-disk value) …
        #expect(args[args.lastIndex(of: "--max-cache-disk")! + 1] == "999G")
        // … and the explicit --port in extraArgs suppresses the appended one.
        #expect(args.filter { $0 == "--port" }.count == 1)
        #expect(args.last == "9001")
    }

    @Test func liftParsesBothFormsAndMutatesInPlace() {
        var extra = ["--persistent-cache", "--cache-dir=/v/cache", "--max-cache-disk", "20G",
                     "--mmproj-keep", "x"]
        let s = SplashStorage.lift(from: &extra)
        #expect(s.persistentCache)
        #expect(s.cacheDir == "/v/cache")
        #expect(s.maxCacheDisk == "20G")
        #expect(extra == ["--mmproj-keep", "x"])   // unknown flags untouched
    }

    @Test func oldConfigWithoutStorageDecodesToDefaults() throws {
        let json = #"{"keepRunning":true,"profiles":[],"port":8123}"#
        let s = try JSONDecoder().decode(SplashSettings.self, from: Data(json.utf8))
        #expect(s.storage == nil)
    }
}

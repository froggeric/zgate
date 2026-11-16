import Foundation
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

    @Test func assetPickExactSingleAmbiguous() throws {
        let exact = try JSONDecoder().decode(SplashRelease.self, from: fix("splash-releases-exact"))
        #expect(SplashAssetPicker.binaryURL(from: exact)?.absoluteString == "https://example.com/splash-m1")
        let single = try JSONDecoder().decode(SplashRelease.self, from: fix("splash-releases-single"))
        #expect(SplashAssetPicker.binaryURL(from: single)?.absoluteString == "https://example.com/binary")
        let ambiguous = try JSONDecoder().decode(SplashRelease.self, from: fix("splash-releases-ambiguous"))
        #expect(SplashAssetPicker.binaryURL(from: ambiguous) == nil)
    }

    @Test func installUsesPrimaryPathWhenWritable() async throws {
        let rec = InstallRecorder()
        let installer = SplashInstaller(deps: rec.deps(writable: true))
        let release = try JSONDecoder().decode(SplashRelease.self, from: fix("splash-releases-exact"))
        let outcome = try await installer.installForkBinary(from: release)
        #expect(outcome == .installedAt(path: "/opt/homebrew/bin/splash-m1", fallback: false))
        #expect(rec.chmodmed)
    }

    @Test func installFallsBackOnPermissionError() async throws {
        let rec = InstallRecorder()
        let installer = SplashInstaller(deps: rec.deps(writable: false))
        let release = try JSONDecoder().decode(SplashRelease.self, from: fix("splash-releases-exact"))
        let outcome = try await installer.installForkBinary(from: release)
        let expected = AppPaths.appSupport.appendingPathComponent("bin/splash-m1").path
        #expect(outcome == .installedAt(path: expected, fallback: true))
    }

    @Test func brewArguments() {
        #expect(SplashInstaller.brewArguments(installed: false)
                == ["/opt/homebrew/bin/brew", "install", "incoai/tap/splash"])
        #expect(SplashInstaller.brewArguments(installed: true)
                == ["/opt/homebrew/bin/brew", "upgrade", "incoai/tap/splash"])
    }

    // MARK: helpers
    private final class BundleToken {}
    private func fix(_ name: String) throws -> Data {
        let fileName = "\(name).json"
        let bundle = Bundle(for: BundleToken.self)
        let candidates = [
            bundle.resourceURL?.appendingPathComponent(fileName),
            bundle.resourceURL?.appendingPathComponent("Fixtures").appendingPathComponent(fileName),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures").appendingPathComponent(fileName)
        ]
        for c in candidates.compactMap({ $0 }) {
            if let d = try? Data(contentsOf: c) { return d }
        }
        throw CocoaError(.fileNoSuchFile)
    }

    /// Seam recorder: fetch returns marker bytes; move/setExecutable log calls;
    /// writable false makes the primary move throw NSFileWriteNoPermissionError.
    private final class InstallRecorder: @unchecked Sendable {
        var chmodmed = false
        private let lock = NSLock()
        func deps(writable: Bool) -> SplashInstallerDeps {
            SplashInstallerDeps(
                fetch: { _ in Data("#!/bin/sh\necho stub\n".utf8) },
                move: { src, dst in
                    if !writable && dst.path == "/opt/homebrew/bin/splash-m1" {
                        throw CocoaError(.fileWriteNoPermission)
                    }
                    _ = src; _ = dst
                },
                setExecutable: { _ in self.lock.withLock { self.chmodmed = true } },
                isWritable: { _ in writable },
                removeItem: { _ in })
        }
    }
}

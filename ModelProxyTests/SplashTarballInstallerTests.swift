import Foundation
import Testing
@testable import ZGate

@Suite struct SplashTarballInstallerTests {

    /// Builds a REAL tarball the way the repos ship it: one wrapper
    /// component (`inner/…`) so `--strip-components 1` lands the contents
    /// at the version-dir root. Ships a stub `python/bin/python3` that
    /// answers `Splash <tag>`, so the shim's exec and the `--version`
    /// verify run end to end through the `current` symlink (no network;
    /// tar/xattr/sh are local tools).
    private func makeTarball(_ dir: URL, tag: String) throws -> (Data, String) {
        let fm = FileManager.default
        let inner = dir.appendingPathComponent("pkg/inner", isDirectory: true)
        try fm.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: inner.appendingPathComponent("hello.txt"))
        let pythonDir = inner.appendingPathComponent("python/bin", isDirectory: true)
        try fm.createDirectory(at: pythonDir, withIntermediateDirectories: true)
        let python = pythonDir.appendingPathComponent("python3")
        try Data("#!/bin/sh\necho \"Splash \(tag)\"\n".utf8).write(to: python)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        let install = inner.appendingPathComponent("install", isDirectory: true)
        try fm.createDirectory(at: install, withIntermediateDirectories: true)
        try Data("# stub\n".utf8).write(to: install.appendingPathComponent("launcher.py"))
        let tarPath = dir.appendingPathComponent("splash-\(tag)-arm64-macos26.tar.gz").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-czf", tarPath, "-C", dir.appendingPathComponent("pkg").path, "inner"]
        try p.run(); p.waitUntilExit()
        let data = try Data(contentsOf: URL(fileURLWithPath: tarPath))
        return (data, SHA256Hex.of(data))
    }

    private func release(tag: String, sidecar: Bool = true) -> SplashRelease {
        func asset(_ name: String) -> SplashReleaseAsset {
            SplashReleaseAsset(name: name, browser_download_url: URL(string: "https://x/\(name)")!)
        }
        var assets = [
            asset("splash-\(tag)-arm64-macos26.tar.gz"),
            asset("install-m1.sh"), asset("Splash-\(tag).dmg"),
        ]
        if sidecar { assets.append(asset("splash-\(tag)-arm64-macos26.tar.gz.sha256")) }
        return SplashRelease(tag_name: tag, assets: assets)
    }

    private struct Harness {
        let root: URL, binDir: URL, tarData: (Data, String)

        /// fetch returns the real tarball bytes; the sidecar goes through
        /// `sidecar` (default: exactly what the repos ship — hex + `\n`).
        func installer(
            sidecar: @escaping (String) -> Data = { Data("\($0)\n".utf8) }
        ) -> SplashTarballInstaller {
            var i = SplashTarballInstaller()
            let (data, hex) = tarData
            i.deps.fetch = { url in
                url.absoluteString.hasSuffix(".sha256") ? sidecar(hex) : data
            }
            return i
        }
    }

    private func makeHarness(tag: String = "1.6.1-m1.1") throws -> Harness {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("tarball-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return Harness(root: base.appendingPathComponent("Splash-M1"),
                       binDir: base.appendingPathComponent("bin"),
                       tarData: try makeTarball(base, tag: tag))
    }

    @Test func assetPairPicksTarballAndSidecar() throws {
        let pair = SplashTarballInstaller.assetPair(from: release(tag: "1.6.1-m1.1"))
        #expect(pair?.tar.name == "splash-1.6.1-m1.1-arm64-macos26.tar.gz")
        #expect(pair?.sha256.name == "splash-1.6.1-m1.1-arm64-macos26.tar.gz.sha256")
        // nil when either half is missing — never guess (spec §2).
        #expect(SplashTarballInstaller.assetPair(from: release(tag: "1.6.1-m1.1", sidecar: false)) == nil)
    }

    @Test func installsUnpacksSwapsSymlinkWritesShim() async throws {
        let h = try makeHarness()
        let tag = try await h.installer()
            .install(release: release(tag: "1.6.1-m1.1"), installRoot: h.root, binDir: h.binDir)
        #expect(tag == "1.6.1-m1.1")
        // Relative target (ln -sfn semantics): the root stays relocatable.
        let cur = try FileManager.default.destinationOfSymbolicLink(
            atPath: h.root.appendingPathComponent("current").path)
        #expect(cur == "1.6.1-m1.1")
        #expect(FileManager.default.fileExists(
            atPath: h.root.appendingPathComponent("1.6.1-m1.1/hello.txt").path))
        let shim = try String(contentsOf: h.binDir.appendingPathComponent("splash-m1"), encoding: .utf8)
        #expect(shim.contains("PYTHONDONTWRITEBYTECODE=1"))
        #expect(shim.contains("/current/python/bin/python3"))
        #expect(shim.contains("/current/install/launcher.py"))
    }

    @Test func checksumMismatchAbortsLeavingPriorIntact() async throws {
        let h = try makeHarness()
        let fm = FileManager.default
        // Prior install: old version dir + current pointing at it.
        let old = h.root.appendingPathComponent("1.5.0-m1", isDirectory: true)
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old.appendingPathComponent("hello.txt"))
        try fm.createSymbolicLink(atPath: h.root.appendingPathComponent("current").path,
                                  withDestinationPath: "1.5.0-m1")
        let bad = "deadbeef" + String(h.tarData.1.dropFirst(8))
        await #expect(throws: SplashTarballInstaller.InstallError.checksumMismatch) {
            _ = try await h.installer(sidecar: { _ in Data("\(bad)\n".utf8) })
                .install(release: release(tag: "1.6.1-m1.1"), installRoot: h.root, binDir: h.binDir)
        }
        #expect(try fm.destinationOfSymbolicLink(
            atPath: h.root.appendingPathComponent("current").path) == "1.5.0-m1")
        #expect(fm.fileExists(atPath: old.appendingPathComponent("hello.txt").path))
        #expect(!fm.fileExists(atPath: h.root.appendingPathComponent("1.6.1-m1.1").path))
        #expect(!fm.fileExists(atPath: h.root.appendingPathComponent("1.6.1-m1.1.partial").path))
        // The abort happens before any binDir write.
        #expect(!fm.fileExists(atPath: h.binDir.appendingPathComponent("splash-m1").path))
    }

    @Test func whitespaceInSidecarIsTolerated() async throws {
        let h = try makeHarness()
        let tag = try await h.installer(sidecar: { Data("  \($0)\r\n\n".utf8) })
            .install(release: release(tag: "1.6.1-m1.1"), installRoot: h.root, binDir: h.binDir)
        #expect(tag == "1.6.1-m1.1")
    }

    @Test func missingSidecarThrowsMissingAssets() async throws {
        let h = try makeHarness()
        await #expect(throws: SplashTarballInstaller.InstallError.missingAssets) {
            _ = try await h.installer()
                .install(release: release(tag: "1.6.1-m1.1", sidecar: false),
                         installRoot: h.root, binDir: h.binDir)
        }
        #expect(!FileManager.default.fileExists(
            atPath: h.root.appendingPathComponent("1.6.1-m1.1").path))
    }

    @Test func legacyShimBackedUp() async throws {
        let h = try makeHarness()
        let fm = FileManager.default
        try fm.createDirectory(at: h.binDir, withIntermediateDirectories: true)
        try Data("MZ legacy plain binary".utf8)
            .write(to: h.binDir.appendingPathComponent("splash-m1"))
        let tag = try await h.installer()
            .install(release: release(tag: "1.6.1-m1.1"), installRoot: h.root, binDir: h.binDir)
        #expect(tag == "1.6.1-m1.1")
        let legacy = try String(contentsOf: h.binDir.appendingPathComponent("splash-m1.zgate-legacy"),
                                encoding: .utf8)
        #expect(legacy == "MZ legacy plain binary")
        let shim = try String(contentsOf: h.binDir.appendingPathComponent("splash-m1"), encoding: .utf8)
        #expect(shim.contains("PYTHONDONTWRITEBYTECODE=1"))
    }

    @Test func pruneKeepsCurrentAndOnePrevious() async throws {
        let h = try makeHarness()
        let fm = FileManager.default
        for old in ["1.5.0-m1", "1.6.0-m1"] {
            let d = h.root.appendingPathComponent(old, isDirectory: true)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            try Data("old".utf8).write(to: d.appendingPathComponent("hello.txt"))
        }
        // Existing current → exercises the replace-the-symlink swap path.
        try fm.createSymbolicLink(atPath: h.root.appendingPathComponent("current").path,
                                  withDestinationPath: "1.6.0-m1")
        let tag = try await h.installer()
            .install(release: release(tag: "1.6.1-m1.1"), installRoot: h.root, binDir: h.binDir)
        #expect(tag == "1.6.1-m1.1")
        #expect(!fm.fileExists(atPath: h.root.appendingPathComponent("1.5.0-m1").path))
        #expect(fm.fileExists(atPath: h.root.appendingPathComponent("1.6.0-m1/hello.txt").path))
        #expect(try fm.destinationOfSymbolicLink(
            atPath: h.root.appendingPathComponent("current").path) == "1.6.1-m1.1")
    }
}

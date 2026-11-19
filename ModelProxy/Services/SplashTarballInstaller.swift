import CryptoKit
import Foundation

// MARK: - SHA-256 hex

enum SHA256Hex: Sendable {
    static func of(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Tarball installer

/// Fork install/update, mirroring paperniuk's install-m1.sh step for step
/// (spec §3.2) — but executed by us, never by piping the remote script.
struct SplashTarballInstaller: Sendable {
    struct Deps: Sendable {
        var fetch: @Sendable (URL) async throws -> Data = { url in
            let (d, _) = try await URLSession.shared.data(from: url); return d
        }
        /// Runs argv (argv[0] = executable); non-zero exit throws.
        var run: @Sendable ([String]) async throws -> Void = { argv in
            try await SplashTarballInstaller.runProcess(argv)
        }
        /// Runs argv, returns trimmed stdout; nil on non-zero exit.
        var capture: @Sendable ([String]) async -> String? = { argv in
            await SplashTarballInstaller.captureProcess(argv)
        }
    }
    enum InstallError: Error, Equatable {
        case missingAssets, checksumMismatch, verifyFailed(String)
    }

    static var defaultInstallRoot: URL {
        AppPaths.appSupport.deletingLastPathComponent()  // ~/Library/Application Support
            .appendingPathComponent("Splash-M1", isDirectory: true)
    }
    /// /opt/homebrew/bin when writable (the fork's own rule), else ~/.local/bin.
    static var defaultBinDir: URL {
        let hb = URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)
        return FileManager.default.isWritableFile(atPath: hb.path)
            ? hb : URL(fileURLWithPath: NSHomeDirectory() + "/.local/bin", isDirectory: true)
    }

    var deps = Deps()

    /// Uniform asset rule (both repos): splash-<tag>-arm64-macos26.tar.gz
    /// + same + ".sha256". Never guesses (spec §2).
    static func assetPair(from release: SplashRelease) -> (tar: SplashReleaseAsset, sha256: SplashReleaseAsset)? {
        let exact = "splash-\(release.tag_name)-arm64-macos26.tar.gz"
        guard let tar = release.assets.first(where: { $0.name == exact })
                ?? release.assets.first(where: { $0.name.hasPrefix("splash-") && $0.name.hasSuffix("-arm64-macos26.tar.gz") }),
              let sum = release.assets.first(where: { $0.name == tar.name + ".sha256" })
        else { return nil }
        return (tar, sum)
    }

    /// Full install; returns the installed tag. Throws on any step before
    /// touching the previous install (checksum) or after (verify).
    func install(release: SplashRelease, installRoot: URL? = nil, binDir: URL? = nil) async throws -> String {
        guard let (tar, sum) = Self.assetPair(from: release) else { throw InstallError.missingAssets }
        let tag = release.tag_name
        let tarData = try await deps.fetch(tar.browser_download_url)
        let sidecar = String(data: try await deps.fetch(sum.browser_download_url), encoding: .utf8) ?? ""
        // install-m1.sh: tr -d '[:space:]' — the sidecar ships trailing \n.
        guard sidecar.trimmingCharacters(in: .whitespacesAndNewlines)
            == SHA256Hex.of(tarData) else { throw InstallError.checksumMismatch }

        let root = installRoot ?? Self.defaultInstallRoot
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let partial = root.appendingPathComponent("\(tag).partial", isDirectory: true)
        try? fm.removeItem(at: partial)
        try fm.createDirectory(at: partial, withIntermediateDirectories: true)
        let tmpTar = FileManager.default.temporaryDirectory
            .appendingPathComponent("splash-\(UUID().uuidString).tar.gz")
        defer { try? fm.removeItem(at: tmpTar) }
        try tarData.write(to: tmpTar)
        try await deps.run(["/usr/bin/tar", "-xzf", tmpTar.path, "-C", partial.path, "--strip-components", "1"])
        // A browser download would mark these quarantined; clear like the script.
        try? await deps.run(["/usr/bin/xattr", "-dr", "com.apple.quarantine", partial.path])
        let final = root.appendingPathComponent(tag, isDirectory: true)
        try? fm.removeItem(at: final)
        try fm.moveItem(at: partial, to: final)

        swapCurrentSymlink(to: tag, under: root)
        try await ensureShim(root: root, binDir: binDir ?? Self.defaultBinDir)
        prune(keeping: tag, plus: 1, under: root)

        // Sanity (spec §3.2 step 6): --version must answer the new tag.
        let shim = (binDir ?? Self.defaultBinDir).appendingPathComponent("splash-m1").path
        if let out = await deps.capture([shim, "--version"]), out.contains(tag) { return tag }
        throw InstallError.verifyFailed(tag)
    }

    /// Atomic `current` swap (`ln -sfn` semantics): build the symlink
    /// beside the target, rename it over. Relative destination — the root
    /// stays relocatable.
    private func swapCurrentSymlink(to tag: String, under root: URL) {
        let fm = FileManager.default
        let current = root.appendingPathComponent("current")
        let linkTmp = root.appendingPathComponent(".current-\(UUID().uuidString)")
        try? fm.removeItem(at: linkTmp)
        try? fm.createSymbolicLink(atPath: linkTmp.path, withDestinationPath: tag)
        if Self.itemExists(current) {
            do { _ = try fm.replaceItemAt(current, withItemAt: linkTmp) }
            catch {
                // A destination replaceItemAt refuses (e.g. odd metadata):
                // fall back to remove+move rather than fail the install.
                try? fm.removeItem(at: current)
                try? fm.moveItem(at: linkTmp, to: current)
            }
        } else {
            try? fm.moveItem(at: linkTmp, to: current)
        }
    }

    /// lstat semantics: `fileExists` follows symlinks, so a dangling
    /// `current` (deleted target) still counts as existing for the swap.
    private static func itemExists(_ url: URL) -> Bool {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
            return true
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func ensureShim(root: URL, binDir: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        let shim = binDir.appendingPathComponent("splash-m1")
        let contents = """
        #!/bin/sh
        export PYTHONDONTWRITEBYTECODE=1
        exec "\(root.path)/current/python/bin/python3" -u "\(root.path)/current/install/launcher.py" "$@"

        """
        // Probe raw bytes: a legacy Mach-O binary isn't UTF-8 but still
        // must be backed up before the overwrite.
        let existingData = try? Data(contentsOf: shim)
        let existing = existingData.flatMap { String(data: $0, encoding: .utf8) }
        if existing != contents {
            if existingData != nil {   // legacy ZGate plain binary → keep a backup
                try? fm.copyItem(at: shim, to: binDir.appendingPathComponent("splash-m1.zgate-legacy"))
                try fm.removeItem(at: shim)
            }
            try contents.write(to: shim, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        }
    }

    /// Removes version dirs except the installed one and its `keep` newest
    /// predecessors (install-m1.sh keeps every version; we keep the last
    /// one for instant rollback).
    private func prune(keeping tag: String, plus keep: Int, under root: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        let versions = names.filter { $0 != tag && !$0.hasPrefix(".") && $0 != "current" }
            .sorted(by: >)   // lexical ≥ release ordering for this scheme
        for name in versions.dropFirst(keep) {
            try? fm.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
        }
    }

    // MARK: Process seams

    private enum ProcessError: Error { case failed(Int32) }

    /// The Process idiom of `SplashInstaller.runBrew` (pipe stdout,
    /// null stderr, detached); throws on non-zero exit.
    nonisolated private static func runProcess(_ argv: [String]) async throws {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: argv[0])
            p.arguments = Array(argv.dropFirst())
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            try p.run()
            pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus != 0 { throw ProcessError.failed(p.terminationStatus) }
        }.value
    }

    nonisolated private static func captureProcess(_ argv: [String]) async -> String? {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: argv[0])
            p.arguments = Array(argv.dropFirst())
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}

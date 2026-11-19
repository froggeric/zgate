import Foundation

// MARK: - Chip

enum SplashChip: String, Sendable, Equatable {
    case forkM1M2, officialM3Plus

    /// `sysctl -n machdep.cpu.brand_string` → chip family. Apple M-series
    /// with generation ≤ 2 → fork; ≥ 3 → official; anything else → nil.
    nonisolated static func from(brandString: String) -> SplashChip? {
        let s = brandString.lowercased()
        guard let mRange = s.range(of: "apple m") else { return nil }
        let rest = s[mRange.upperBound...]
        guard let digit = rest.first(where: { $0.isNumber }),
              let generation = digit.wholeNumberValue else { return nil }
        return generation <= 2 ? .forkM1M2 : .officialM3Plus
    }

    nonisolated static func currentBrandString() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
        p.arguments = ["-n", "machdep.cpu.brand_string"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// `nonisolated`: pure per-chip facts + subprocess probe, consumed from any
// isolation (binary resolution runs off the main actor).
nonisolated extension SplashChip {
    /// Binary this chip family runs (fork shim vs brew formula command).
    var binaryName: String { self == .officialM3Plus ? "splash" : "splash-m1" }
    /// Repo whose releases/latest answers for this chip (spec §3.1).
    var repoSlug: String { self == .officialM3Plus ? "incoai/splash" : "paperniuk/splash" }
    /// Detected once per process; nil = unknown → callers treat as fork
    /// (same rule as SplashTabModel.installVariant).
    static let current: SplashChip? =
        SplashChip.from(brandString: SplashChip.currentBrandString() ?? "")

    static func releasesURL(for chip: SplashChip?) -> URL {
        URL(string: "https://api.github.com/repos/\((chip ?? .forkM1M2).repoSlug)/releases/latest")!
    }

    /// Both splash repos require macOS 26.4 (install-m1.sh gate; official
    /// device check). ZGate runs on 15.7+, so this gates only splash
    /// install/update UI and auto-apply, never the app itself.
    static func macOSSupportsSplash(_ v: OperatingSystemVersion) -> Bool {
        if v.majorVersion > 26 { return true }
        return v.majorVersion == 26 && v.minorVersion >= 4
    }
}

// MARK: - Version

enum SplashVersion: Sendable {
    /// `Splash 1.6.1-m1` → [1, 6, 1]. The `-m1` fork suffix does not affect
    /// ordering (spec §3.2). nil when unparseable.
    static func parse(_ output: String) -> [Int]? {
        let tokens = output.split(whereSeparator: { $0.isWhitespace })
        guard let idx = tokens.firstIndex(of: "Splash"), idx + 1 < tokens.count else { return nil }
        let core = tokens[idx + 1].split(separator: "-").first?
            .split(separator: ".").compactMap { Int($0) } ?? []
        return core.isEmpty ? nil : core
    }

    /// Lexicographic over dotted numbers; shorter prefix loses when equal
    /// (1.6 < 1.6.1).
    static func isOlder(_ a: [Int], than b: [Int]) -> Bool {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : -1
            let y = i < b.count ? b[i] : -1
            if x != y { return x < y }
        }
        return false
    }
}

// MARK: - Releases

struct SplashReleaseAsset: Decodable, Sendable, Equatable {
    let name: String
    let browser_download_url: URL
}

struct SplashRelease: Decodable, Sendable, Equatable {
    let tag_name: String
    let assets: [SplashReleaseAsset]
}

enum SplashAssetPicker: Sendable {
    /// Spec §3.2 asset rule: exact `splash-m1` wins; else the SINGLE
    /// non-.dmg non-.sh asset; nil = none/ambiguous (never guess).
    static func binaryURL(from release: SplashRelease) -> URL? {
        if let exact = release.assets.first(where: { $0.name == "splash-m1" }) {
            return exact.browser_download_url
        }
        let candidates = release.assets.filter {
            !$0.name.hasSuffix(".dmg") && !$0.name.hasSuffix(".sh")
        }
        return candidates.count == 1 ? candidates[0].browser_download_url : nil
    }
}

// MARK: - Installer

struct SplashInstallerDeps: Sendable {
    var fetch: @Sendable (URL) async throws -> Data = { url in
        let (d, _) = try await URLSession.shared.data(from: url); return d
    }
    var move: @Sendable (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    var setExecutable: @Sendable (URL) throws -> Void = {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: $0.path)
    }
    var isWritable: @Sendable (URL) -> Bool = {
        FileManager.default.isWritableFile(atPath: $0.deletingLastPathComponent().path)
    }
    var removeItem: @Sendable (URL) -> Void = { try? FileManager.default.removeItem(at: $0) }
}

enum SplashInstallOutcome: Equatable, Sendable {
    case installedAt(path: String, fallback: Bool)
}

enum SplashInstallerError: Error, Equatable {
    case ambiguousOrMissingAsset
}

struct SplashInstaller: Sendable {
    static let releasesURL = URL(
        string: "https://api.github.com/repos/paperniuk/splash/releases/latest")!
    static let homebrewPath = "/opt/homebrew/bin/splash-m1"
    static var fallbackPath: String {
        AppPaths.appSupport.appendingPathComponent("bin/splash-m1").path
    }

    var deps = SplashInstallerDeps()

    static func brewArguments(installed: Bool) -> [String] {
        ["/opt/homebrew/bin/brew", installed ? "upgrade" : "install", "incoai/tap/splash"]
    }

    /// Latest fork release; nil on ANY failure (network, decode) — UI shows
    /// "unknown latest", never a wrong verdict.
    func latestForkRelease() async -> SplashRelease? {
        guard let data = try? await deps.fetch(Self.releasesURL) else { return nil }
        return try? JSONDecoder().decode(SplashRelease.self, from: data)
    }

    /// Latest release for the chip's repo (spec §3.1); nil on ANY failure.
    func latestRelease(for chip: SplashChip?) async -> SplashRelease? {
        guard let data = try? await deps.fetch(SplashChip.releasesURL(for: chip)) else { return nil }
        return try? JSONDecoder().decode(SplashRelease.self, from: data)
    }

    /// `splash-m1 --version` output, or nil (missing binary / failure).
    static func installedVersion(binaryPath: String) async -> String? {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: binaryPath)
            p.arguments = ["--version"]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(data: data, encoding: .utf8)
        }.value
    }

    /// Download → chmod → atomic move (spec §3.2). Never executes the temp
    /// file; permission failure at the primary path falls back to the
    /// app-support dir and reports `fallback: true` so the caller persists
    /// `binaryPathOverride`.
    func installForkBinary(from release: SplashRelease) async throws -> SplashInstallOutcome {
        guard let url = SplashAssetPicker.binaryURL(from: release) else {
            throw SplashInstallerError.ambiguousOrMissingAsset
        }
        let bytes = try await deps.fetch(url)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("splash-m1-\(UUID().uuidString)")
        defer { deps.removeItem(tmp) }
        try bytes.write(to: tmp)
        try deps.setExecutable(tmp)

        let primary = URL(fileURLWithPath: Self.homebrewPath)
        if deps.isWritable(primary) {
            do { try deps.move(tmp, primary); return .installedAt(path: primary.path, fallback: false) }
            catch { /* permission-ish at move time → fall through */ }
        }
        let fallback = URL(fileURLWithPath: Self.fallbackPath)
        try? FileManager.default.createDirectory(
            at: fallback.deletingLastPathComponent(), withIntermediateDirectories: true)
        try deps.move(tmp, fallback)
        return .installedAt(path: fallback.path, fallback: true)
    }
}

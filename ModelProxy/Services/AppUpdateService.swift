import Foundation
import Observation

// MARK: - ZGate self-update (spec §3.5)

/// The explicit-click self-updater: anonymous check against the public
/// repo (reusing `ZGateRelease` — one decoder, one fetcher), staging
/// that verifies the GitHub asset digest AND the staged bundle's
/// codesign TeamIdentifier against the running app, and a swap that
/// spawns the bundled `release-swap.sh` DETACHED via `/bin/zsh` — the
/// script SIGTERMs this app (its own parent) by design, so it is never
/// awaited. Nothing here is automatic: stage/swap only ever run from an
/// explicit UI click (spec §3.5).
@MainActor @Observable
final class AppUpdateService {
    enum StageError: Error, Equatable {
        case notProdInstall          // running outside /Applications/ZGate.app
        case missingScript           // release-swap.sh not in the bundle
        case checksumMismatch        // download failed the API digest check
        case teamMismatch(String)    // staged TeamID ≠ running app's (payload: current)
        case staging(String)         // digest missing / low disk / bad zip / codesign exit
    }

    struct Deps: Sendable {
        var fetch: @Sendable (URL) async throws -> Data = { url in
            let (d, _) = try await URLSession.shared.data(from: url); return d
        }
        /// Runs argv (argv[0] = executable), returns combined stdout+stderr
        /// (`codesign -dv` prints TeamIdentifier to stderr); non-zero exit
        /// throws.
        var runCapture: @Sendable ([String]) async throws -> String = { argv in
            try await AppUpdateService.runCaptureProcess(argv)
        }
        var currentBundlePath: @Sendable () -> String = { Bundle.main.bundleURL.path }
        /// UI-level convenience only — the check path takes the triple as a
        /// parameter so a nil version read can degrade honestly instead of
        /// fabricating an update (UpdateCenter guards that; see checkState).
        var currentVersion: @Sendable () -> (Int, Int, Int) = {
            let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
            return ZGateVersion.parse(tag: "v\(short).\(build)") ?? (0, 0, 0)
        }
        /// The bundled swap script (wired into Resources in this task).
        var scriptPath: @Sendable () -> URL? = {
            Bundle.main.url(forResource: "release-swap", withExtension: "sh")
        }
    }

    var deps: Deps
    /// The release the last checkState fetched (nil on failure) — the
    /// caller's window onto the tag for persistence, without a re-fetch.
    private(set) var lastCheckedRelease: ZGateRelease?

    init(deps: Deps = Deps()) {
        self.deps = deps
    }

    // MARK: - Check (spec §3.5.1 — anonymous, honest degrade)

    /// nil on ANY failure: fetch, decode, or no verifiable
    /// `ZGate-<tag>.zip` asset carrying a `sha256:` digest.
    func latestRelease() async -> ZGateRelease? {
        guard let data = try? await deps.fetch(Self.releasesURL),
              let release = try? JSONDecoder().decode(ZGateRelease.self, from: data),
              release.zipAsset != nil else { return nil }
        return release
    }

    /// UpdateCenter-facing check: pure state from latestRelease + the
    /// running version (NON-optional — the center guards a nil read →
    /// cannotCheck before calling).
    func checkState(current: (Int, Int, Int)) async -> UpdateCenter.ZGateUpdateState {
        guard let release = await latestRelease(),
              let latest = ZGateVersion.parse(tag: release.tag_name)
        else {
            lastCheckedRelease = nil
            return .cannotCheck
        }
        lastCheckedRelease = release
        if ZGateVersion.isNewer(latest, than: current) {
            return .available(tag: release.tag_name, current: "\(current.0).\(current.1).\(current.2)")
        }
        return .upToDate
    }

    // MARK: - Stage (spec §3.5.2)

    /// Download → digest verify → unpack → TeamID check. Returns the
    /// staged app URL (`…/ZGate/updates/<tag>/ZGate.app`). Throws before
    /// touching disk on a digest mismatch; the temp download is always
    /// cleaned (partial downloads never linger).
    func stage(_ release: ZGateRelease) async throws -> URL {
        guard let asset = release.zipAsset,
              let hex = asset.digest?.dropFirst("sha256:".count)
        else { throw StageError.staging("digest") }
        let zip = try await deps.fetch(asset.browser_download_url)
        guard SHA256Hex.of(zip) == String(hex) else { throw StageError.checksumMismatch }

        let fm = FileManager.default
        let updates = AppPaths.appSupport.appendingPathComponent("updates", isDirectory: true)
        try fm.createDirectory(at: updates, withIntermediateDirectories: true)
        // ≥ 500 MB free on the target volume before staging (spec §3.5).
        if let values = try? updates.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage,
           free < Self.minFreeBytes {
            throw StageError.staging("low disk")
        }
        let dir = updates.appendingPathComponent(release.tag_name, isDirectory: true)
        try? fm.removeItem(at: dir)   // a failed prior attempt stages over cleanly
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmpZip = updates.appendingPathComponent("dl-\(UUID().uuidString).zip")
        defer { try? fm.removeItem(at: tmpZip) }
        try zip.write(to: tmpZip)
        try await deps.runCapture(["/usr/bin/ditto", "-x", "-k", tmpZip.path, dir.path])
        let staged = dir.appendingPathComponent("ZGate.app")
        guard fm.fileExists(atPath: staged.path) else { throw StageError.staging("no app in zip") }
        // Belt-and-braces identity check beside the sha256 (spec §3.5):
        // the staged bundle's codesign TeamIdentifier must equal the
        // running app's (both ad-hoc → both nil → still equal).
        let stagedTeam = Self.teamID(fromCodesignOutput:
            try await deps.runCapture(["/usr/bin/codesign", "-dv", staged.path]))
        let currentTeam = Self.teamID(fromCodesignOutput:
            try await deps.runCapture(["/usr/bin/codesign", "-dv", deps.currentBundlePath()]))
        guard stagedTeam == currentTeam else { throw StageError.teamMismatch(currentTeam ?? "unknown") }
        return staged
    }

    // MARK: - Swap (spec §3.5.3)

    /// Spawns the bundled release-swap.sh DETACHED and returns: the
    /// script SIGTERMs this app (its own parent — it is built to outlive
    /// it, scripts/release-swap.sh header). NEVER awaited.
    func swap(staged: URL) async throws {
        guard deps.currentBundlePath() == Self.prodAppPath else { throw StageError.notProdInstall }
        guard let script = deps.scriptPath() else { throw StageError.missingScript }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [script.path, staged.path]
        p.standardOutput = FileHandle.nullDevice   // no pipe left for a dying
        p.standardError = FileHandle.nullDevice    // parent to drain
        try p.run()   // fire — the app dies mid-script by design
    }
}

nonisolated extension AppUpdateService {
    /// Public repo (locked decision 4): anonymous releases/latest; 404,
    /// rate-limit or network failure degrades to cannotCheck.
    static let releasesURL = URL(
        string: "https://api.github.com/repos/froggeric/zgate/releases/latest")!
    /// The swap script only ever replaces exactly this install (its own
    /// PROD_APP constraint) — elsewhere the UI offers the Releases page.
    static let prodAppPath = "/Applications/ZGate.app"
    /// ≥ 500 MB free on the app-support volume before staging (spec §3.5).
    static let minFreeBytes: Int64 = 500_000_000

    /// The default runCapture: a real process, stdout+stderr combined
    /// (`codesign -dv` writes TeamIdentifier to stderr), throws on
    /// non-zero exit. (SplashTarballInstaller's detached-Process idiom.)
    static func runCaptureProcess(_ argv: [String]) async throws -> String {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: argv[0])
            p.arguments = Array(argv.dropFirst())
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
                + err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                throw StageError.staging("exit \(p.terminationStatus) \(argv[0])")
            }
            return String(data: data, encoding: .utf8) ?? ""
        }.value
    }

    /// `TeamIdentifier=<10-char id>` from `codesign -dv` output; tolerates
    /// the parenthesized `TeamIdentifier=(X)` shape; nil when absent or
    /// "not set" (ad-hoc signature).
    static func teamID(fromCodesignOutput output: String) -> String? {
        for line in output.split(separator: "\n") {
            guard let r = line.range(of: "TeamIdentifier=") else { continue }
            let raw = line[r.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            if !raw.isEmpty && raw != "not set" { return raw }
        }
        return nil
    }
}

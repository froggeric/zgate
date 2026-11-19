import Foundation
import Observation

// MARK: - Cadence

/// Check timing (spec §3.4): a launch check only when the last check is
/// missing or older than 6 h, then a 24 h repeat — 2 unauthenticated API
/// calls per cycle (splash + ZGate latest), well inside GitHub's 60/h
/// anonymous budget.
enum UpdateCadence {}

nonisolated extension UpdateCadence {
    static let minLaunchInterval: TimeInterval = 6 * 3600
    static let repeatInterval: TimeInterval = 24 * 3600

    static func shouldCheck(lastCheckAt: Date?, now: Date) -> Bool {
        guard let last = lastCheckAt else { return true }
        return now.timeIntervalSince(last) >= minLaunchInterval
    }
}

// MARK: - ZGate version

/// ZGate release tags are `v{marketing}.{build}` (live: `v2.8.9` = 2.8 (9))
/// — a plain numeric triple, unlike splash's fork-suffixed tags.
enum ZGateVersion {}

nonisolated extension ZGateVersion {
    /// "v2.8.9" → (2, 8, 9); nil when unparseable.
    static func parse(tag: String) -> (Int, Int, Int)? {
        let body = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let n = body.split(separator: ".").compactMap { Int($0) }
        return n.count == 3 ? (n[0], n[1], n[2]) : nil
    }

    static func isNewer(_ tag: (Int, Int, Int), than current: (Int, Int, Int)) -> Bool {
        tag.0 > current.0
            || (tag.0 == current.0
                && (tag.1 > current.1 || (tag.1 == current.1 && tag.2 > current.2)))
    }
}

// MARK: - ZGate release

struct ZGateReleaseAsset: Decodable, Sendable {
    let name: String
    let browser_download_url: URL
    /// GitHub's `digest` field (`sha256:<hex>`); absent on some assets.
    let digest: String?
}

struct ZGateRelease: Decodable, Sendable {
    let tag_name: String
    let assets: [ZGateReleaseAsset]

    /// The one asset we can stage: exact `ZGate-<tag>.zip` name AND a
    /// sha256 digest to verify the download against. nil → cannot check.
    var zipAsset: ZGateReleaseAsset? {
        assets.first {
            $0.name == "ZGate-\(tag_name).zip" && $0.digest?.hasPrefix("sha256:") == true
        }
    }
}

// MARK: - Installed version reader

/// Reads the installed splash version from `release.json` without spawning
/// anything (spec §2): the fork keeps it at
/// `…/Splash-M1/current/release.json`; brew's official install keeps it at
/// the Cellar package root, reached by a symlink-resolved walk-up from the
/// binary. The `--version` fallback is the caller's business
/// (`SplashInstaller.installedVersion`).
enum SplashInstalledVersionReader {}

nonisolated extension SplashInstalledVersionReader {
    /// Fork install root: `~/Library/Application Support/Splash-M1` (one
    /// level above ZGate's own support dir).
    static var forkRoot: URL {
        AppPaths.appSupport.deletingLastPathComponent()
            .appendingPathComponent("Splash-M1", isDirectory: true)
    }

    /// Fork root first (no process), then ≤4 parent hops from the
    /// symlink-resolved binary — furthest ancestor first, so the Cellar
    /// package root outranks anything nearer the binary. nil when no
    /// candidate file decodes. JSONSerialization (not Decodable) keeps
    /// this callable from the nonisolated `installedSplashVersion` seam.
    static func releaseJSONVersion(forkRoot: URL, binaryPath: String?) -> String? {
        var candidates = [forkRoot.appendingPathComponent("current/release.json")]
        if let binaryPath {
            var hops: [URL] = []
            var dir = URL(fileURLWithPath: binaryPath).resolvingSymlinksInPath()
                .deletingLastPathComponent()  // 0 up: the binary's own dir
            hops.append(dir)
            for _ in 0..<4 {                  // 4 parent hops (brew Cellar shape)
                dir = dir.deletingLastPathComponent()
                hops.append(dir)
            }
            candidates += hops.reversed().map { $0.appendingPathComponent("release.json") }
        }
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let version = obj["version"] as? String
            else { continue }
            return version
        }
        return nil
    }
}

// MARK: - UpdateCenter

/// Observable update-check service (spec §3.4): splash installed vs the
/// chip repo's latest tag, ZGate tag triple vs the public repo, launch +
/// daily cadence, per-tag dismissal that expires on a newer tag. Every
/// check failure degrades to a non-alerting state — a failed check never
/// alerts, never crashes. The apply verbs (splash auto-apply, ZGate
/// stage/swap) arrive with their own tasks; this type only observes.
@MainActor @Observable
final class UpdateCenter {
    enum SplashUpdateState: Equatable {
        case unknown                    // never checked / check failed
        case notInstalled               // no binary and no release.json
        case upToDate(installed: String)
        case available(installed: String?, latest: String)
        case failed(String)             // apply-time failure (later task)
    }
    enum ZGateUpdateState: Equatable {
        case unknown
        case upToDate
        case available(tag: String, current: String)
        case cannotCheck                // fetch/decode/asset failure
        case failed(String)             // stage/swap failure (later task)
    }

    private(set) var splashState: SplashUpdateState = .unknown
    private(set) var zgateState: ZGateUpdateState = .unknown

    var hasActiveAlert: Bool { splashAlert || zgateAlert }
    var splashAlert: Bool {
        if case .available(_, let latest) = splashState {
            return latest != settings.dismissedSplashTag
        }
        return false
    }
    var zgateAlert: Bool {
        if case .available(let tag, _) = zgateState {
            return tag != settings.dismissedZGateTag
        }
        return false
    }

    /// Public repo (locked decision 4): anonymous releases/latest; 404,
    /// rate-limit or network failure degrades to `cannotCheck`.
    static let zgateReleasesURL = URL(
        string: "https://api.github.com/repos/froggeric/zgate/releases/latest")!

    struct Deps: Sendable {
        var fetch: @Sendable (URL) async throws -> Data = { url in
            let (d, _) = try await URLSession.shared.data(from: url); return d
        }
        var now: @Sendable () -> Date = { Date() }
        var sleep: @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
        /// release.json (fork root, then binary walk-up) → `--version`.
        var installedSplashVersion: @Sendable (_ chip: SplashChip?) async -> String? = { chip in
            let binaryPath = SplashManager.resolvedBinaryPath(chip: chip)
            if let v = SplashInstalledVersionReader.releaseJSONVersion(
                forkRoot: SplashInstalledVersionReader.forkRoot, binaryPath: binaryPath) {
                return v
            }
            return await SplashInstaller.installedVersion(binaryPath: binaryPath)
        }
        /// `CFBundleShortVersionString` (marketing "2.8") +
        /// `CFBundleVersion` (build "9") → (2, 8, 9). nil when unreadable
        /// or unparseable — never a fabricated fallback version (a failed
        /// read must not invent an update alert).
        var currentZGateVersion: @Sendable () -> (Int, Int, Int)? = {
            let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            return ZGateVersion.parse(tag: "v\(short).\(build)")
        }
    }

    private var settings = UpdateSettings()
    @ObservationIgnored private var configWrite: ((inout UpdateSettings) -> Void)?
    @ObservationIgnored private let deps: Deps
    @ObservationIgnored private var repeatTask: Task<Void, Never>?

    init(deps: Deps = Deps()) {
        self.deps = deps
    }

    deinit { repeatTask?.cancel() }

    /// Config plumbing (the production seam is wired at launch): load the
    /// last-seen state once, then hand every mutation back through
    /// `configWrite`.
    func attach(
        configLoad: @escaping () -> UpdateSettings?,
        configWrite: @escaping ((inout UpdateSettings) -> Void)
    ) {
        settings = configLoad() ?? UpdateSettings()
        self.configWrite = configWrite
    }

    /// Launch entry: one cadence-gated check, then the 24 h repeat.
    /// `splashChecksEnabled` = `SplashManager.shouldSupervise` (splash
    /// work is supervised-environment-only; the ZGate check always runs).
    /// The `autoCheck` toggle gates every automatic check — manual
    /// `checkNow` is unaffected (spec §4).
    func start(splashChecksEnabled: Bool) async {
        guard settings.autoCheck else { return }
        if UpdateCadence.shouldCheck(lastCheckAt: settings.lastCheckAt, now: deps.now()) {
            await checkNow(splash: splashChecksEnabled)
        }
        let deps = self.deps
        repeatTask?.cancel()  // double-start guard: never two repeat loops
        repeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await deps.sleep(UpdateCadence.repeatInterval)
                guard let self else { return }
                await self.checkNow(splash: splashChecksEnabled)
            }
        }
    }

    func stop() {
        repeatTask?.cancel()
        repeatTask = nil
    }

    /// One full cycle: splash (unless disabled — M3+ unsupervised hosts,
    /// or `splash: false` for a ZGate-only refresh), then ZGate. Persists
    /// the last-seen tags and `lastCheckAt` — degraded cycles included,
    /// which is what prevents a retry storm after a failed check.
    func checkNow(splash: Bool = true, chip: SplashChip? = SplashChip.current) async {
        if splash {
            await checkSplash(chip: chip)
        }
        await checkZGate()
        settings.lastCheckAt = deps.now()
        persist()
    }

    /// Per-tag dismissal: suppresses this tag's alert; a newer tag
    /// re-alerts automatically (the alert accessors compare tags).
    func dismissSplash(tag: String) {
        settings.dismissedSplashTag = tag
        persist()
    }

    func dismissZGate(tag: String) {
        settings.dismissedZGateTag = tag
        persist()
    }

    // MARK: - Private

    private func checkSplash(chip: SplashChip?) async {
        let installer = SplashInstaller(deps: SplashInstallerDeps(fetch: deps.fetch))
        guard let latest = await installer.latestRelease(for: chip) else {
            splashState = .unknown  // fetch/decode failure — never alerts
            return
        }
        settings.lastSplashTag = latest.tag_name
        guard let installed = await deps.installedSplashVersion(chip) else {
            splashState = .notInstalled
            return
        }
        guard let latestParts = SplashVersion.parseTag(latest.tag_name),
              let installedParts = Self.splashParts(installed)
        else {
            // Unparseable version strings — cannot prove either verdict.
            splashState = .unknown
            return
        }
        if SplashVersion.isOlder(installedParts, than: latestParts) {
            splashState = .available(installed: installed, latest: latest.tag_name)
        } else {
            splashState = .upToDate(installed: installed)
        }
    }

    private func checkZGate() async {
        guard let data = try? await deps.fetch(Self.zgateReleasesURL),
              let release = try? JSONDecoder().decode(ZGateRelease.self, from: data),
              release.zipAsset != nil,
              let latest = ZGateVersion.parse(tag: release.tag_name)
        else {
            zgateState = .cannotCheck  // repo unreachable/private, no verifiable asset
            return
        }
        settings.lastZGateTag = release.tag_name
        guard let current = deps.currentZGateVersion() else {
            // Running version unreadable — availability is unknowable, so
            // degrade honestly instead of fabricating an update (a failed
            // read must never alert).
            zgateState = .cannotCheck
            return
        }
        if ZGateVersion.isNewer(latest, than: current) {
            zgateState = .available(tag: release.tag_name, current: "\(current.0).\(current.1).\(current.2)")
        } else {
            zgateState = .upToDate
        }
    }

    /// The installed-version seam returns either form: a `release.json`
    /// tag (`1.6.1-m1.1`) or `--version` output (`Splash 1.6.1-m1.1`).
    private static func splashParts(_ s: String) -> [Int]? {
        SplashVersion.parseTag(s.hasPrefix("Splash ") ? String(s.dropFirst("Splash ".count)) : s)
    }

    private func persist() {
        configWrite?(&settings)
    }
}

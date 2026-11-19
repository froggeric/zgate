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
/// chip repo's latest tag, ZGate tag triple vs the public repo (delegated
/// to AppUpdateService — one fetcher, no duplication), launch + daily
/// cadence, per-tag dismissal that expires on a newer tag, and the splash
/// AUTO-APPLY (locked decision 2) driven through two SplashManager hooks
/// — apply when stopped, defer while owned-running, banner only when
/// adopted. Every check failure degrades to a non-alerting state — a
/// failed check never alerts, never crashes; a failed apply never blocks
/// a splash start. The ZGate stage/swap verbs are AppUpdateService's.
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

    /// Public repo (locked decision 4): anonymous releases/latest. The
    /// fetcher/decoder now live in AppUpdateService; this alias keeps the
    /// check URL addressable here (same constant, no second source).
    static let zgateReleasesURL = AppUpdateService.releasesURL

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
        /// Auto-apply's macOS floor (both repos need 26.4, spec §3.2);
        /// injected so tests pin both the refusal and the proceed side.
        var osVersion: @Sendable () -> OperatingSystemVersion = {
            ProcessInfo.processInfo.operatingSystemVersion
        }
        /// Fork tarball apply (spec §3.2); returns the installed tag.
        var applyFork: @Sendable (SplashRelease) async throws -> String = { release in
            try await SplashTarballInstaller().install(release: release)
        }
        /// Official brew apply (spec §3.3); argv[0] is the executable.
        var applyBrew: @Sendable ([String]) async throws -> Void = { argv in
            try await SplashInstaller.runBrew(argv: argv)
        }
    }

    private var settings = UpdateSettings()
    @ObservationIgnored private var configWrite: ((inout UpdateSettings) -> Void)?
    @ObservationIgnored private let deps: Deps
    @ObservationIgnored private var repeatTask: Task<Void, Never>?
    /// Shared installer (rides the injected fetch seam) for check + apply.
    private let installer: SplashInstaller
    /// ZGate-check delegation (spec §3.5): the check — and the explicit-
    /// click stage/swap verbs the UI calls directly — live in one service
    /// riding the same fetch seam.
    @ObservationIgnored private let appUpdate: AppUpdateService
    /// Weak: the manager owns the lifecycle; the center only observes it.
    @ObservationIgnored private weak var manager: SplashManager?
    /// One apply at a time (spec §3.4); also the re-entrancy break for
    /// apply → checkNow → evaluateAutoApply.
    @ObservationIgnored private var applying = false
    /// An update was seen while the engine ran owned — applied at the stop
    /// hook or the next start gate, whichever comes first.
    @ObservationIgnored private var pendingApply = false
    /// Chip the last check ran for; the apply branches on the same value.
    @ObservationIgnored private var chip: SplashChip? = SplashChip.current

    init(deps: Deps = Deps()) {
        self.deps = deps
        self.installer = SplashInstaller(deps: SplashInstallerDeps(fetch: deps.fetch))
        self.appUpdate = AppUpdateService(deps: AppUpdateService.Deps(fetch: deps.fetch))
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

    /// SplashManager wiring (spec §3.4 apply side): the start gate applies
    /// a pending update before the next spawn — and returns true whatever
    /// happened, so a failed apply never blocks the start; the stop hook
    /// re-evaluates auto-apply the moment a deliberate stop lands an owned
    /// child in .stopped.
    func attach(to manager: SplashManager) {
        self.manager = manager
        manager.preStartUpdateGate = { [weak self] in
            guard let self, self.pendingApply else { return true }
            await self.applySplashUpdate()
            return true   // proceed with the start whatever happened
        }
        manager.ownedStoppedHook = { [weak self] in
            guard let self else { return }
            Task { await self.evaluateAutoApply() }
        }
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
    /// which is what prevents a retry storm after a failed check. Ends by
    /// re-evaluating auto-apply against the fresh verdict.
    func checkNow(splash: Bool = true, chip: SplashChip? = SplashChip.current) async {
        self.chip = chip
        if splash {
            await checkSplash(chip: chip)
        }
        await checkZGate()
        settings.lastCheckAt = deps.now()
        persist()
        await evaluateAutoApply()
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

    // MARK: - Splash auto-apply (spec §3.4, locked decision 2)

    /// After every check + on the stop hook: apply when the engine is
    /// stopped, defer (pendingApply) while it runs OWNED — the flag is
    /// consumed by the start gate or the stop hook, whichever lands first.
    /// Adopted/external instances are banner-only, never touched.
    func evaluateAutoApply() async {
        guard case .available = splashState, settings.splashAutoApply else { return }
        if manager?.state == .stopped {
            await applySplashUpdate()
        } else if case .running(_, _, false)? = manager?.state {
            pendingApply = true
        }
    }

    /// Apply the available splash update: fork tarball or official brew
    /// (whichever `installVariant` picks for this chip), one at a time,
    /// macOS ≥ 26.4 gated, post-apply version-verified. Every refusal and
    /// failure degrades to `.failed` — non-alerting, never blocking.
    func applySplashUpdate() async {
        guard !applying, case .available(_, let latest) = splashState else { return }
        guard SplashChip.macOSSupportsSplash(deps.osVersion()) else {
            splashState = .failed("needs macOS 26.4+")
            return
        }
        applying = true
        pendingApply = false
        defer { applying = false }
        switch SplashTabModel.installVariant(chipKind: chip) {
        case .fork:
            guard let release = await installer.latestRelease(for: chip) else {
                splashState = .failed("release unavailable")
                return
            }
            do { _ = try await deps.applyFork(release) }
            catch {
                splashState = .failed(String(describing: error))
                return
            }
        case .brewOfficial:
            // .available implies an installed version → the upgrade verb.
            do { try await deps.applyBrew(SplashInstaller.brewArguments(installed: true)) }
            catch {
                splashState = .failed(String(describing: error))
                return
            }
        }
        // Post-apply verify (spec §3.4): the new version must answer, in
        // either form the seam returns (release.json tag / --version).
        let answered = await deps.installedSplashVersion(chip)
        guard let answered, Self.splashParts(answered) == SplashVersion.parseTag(latest) else {
            splashState = .failed("verify: still \(answered ?? "?")")
            return
        }
        // The trailing evaluateAutoApply sees .upToDate (and `applying` is
        // still set) — no re-entry loop.
        await checkNow(chip: chip)
    }

    // MARK: - Private

    private func checkSplash(chip: SplashChip?) async {
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
        guard let current = deps.currentZGateVersion() else {
            // Running version unreadable — availability is unknowable, so
            // degrade honestly instead of fabricating an update (a failed
            // read must never alert).
            zgateState = .cannotCheck
            return
        }
        // One fetcher, one decoder (spec §3.5): the service owns the check.
        zgateState = await appUpdate.checkState(current: current)
        if let release = appUpdate.lastCheckedRelease {
            settings.lastZGateTag = release.tag_name
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

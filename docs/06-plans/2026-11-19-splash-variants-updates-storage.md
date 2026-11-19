# Splash Variants, Update Center, Storage Management — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the approved spec `docs/specs/2026-11-19-splash-variants-updates-storage-design.md`: per-chip splash correctness (M1/M2 fork tarball vs M3+ brew), a version-update center with auto-apply-when-stopped for splash and explicit-click self-update for ZGate via bundled `release-swap.sh`, first-class storage/cache settings, menu-bar alert badge, and About credits.

**Architecture:** `SplashChip` becomes the per-variant table consumed by resolution/latest-check/install; a new tarball installer replaces the rotten direct-binary path; an `UpdateCenter` (@MainActor @Observable) owns check cadence + alert state and drives splash auto-apply through two hooks on `SplashManager`; `AppUpdateService` stages a digest-verified zip and delegates the swap to the bundled script; `SplashStorage` rides `SplashSettings` into `serveArguments` and the launch environment.

**Tech Stack:** Swift 6, SwiftUI, SwiftNIO (untouched), CryptoKit (SHA-256), Swift Testing. No new packages.

**Spec:** `docs/specs/2026-11-19-splash-variants-updates-storage-design.md` — read it first; this plan argues from it.

## Global Constraints

- **Test command** (suite-wide): `xcodebuild test -project ZGate.xcodeproj -scheme ZGate -destination 'platform=macOS'`; single suite: append `-only-testing:ZGateTests/<SuiteName>`. Test sources live in `ModelProxyTests/` but the target is `ZGateTests`.
- **New files auto-build**: the project uses `PBXFileSystemSynchronizedRootGroup` — new `.swift` files under `ModelProxy/` / `ModelProxyTests/` need NO pbxproj edits. Only Task 7 edits pbxproj (script resource).
- **No network in tests**: every network path goes through an injected `fetch: @Sendable (URL) async throws -> Data` seam. Production default is URLSession.
- **nil-on-failure**: any GitHub fetch/decode failure yields nil / a non-alerting state — never a crash, never a wrong verdict (spec §3.4).
- **Tolerant decode**: every new persisted key decodes with `try?` + default so pre-existing `config.json` files load unchanged (spec §4).
- **extraArgs keep last word**: storage flags emit BEFORE `extraArgs`; `--port` logic scans the full list (spec §3.6).
- **shouldSupervise gate** (`SplashManager.swift:162-165`): launch-time splash supervision/update work runs only when it returns true; tests never spawn the real splash and never execute the real swap script (stub its path).
- **Self-update is explicit-click only**; the swap script is spawned detached and not awaited (the app dies mid-run by design, spec §3.5).
- **Commit style**: plain conventional commits, no emoji (`docs(spec): …`, `feat(splash): …`), matching repo history.
- Fork asset naming (verified live 2026-11-19): `splash-<tag>-arm64-macos26.tar.gz` + `.sha256` sidecar (65 B hex digest) — identical pattern on both repos. Fork install root: `~/Library/Application Support/Splash-M1/<tag>` + `current` symlink; shim `splash-m1` execs `<root>/current/python/bin/python3 -u <root>/current/install/launcher.py "$@"` with `PYTHONDONTWRITEBYTECODE=1`.

**User decisions (already made):**
- ZGate self-update = custom updater + bundled `release-swap.sh`; explicit click only (2026-11-19).
- Splash updates auto-apply when stopped; owned-running defers to next stop/start; adopted never (2026-11-19).
- Storage scope = model cache (HF_HUB_CACHE) AND prefix cache flags (2026-11-19).
- Repo is PUBLIC since 2026-11-19 (verified anonymous `releases/latest` → `v2.8.9`).

## Review Focus

1. **Fork-patch version ordering** — `1.6.1-m1` vs `1.6.1-m1.1`: `SplashVersion.parse` currently drops the suffix → equal → update never offered. Task 5 extends it to keep the fork patch as a 4th component and pins the ordering.
2. **`.sha256` sidecar whitespace** — the 65-byte file ends with a newline; a naive hex compare fails and kills every install. Task 3 trims all whitespace (mirrors `install-m1.sh`'s `tr -d '[:space:]'`) and tests it.
3. **Dismissed tag, newer tag appears** — dismissal must expire silently when `latest != dismissedTag`. Task 5 pins it.
4. **Old config, new keys** — pre-2026-11-19 `config.json` has no `splash.storage` / `update` section; decode must default, never reset. Tasks 4 & 5 pin it.
5. **GitHub 404/rate-limit/network failure** — every fetch failure degrades to a non-alerting state (`unknown` / `cannotCheck`), never blocks splash start. Tasks 5 & 7 pin it.

---

### Task 1: SplashChip variant table + per-chip binary resolution + macOS gate

**Goal:** One source of truth for per-chip facts (binary name, repo slug, releases URL, macOS gate) and a resolution order that finds the official `splash` binary on M3+ (and the fork's `~/.local/bin` fallback).

**Files:**
- Modify: `ModelProxy/Services/SplashInstaller.swift` (extend `SplashChip` at :5-30; add `latestRelease(for:)` beside `latestForkRelease` at :123)
- Modify: `ModelProxy/Services/SplashManager.swift:142-155` (`resolvedBinaryPath`)
- Test: `ModelProxyTests/SplashVariantTests.swift` (new)

**Acceptance Criteria:**
- [ ] `SplashChip.binaryName` = `splash-m1` (fork) / `splash` (official); `repoSlug` = `paperniuk/splash` / `incoai/splash`; `releasesURL(for:)` builds the right api.github.com URL (nil chip → fork).
- [ ] `SplashChip.macOSSupportsSplash` true for 26.4/27.2, false for 26.3/15.7.
- [ ] `resolvedBinaryPath` probes override → `/opt/homebrew/bin/<name>` → `~/.local/bin/<name>` → app-support `bin/<name>`, with the chip's name in every hop; stale override falls through.
- [ ] Full suite green.

**Verify:** `xcodebuild test -project ZGate.xcodeproj -scheme ZGate -destination 'platform=macOS' -only-testing:ZGateTests/SplashVariantTests` → all pass.

**Steps:**

- [ ] **Step 1: Write the failing test** — `ModelProxyTests/SplashVariantTests.swift`:

```swift
import Testing
import Foundation
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
```

- [ ] **Step 2: Run** → fails (`binaryName`, `macOSSupportsSplash`, new `resolvedBinaryPath` parameters don't exist).

- [ ] **Step 3: Implement.** In `SplashInstaller.swift`, extend `SplashChip`:

```swift
extension SplashChip {
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
```

Add beside `latestForkRelease` (keep `latestForkRelease` until Task 3 deletes it):

```swift
    /// Latest release for the chip's repo (spec §3.1); nil on ANY failure.
    func latestRelease(for chip: SplashChip?) async -> SplashRelease? {
        guard let data = try? await deps.fetch(SplashChip.releasesURL(for: chip)) else { return nil }
        return try? JSONDecoder().decode(SplashRelease.self, from: data)
    }
```

In `SplashManager.swift`, replace `resolvedBinaryPath` (:149-155) — keep the zero-arg call sites compiling via defaults:

```swift
    /// Binary resolution (spec §3.1): override (if present) →
    /// /opt/homebrew/bin/<chip binary> → ~/.local/bin/<chip binary> (the
    /// fork installer's fallback) → app-support bin/<chip binary>. A stale
    /// override falls through so it can never brick launches.
    nonisolated static func resolvedBinaryPath(
        override: String? = nil,
        chip: SplashChip? = SplashChip.current,
        fileExists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        homebrewBinDir: String = "/opt/homebrew/bin",
        localBinDir: String? = NSHomeDirectory() + "/.local/bin"
    ) -> String {
        if let override, fileExists(override) { return override }
        let name = (chip ?? .forkM1M2).binaryName
        let homebrew = "\(homebrewBinDir)/\(name)"
        if fileExists(homebrew) { return homebrew }
        if let localBinDir {
            let local = "\(localBinDir)/\(name)"
            if fileExists(local) { return local }
        }
        return fallbackBinDir.appendingPathComponent("bin/\(name)").path
    }
```

- [ ] **Step 4: Run suite** → green (existing `SplashManagerTests` resolution tests still pass — behavior for fork chips is unchanged on machines with the homebrew shim).
- [ ] **Step 5: Commit** `feat(splash): per-chip binary names, repo URLs, macOS 26.4 gate`

---

### Task 2: Splash vendor baseURL follows the configured port

**Goal:** Kill the hardcoded `127.0.0.1:8123` desync — routing targets for the splash vendor derive from `SplashSettings.port` (spec §6.1).

**Files:**
- Modify: `ModelProxy/Models/AppConfig.swift` (new pure helper near `makeZGateDefaultRouting` :200)
- Modify: `ModelProxy/Proxy/ProxyServer.swift` (apply at the routing-snapshot build in `start(config:)`)
- Test: `ModelProxyTests/SplashPortSyncTests.swift` (new)

**Acceptance Criteria:**
- [ ] `AppConfig.syncingSplashVendor(_:splashPort:)` rewrites only the local splash vendor row (name contains "splash", host 127.0.0.1); other vendors untouched.
- [ ] `ProxyServer.start(config:)` builds routing from the synced vendors (in-memory only — nothing persisted).
- [ ] Config with `splash.port = 9999` → the qwen lever's route target baseURL is `http://127.0.0.1:9999`.
- [ ] Full suite green (existing RouterTests unaffected).

**Verify:** `xcodebuild test … -only-testing:ZGateTests/SplashPortSyncTests` → pass.

**Steps:**

- [ ] **Step 1: Failing test**:

```swift
import Testing
import Foundation
@testable import ZGate

@Suite struct SplashPortSyncTests {
    private func qwenLeverConfig(port: Int?) -> AppConfig {
        var cfg = AppConfig.makeDefault()
        cfg.splash?.port = port ?? 8123
        // enable the shipped disabled sonnet→local-qwen lever so a class
        // rule targets the splash vendor
        if let i = cfg.modelMappings.firstIndex(where: { $0.sourceModel.contains("local qwen") }) {
            cfg.modelMappings[i].isEnabled = true
        }
        return cfg
    }

    @Test func baseURLFollowsPort() {
        let vendors = AppConfig.syncingSplashVendor(
            qwenLeverConfig(port: 9999).vendors, splashPort: 9999)
        let splash = vendors.first { $0.name.lowercased().contains("splash") }!
        #expect(splash.baseURL == "http://127.0.0.1:9999")
    }

    @Test func nilPortKeepsDefault8123() {
        let vendors = AppConfig.syncingSplashVendor(
            qwenLeverConfig(port: nil).vendors, splashPort: nil)
        let splash = vendors.first { $0.name.lowercased().contains("splash") }!
        #expect(splash.baseURL == "http://127.0.0.1:8123")
    }

    @Test func relayVendorUntouched() {
        let vendors = AppConfig.syncingSplashVendor(
            qwenLeverConfig(port: 9999).vendors, splashPort: 9999)
        let relay = vendors.first { $0.vendorKind == .relay }!
        #expect(relay.baseURL.contains("zcode.z.ai"))
    }

    @Test func routingTableSeesSyncedPort() {
        let cfg = qwenLeverConfig(port: 9555)
        let vendors = AppConfig.syncingSplashVendor(cfg.vendors, splashPort: 9555)
        let table = ClassRuleTable(from: cfg.modelMappings, vendors: vendors, clientID: cfg.clients.first!.id)
        let targets = table.targets(
            for: "glm-5.3[1m]-sonnet", context: ConditionContext(now: Date()))?
            .map(\.baseURL) ?? []
        #expect(targets.contains("http://127.0.0.1:9555"))
    }
}
```

(If the sonnet-lever `sourceModel` string differs, adapt the fixture to whatever `makeZGateDefaultRouting` names it — the assertion that matters is the splash target's baseURL.)

- [ ] **Step 2: Run** → fails (no `syncingSplashVendor`).

- [ ] **Step 3: Implement** in `AppConfig.swift`:

```swift
extension AppConfig {
    /// Spec §6.1: the stored splash vendor baseURL (default 8123) goes stale
    /// the moment the user changes the port. Pure in-memory rewrite used to
    /// build routing; NEVER persisted (the stored row keeps its default).
    static func syncingSplashVendor(_ vendors: [Vendor], splashPort: Int?) -> [Vendor] {
        let port = splashPort ?? 8123
        return vendors.map { v in
            guard v.name.lowercased().contains("splash"),
                  v.baseURL.contains("127.0.0.1") else { return v }
            var out = v
            out.baseURL = "http://127.0.0.1:\(port)"
            return out
        }
    }
}
```

In `ProxyServer.start(config:)` (grep `config.vendors` — the snapshot/`ClassRuleTable` build site), build from the synced array:

```swift
let vendors = AppConfig.syncingSplashVendor(config.vendors, splashPort: config.splash?.port)
```

and thread `vendors` into the snapshot construction (the same variable `config.vendors` fed before). If `start` re-reads `config.vendors` in a reload path, apply the same sync there — the helper is pure and idempotent.

- [ ] **Step 4: Run full suite** → green.
- [ ] **Step 5: Commit** `fix(routing): splash vendor baseURL follows configured port`

---

### Task 3: SplashTarballInstaller replaces the rotten fork install path

**Goal:** A working fork install/update mechanism mirroring `install-m1.sh` (tarball + SHA-256 + unpack + `current` symlink + shim + prune), uniform asset rule for both repos; delete `SplashAssetPicker` / `installForkBinary` (spec §3.2, §1.2).

**Files:**
- Create: `ModelProxy/Services/SplashTarballInstaller.swift`
- Modify: `ModelProxy/Services/SplashInstaller.swift` (delete `SplashAssetPicker` :69-81, `installForkBinary` :146-167, `SplashInstallOutcome`/`SplashInstallerError`, `latestForkRelease` :123-126 and `static let releasesURL` :108-109 — superseded by Task 1's `latestRelease(for:)`)
- Modify: `ModelProxy/Views/SplashTabView.swift:390-427` (`runInstall` fork branch rewires)
- Modify: `ModelProxyTests/SplashInstallerTests.swift` (delete tests of removed API)
- Test: `ModelProxyTests/SplashTarballInstallerTests.swift` (new)

**Acceptance Criteria:**
- [ ] `assetPair(from:)` picks `splash-<tag>-arm64-macos26.tar.gz` + its `.sha256`; nil when either is missing.
- [ ] Install into an injectable root: verify SHA-256 (hex compare after whitespace trim) → `tar -xzf --strip-components 1` into `<root>/<tag>.partial` → quarantine strip → replace `<tag>` dir → atomic `current` symlink swap → shim written (exact 3-line contents, 0755; legacy binary at the shim path backed up to `splash-m1.zgate-legacy`) → prune keeps current + one previous → `--version` verify.
- [ ] Checksum mismatch aborts with the previous install untouched.
- [ ] The Splash tab's fork Install button works again (rewired, no `binaryPathOverride` fallback flow).
- [ ] Full suite green.

**Verify:** `xcodebuild test … -only-testing:ZGateTests/SplashTarballInstallerTests` → pass.

**Steps:**

- [ ] **Step 1: Failing test** — build a REAL tarball fixture at test time (no network; tar/xattr are local tools):

```swift
import Testing
import Foundation
@testable import ZGate

@Suite struct SplashTarballInstallerTests {
    /// Makes <dir>/pkg/inner/hello.txt, tars it the way the repos ship
    /// (single wrapper component → --strip-components 1), returns tar data
    /// + its SHA-256 hex.
    private func makeTarball(_ dir: URL) throws -> (Data, String) {
        let inner = dir.appendingPathComponent("pkg/inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: inner.appendingPathComponent("hello.txt"))
        let tarPath = dir.appendingPathComponent("splash-X-arm64-macos26.tar.gz").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-czf", tarPath, "-C", dir.appendingPathComponent("pkg").path, "inner"]
        try p.run(); p.waitUntilExit()
        let data = try Data(contentsOf: URL(fileURLWithPath: tarPath))
        let hex = SHA256Hex.of(data)
        return (data, hex)
    }

    private func release(tag: String, tar: Data, hex: String) -> SplashRelease {
        func asset(_ name: String) -> SplashReleaseAsset {
            SplashReleaseAsset(name: name, browser_download_url: URL(string: "https://x/\(name)")!)
        }
        return SplashRelease(tag_name: tag, assets: [
            asset("splash-\(tag)-arm64-macos26.tar.gz"),
            asset("splash-\(tag)-arm64-macos26.tar.gz.sha256"),
            asset("install-m1.sh"), asset("Splash-\(tag).dmg"),
        ])
    }

    private struct Harness {
        let root: URL, binDir: URL, tarData: (Data, String)
        var installer: SplashTarballInstaller {
            var i = SplashTarballInstaller()
            let (data, hex) = tarData
            i.deps.fetch = { url in
                if url.absoluteString.hasSuffix(".sha256") { return Data("\(hex)\n".utf8) }
                return data
            }
            return i
        }
    }

    @Test func installsUnpacksSwapsSymlinkWritesShim() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("tarball-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let h = Harness(root: base.appendingPathComponent("Splash-M1"),
                        binDir: base.appendingPathComponent("bin"),
                        tarData: try makeTarball(base))
        let rel = release(tag: "1.6.1-m1.1", tar: h.tarData.0, hex: h.tarData.1)
        let tag = try await h.installer.install(release: rel, installRoot: h.root, binDir: h.binDir)
        #expect(tag == "1.6.1-m1.1")
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
        // …same harness, corrupt the sidecar hex → throws .checksumMismatch;
        // a pre-seeded <root>/current symlink still points at the old tag.
    }

    @Test func whitespaceInSidecarIsTolerated() async throws {
        // sidecar Data("  <hex>\n\n") → install still succeeds.
    }

    @Test func missingSidecarThrowsMissingAssets() async throws { /* assets w/o .sha256 */ }

    @Test func legacyShimBackedUp() async throws {
        // pre-write a plain-binary-looking shim at binDir/splash-m1 →
        // after install, binDir/splash-m1.zgate-legacy exists with old bytes.
    }

    @Test func pruneKeepsCurrentAndOnePrevious() async throws {
        // pre-create root/1.5.0-m1 and root/1.6.0-m1 dirs; install 1.6.1-m1.1
        // → 1.5.0-m1 gone, 1.6.0-m1 kept.
    }
}
```

Add a tiny shared helper `SHA256Hex.of(Data) -> String` (hex-encode `CryptoKit.SHA256.hash(data:)`) — put it in `SplashTarballInstaller.swift` and `@testable`-use it, or duplicate 5 lines in the test file (prefer the former).

- [ ] **Step 2: Run** → fails (type doesn't exist).

- [ ] **Step 3: Implement** `ModelProxy/Services/SplashTarballInstaller.swift`:

```swift
import CryptoKit
import Foundation

enum SHA256Hex {
    static func of(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Fork install/update, mirroring paperniuk's install-m1.sh step for step
/// (spec §3.2) — but executed by us, never by piping the remote script.
struct SplashTarballInstaller: Sendable {
    struct Deps: Sendable {
        var fetch: @Sendable (URL) async throws -> Data = { url in
            let (d, _) = try await URLSession.shared.data(from: url); return d
        }
        /// Runs argv (argv[0] = executable); non-zero exit throws.
        var run: @Sendable ([String]) async throws -> Void
        /// Runs argv, returns trimmed stdout; non-zero exit throws nil.
        var capture: @Sendable ([String]) async -> String?
        var fileExists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
        var isWritable: @Sendable (String) -> Bool = { FileManager.default.isWritableFile(atPath: $0) }
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
        var ok = ObjCBool(false)
        return FileManager.default.isWritableFile(atPath: hb.path, &ok) && ok.boolValue
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

        // Atomic current swap: build the symlink beside it, rename over.
        let current = root.appendingPathComponent("current")
        let linkTmp = root.appendingPathComponent(".current-\(UUID().uuidString)")
        try? fm.removeItem(at: linkTmp)
        try fm.createSymbolicLink(at: linkTmp, withDestinationURL: final)
        _ = try fm.replaceItemAt(current, withItemAt: linkTmp) ?? current

        try await ensureShim(root: root, binDir: binDir ?? Self.defaultBinDir)
        prune(keeping: tag, plus: 1, under: root)

        // Sanity (spec §3.2 step 6): --version must answer the new tag.
        let shim = (binDir ?? Self.defaultBinDir).appendingPathComponent("splash-m1").path
        if let out = await deps.capture([shim, "--version"]), !out.isEmpty,
           out.contains(tag) { return tag }
        throw InstallError.verifyFailed(tag)
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
        let existing = try? String(contentsOf: shim, encoding: .utf8)
        if existing != contents {
            if existing != nil {   // legacy ZGate plain binary → keep a backup
                try? fm.copyItem(at: shim, to: binDir.appendingPathComponent("splash-m1.zgate-legacy"))
            }
            try fm.removeItem(at: shim)
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
}
```

Wire the default `run`/`capture` seams like `SplashTabModel.runBrewProcess` (Process + Pipe, detached; `capture` returns stdout trimmed).

Delete from `SplashInstaller.swift`: `SplashAssetPicker`, `installForkBinary`, `SplashInstallOutcome`, `SplashInstallerError`, `latestForkRelease`, `static let releasesURL`, `homebrewPath`/`fallbackPath` (superseded). Update `SplashTabView.runInstall` fork branch:

```swift
case .fork:
    guard let release = await SplashInstaller().latestRelease(for: chipKind) else {
        installLine += " · no release info"
        return
    }
    do {
        _ = try await SplashTarballInstaller().install(release: release)
        refreshInstallLine()
    } catch {
        installLine += " · install failed"
    }
```

and delete the `SplashAssetPicker`/`installedAt` references plus the `binaryPathOverride` persistence block (the shim layout owns resolution now). Delete the removed-API tests in `SplashInstallerTests.swift`.

- [ ] **Step 4: Run full suite** → green.
- [ ] **Step 5: Commit** `feat(splash): tarball+sha256 installer replaces dead binary path`

---

### Task 4: SplashStorage model + arg emission + migration + launch env

**Goal:** First-class storage/cache settings that emit documented flags before `extraArgs`, inject `HF_HUB_CACHE` into the splash process, and migrate the owner's hand-written extraArgs into the UI (spec §3.6, §4).

**Files:**
- Create: `ModelProxy/Models/SplashStorage.swift`
- Modify: `ModelProxy/Models/SplashSettings.swift` (`storage` field + tolerant decode; `serveArguments(port:storage:)` :39-45)
- Modify: `ModelProxy/Services/ConfigStore.swift` (`applyMigrations` :104+, new migration 8)
- Modify: `ModelProxy/Services/SplashManager.swift` (`beginStart` :279-297 env injection)
- Test: `ModelProxyTests/SplashStorageTests.swift` (new) + a case in `ModelProxyTests/ConfigMigrationTests.swift` + an env case in `ModelProxyTests/SplashManagerTests.swift`

**Acceptance Criteria:**
- [ ] Defaults emit NO flags and NO env override; each field emits its documented flag; `--cache-dir` only when `persistentCache` is on; write budget/quota strings pass through verbatim.
- [ ] `serveArguments(port:storage:)` order: profile flags → storage flags → `extraArgs` → `--port` if absent anywhere; an `--port` inside extraArgs still wins.
- [ ] Migration 8 (one-shot, `storage == nil` guard) lifts `--persistent-cache`, `--cache-dir X`, `--max-cache-disk X`, `--max-cache-disk-writes X` (both `flag X` and `flag=X` forms) out of the ACTIVE profile only; idempotent; old configs without the key decode to defaults.
- [ ] `beginStart` passes inherited env + `HF_HUB_CACHE` when `modelCacheLocation` is set (stub-script behavioral test).
- [ ] Full suite green.

**Verify:** `xcodebuild test … -only-testing:ZGateTests/SplashStorageTests -only-testing:ZGateTests/ConfigMigrationTests` → pass.

**Steps:**

- [ ] **Step 1: Failing tests** — `SplashStorageTests.swift`:

```swift
import Testing
import Foundation
@testable import ZGate

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
        let s = SplashStorage(cacheDir: "/x", persistentCache: false)
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
```

ConfigMigrationTests addition:

```swift
    @Test func migration8LiftsActiveProfileCacheFlags() {
        var cfg = AppConfig.makeDefault()
        cfg.splash?.storage = nil
        // active profile carries the owner's hand-written flags (spec §2)
        if let i = cfg.splash?.profiles.firstIndex(where: { $0.id == cfg.splash?.activeProfileID }) {
            cfg.splash?.profiles[i].extraArgs = ["--persistent-cache", "--cache-dir", "/v/s", "--max-cache-disk", "20G"]
        }
        let out = ConfigStore.applyMigrations(cfg)
        #expect(out.splash?.storage?.cacheDir == "/v/s")
        #expect(out.splash?.storage?.maxCacheDisk == "20G")
        let active = out.splash!.profiles.first { $0.id == out.splash!.activeProfileID }!
        #expect(!active.extraArgs.contains("--persistent-cache"))
        // one-shot: running again changes nothing
        let again = ConfigStore.applyMigrations(out)
        #expect(again == out)
    }
```

SplashManagerTests env case (reuse the existing stub-script pattern — a script that writes `env`/`args` to a file under a temp dir):

```swift
    @Test func launchInjectsHFCacheEnv() async throws {
        // stub script: #!/bin/sh ; env > "$OUT" ; printf '%s\n' "$@" >> "$OUT"
        // settings.storage.modelCacheLocation = "/v/hub" → spawned process env
        // contains HF_HUB_CACHE=/v/hub AND still contains PATH.
    }
```

- [ ] **Step 2: Run** → fails.

- [ ] **Step 3: Implement.** `SplashStorage.swift`:

```swift
import Foundation

/// Machine-level splash storage/cache settings (spec §3.6). Not per-profile:
/// disk layout is a machine concern. Emitted BEFORE profile extraArgs —
/// extraArgs keep their documented last-word override.
struct SplashStorage: Codable, Equatable, Sendable {
    /// HF download cache override → HF_HUB_CACHE env at launch.
    /// nil = splash default (~/.cache/huggingface/hub).
    var modelCacheLocation: String?
    /// → --persistent-cache (enables --cache-dir).
    var persistentCache: Bool = false
    /// → --cache-dir (only emitted when persistentCache).
    var cacheDir: String?
    /// → --max-cache-disk; nil = auto (no flag); "0" = off; e.g. "16G".
    var maxCacheDisk: String?
    /// → --max-cache-disk-writes; nil = no flag (no budget).
    var maxCacheDiskWrites: String?

    init(modelCacheLocation: String? = nil, persistentCache: Bool = false,
         cacheDir: String? = nil, maxCacheDisk: String? = nil,
         maxCacheDiskWrites: String? = nil) { /* straight assignment */ }

    var launchFlags: [String] {
        var f: [String] = []
        if persistentCache { f.append("--persistent-cache") }
        if persistentCache, let cacheDir, !cacheDir.isEmpty { f += ["--cache-dir", cacheDir] }
        if let maxCacheDisk, !maxCacheDisk.isEmpty { f += ["--max-cache-disk", maxCacheDisk] }
        if let maxCacheDiskWrites, !maxCacheDiskWrites.isEmpty { f += ["--max-cache-disk-writes", maxCacheDiskWrites] }
        return f
    }

    var environment: [String: String]? {
        guard let modelCacheLocation, !modelCacheLocation.isEmpty else { return nil }
        return ["HF_HUB_CACHE": modelCacheLocation]
    }

    /// Migration 8: lift recognized cache flags out of extraArgs (both
    /// `--flag X` and `--flag=X`). Unknown flags untouched.
    static func lift(from extraArgs: inout [String]) -> SplashStorage {
        var s = SplashStorage()
        var i = 0
        func value(form: String) -> String? {
            if extraArgs[i] == form, i + 1 < extraArgs.count { defer { extraArgs.remove(at: i + 1) }; return extraArgs[i + 1] }
            if extraArgs[i].hasPrefix(form + "=") { return String(extraArgs[i].dropFirst(form.count + 1)) }
            return nil
        }
        while i < extraArgs.count {
            let a = extraArgs[i]
            if a == "--persistent-cache" {
                s.persistentCache = true; extraArgs.remove(at: i)
            } else if let v = value(form: "--cache-dir") {
                s.cacheDir = v; extraArgs.remove(at: i)
            } else if let v = value(form: "--max-cache-disk") {
                s.maxCacheDisk = v; extraArgs.remove(at: i)
            } else if let v = value(form: "--max-cache-disk-writes") {
                s.maxCacheDiskWrites = v; extraArgs.remove(at: i)
            } else { i += 1 }
        }
        return s
    }

    // Tolerant decode (SplashProfile's pattern).
    enum CodingKeys: String, CodingKey {
        case modelCacheLocation, persistentCache, cacheDir, maxCacheDisk, maxCacheDiskWrites
    }
    init(from decoder: Decoder) throws { /* try? each key, defaults otherwise */ }
}
```

`SplashSettings`: add `var storage: SplashStorage?` (memberwise init param default nil, CodingKeys + `storage = try? c.decode(...)`), and replace `serveArguments`:

```swift
    /// Storage flags sit between profile flags and extraArgs (spec §3.6):
    /// per-profile extraArgs keep the last word, --port logic scans all.
    func serveArguments(port: Int, storage: SplashStorage? = nil) -> [String] {
        var args = ["serve", "--model", model]
        if let modelDir { args += ["--model-dir", modelDir] }
        if let draftModel { args += ["--draft-model", draftModel] }
        if let mmproj { args += ["--mmproj", mmproj] }
        args += storage?.launchFlags ?? []
        args += extraArgs
        if !args.contains("--port") && !args.contains(where: { $0.hasPrefix("--port=") }) {
            args += ["--port", String(port)]
        }
        return args
    }
```

`ConfigStore.applyMigrations` — append migration 8 (after the existing ones):

```swift
    // Migration 8 (spec §3.6): one-shot lift of cache flags from the ACTIVE
    // profile's extraArgs into splash.storage so the Storage UI is truthful.
    // Other profiles keep theirs (extraArgs still win per-profile).
    if config.splash?.storage == nil {
        var settings = config.splash ?? SplashSettings()
        let idx = settings.profiles.firstIndex(where: { $0.id == settings.activeProfileID })
            ?? (settings.activeProfileID == nil ? settings.profiles.indices.first : nil)
        if let idx {
            let lifted = SplashStorage.lift(from: &settings.profiles[idx].extraArgs)
            if lifted.persistentCache || lifted.cacheDir != nil
                || lifted.maxCacheDisk != nil || lifted.maxCacheDiskWrites != nil {
                settings.storage = lifted
                config.splash = settings
            }
        }
    }
```

`SplashManager.beginStart` — after `p.arguments = …`, fix the call site to `profile.serveArguments(port: settings?.port ?? 8123, storage: settings?.storage)` and add:

```swift
            if let env = settings?.storage?.environment {
                p.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
            }
```

- [ ] **Step 4: Run full suite** → green (existing serveArguments callers compile via the defaulted param).
- [ ] **Step 5: Commit** `feat(splash): storage settings emit serve flags + HF env, migrate extraArgs`

---

### Task 5: UpdateSettings + UpdateCenter (checks, alert state, dismissal)

**Goal:** The observable update-check service: per-chip splash check (release.json → `--version` fallback vs repo latest), ZGate triple compare vs the public repo, launch/daily cadence, per-tag dismissal that expires on a newer tag; plus the fork-patch fix to `SplashVersion` (Review Focus #1).

**Files:**
- Create: `ModelProxy/Models/UpdateSettings.swift`
- Create: `ModelProxy/Services/UpdateCenter.swift`
- Modify: `ModelProxy/Services/SplashInstaller.swift` (`SplashVersion` :34-54 gains suffix-aware parse + `parseTag`)
- Test: `ModelProxyTests/UpdateCenterTests.swift` (new) + ordering cases in `ModelProxyTests/SplashInstallerTests.swift`

**Acceptance Criteria:**
- [ ] `SplashVersion.parse("Splash 1.6.1-m1.1")` → `[1,6,1,1]`; `parse("Splash 1.6.1")` → `[1,6,1]`; ordering `1.6.1-m1 < 1.6.1-m1.1 < 1.6.2-m1`; `parseTag("1.7.0")` works on bare tags.
- [ ] Splash states: `unknown / notInstalled / upToDate(installed) / available(installed?, latest) / failed(reason)`; ZGate states: `unknown / upToDate / available(tag, current) / cannotCheck / failed(reason)`.
- [ ] Installed version: fork `release.json` at `<Splash-M1>/current/release.json` (no process); else walk-up from the resolved binary (≤4 parents, symlink-resolved); else `<binary> --version` output token.
- [ ] Cadence: check at start when `lastCheckAt` is nil or > 6 h old; 24 h repeat timer; `checkNow()` manual; every failure → non-alerting state.
- [ ] `hasActiveAlert` false while the available tag equals the dismissed tag; true again for a different (newer) tag; `lastSplashTag`/`lastZGateTag`/`lastCheckAt` persist through the config-write seam.
- [ ] ZGate check decodes tag + `ZGate-<tag>.zip` asset digest; 404/fetch-failure → `cannotCheck`.
- [ ] Full suite green.

**Verify:** `xcodebuild test … -only-testing:ZGateTests/UpdateCenterTests -only-testing:ZGateTests/SplashInstallerTests` → pass.

**Steps:**

- [ ] **Step 1: Failing tests.** `SplashVersion` additions (in `SplashInstallerTests.swift`):

```swift
    @Test func forkPatchOrders() {
        #expect(SplashVersion.isOlder(SplashVersion.parse("Splash 1.6.1-m1")!, than: SplashVersion.parse("Splash 1.6.1-m1.1")!))
        #expect(SplashVersion.isOlder(SplashVersion.parse("Splash 1.6.1-m1.1")!, than: SplashVersion.parse("Splash 1.6.2-m1")!))
        #expect(!SplashVersion.isOlder(SplashVersion.parse("Splash 1.6.1-m1.1")!, than: SplashVersion.parse("Splash 1.6.1-m1")!))
        #expect(SplashVersion.parse("Splash 1.6.1")! == [1, 6, 1])
        #expect(SplashVersion.parseTag("1.7.0") == [1, 7, 0])
    }
```

`UpdateCenterTests.swift` — seam-driven; fetch stubs serve fixture JSON per URL; clock is a mutable `now` box:

```swift
@Suite struct UpdateCenterTests {
    // fixtures: forkLatest(tag:), zgateLatest(tag:) JSON builders;
    // virtual clock; config dict written through a captured closure.
    @Test func forkUpdateAvailableFromTags() { /* installed release.json 1.6.1-m1.1, latest 1.7.0-m1 → .available */ }
    @Test func upToDateWhenTagsEqual() { /* … */ }
    @Test func notInstalledWhenNoBinaryAndNoReleaseJSON() { /* … */ }
    @Test func fetchFailureNeverAlerts() { /* fetch throws → splashState .unknown, zgateState .cannotCheck, hasActiveAlert false */ }
    @Test func dismissedTagSuppressesUntilNewer() { /* dismiss latest → alert off; serve newer latest → alert on */ }
    @Test func zgateTripleCompare() { /* current (2,8,9): latest v2.8.9 → upToDate; v2.9.0 → available */ }
    @Test func zgateAssetWithoutDigestCannotCheck() { /* asset lacks digest field → .cannotCheck */ }
    @Test func cadenceGatesLaunchCheck() { /* lastCheckAt 1 h ago + shouldCheck → false; 7 h ago → true */ }
    @Test func persistedFieldsWritten() { /* lastSplashTag/lastZGateTag/lastCheckAt reach the config seam */ }
}
```

- [ ] **Step 2: Run** → fails.

- [ ] **Step 3: Implement.**

`UpdateSettings.swift`:

```swift
import Foundation

/// Update-check preferences + last-seen state (spec §4). Tolerant decode.
struct UpdateSettings: Codable, Equatable, Sendable {
    var autoCheck: Bool = true
    var splashAutoApply: Bool = true
    var lastSplashTag: String?
    var lastZGateTag: String?
    var lastCheckAt: Date?
    var dismissedSplashTag: String?
    var dismissedZGateTag: String?
    init(/* defaults */) {}
    enum CodingKeys: String, CodingKey {
        case autoCheck, splashAutoApply, lastSplashTag, lastZGateTag, lastCheckAt, dismissedSplashTag, dismissedZGateTag
    }
    init(from decoder: Decoder) throws { /* try? + defaults */ }
}
```

`SplashVersion` (replace `parse`, keep `isOlder` as-is — lexicographic already handles the longer array):

```swift
    /// `Splash 1.6.1-m1.1` → [1, 6, 1, 1]: numeric core plus the fork patch
    /// as a 4th component (spec Review Focus #1 — 1.6.1-m1 < 1.6.1-m1.1).
    /// `-m1` alone contributes nothing (1.6.1-m1 == [1, 6, 1]).
    static func parse(_ output: String) -> [Int]? {
        let tokens = output.split(whereSeparator: { $0.isWhitespace })
        guard let idx = tokens.firstIndex(of: "Splash"), idx + 1 < tokens.count else { return nil }
        var parts = tokens[idx + 1].split(separator: "-").first?
            .split(separator: ".").compactMap { Int($0) } ?? []
        guard !parts.isEmpty else { return nil }
        if let patch = tokens[idx + 1].split(separator: "-").dropFirst()
            .first?.split(separator: ".").last.flatMap({ Int($0) }), patch > 0 {
            parts.append(patch)
        }
        return parts
    }

    /// Bare tag form: parseTag("1.6.1-m1.1") == parse("Splash 1.6.1-m1.1").
    static func parseTag(_ tag: String) -> [Int]? { parse("Splash " + tag) }
```

`UpdateCenter.swift` (core shape; `applySplashUpdate` arrives in Task 6):

```swift
import Foundation
import Observation

enum UpdateCadence {
    static let minLaunchInterval: TimeInterval = 6 * 3600
    static let repeatInterval: TimeInterval = 24 * 3600
    static func shouldCheck(lastCheckAt: Date?, now: Date) -> Bool {
        guard let last = lastCheckAt else { return true }
        return now.timeIntervalSince(last) >= minLaunchInterval
    }
}

enum ZGateVersion {
    /// "v2.8.9" → (2, 8, 9); nil when unparseable.
    static func parse(tag: String) -> (Int, Int, Int)? {
        let parts = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let n = parts.split(separator: ".").compactMap { Int($0) }
        return n.count == 3 ? (n[0], n[1], n[2]) : nil
    }
    static func isNewer(_ tag: (Int, Int, Int), than current: (Int, Int, Int)) -> Bool {
        tag.0 > current.0 || (tag.0 == current.0 && (tag.1 > current.1 || (tag.1 == current.1 && tag.2 > current.2)))
    }
}

struct ZGateReleaseAsset: Decodable, Sendable {
    let name: String
    let browser_download_url: URL
    let digest: String?
}
struct ZGateRelease: Decodable, Sendable {
    let tag_name: String
    let assets: [ZGateReleaseAsset]
    var zipAsset: ZGateReleaseAsset? {
        assets.first { $0.name == "ZGate-\(tag_name).zip" && $0.digest?.hasPrefix("sha256:") == true }
    }
}

@MainActor @Observable
final class UpdateCenter {
    enum SplashUpdateState: Equatable { case unknown, notInstalled, upToDate(installed: String), available(installed: String?, latest: String), failed(String) }
    enum ZGateUpdateState: Equatable { case unknown, upToDate, available(tag: String, current: String), cannotCheck, failed(String) }

    private(set) var splashState: SplashUpdateState = .unknown
    private(set) var zgateState: ZGateUpdateState = .unknown

    var hasActiveAlert: Bool { splashAlert || zgateAlert }
    var splashAlert: Bool {
        if case .available(_, let latest) = splashState { return latest != settings.dismissedSplashTag }
        return false
    }
    var zgateAlert: Bool {
        if case .available(let tag, _) = zgateState { return tag != settings.dismissedZGateTag }
        return false
    }

    struct Deps: Sendable {
        var fetch: @Sendable (URL) async throws -> Data
        var now: @Sendable () -> Date
        var sleep: @Sendable (TimeInterval) async throws -> Void
        var installedSplashVersion: @Sendable (_ chip: SplashChip?) async -> String?
        var currentZGateVersion: @Sendable () -> (Int, Int, Int)
    }

    private var settings = UpdateSettings()
    private var configWrite: ((inout UpdateSettings) -> Void)?
    private var deps: Deps
    private var repeatTask: Task<Void, Never>?

    func attach(configLoad: @escaping () -> UpdateSettings?,
                configWrite: @escaping ((inout UpdateSettings) -> Void)) { /* store */ }

    func start(splashChecksEnabled: Bool) async {  // launch entry: gate + timer
        if UpdateCadence.shouldCheck(lastCheckAt: settings.lastCheckAt, now: deps.now()) {
            await checkNow(splash: splashChecksEnabled)
        }
        repeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await deps.sleep(UpdateCadence.repeatInterval)
                await self?.checkNow(splash: splashChecksEnabled)
            }
        }
    }

    func checkNow(splash: Bool = true) async { /* per spec §3.4: splash release.json/--version vs latestRelease(for: chip); zgate fetch; nil-on-failure; persist */ }

    func dismissSplash(tag: String) { settings.dismissedSplashTag = tag; persist() }
    func dismissZGate(tag: String) { settings.dismissedZGateTag = tag; persist() }
}
```

Installed-version reader (file `UpdateCenter.swift` or `SplashInstaller.swift` — put beside `installedVersion`):

```swift
enum SplashInstalledVersionReader {
    struct Response: Decodable { let version: String }
    /// release.json without spawning: fork root first, then a symlink-
    /// resolved walk-up from the binary (brew Cellar package root).
    static func releaseJSONVersion(forkRoot: URL, binaryPath: String?) -> String? {
        let fm = FileManager.default
        let candidates: [URL] = [forkRoot.appendingPathComponent("current/release.json")]
            + binaryPath.map { bp -> [URL] in
                let resolved = URL(fileURLWithPath: bp).resolvingSymlinksInPath()
                return (0...4).map { resolved.deletingLastPathComponent(i) }
            }.map { Array($0.reversed()) }.flatMap { $0 }
        // (walk from the package root downward: parents first)
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let v = try? JSONDecoder().decode(Response.self, from: data).version else { continue }
            return v
        }
        return nil
    }
}
```

(`deletingLastPathComponent(i)` — write it as a small loop if the `i` overload isn't available; the point is ≤4 parent hops, parents checked before deeper dirs.)

Default deps in production wiring (Task 8): fetch = URLSession, `installedSplashVersion` = releaseJSON → `SplashInstaller.installedVersion(binaryPath:)`, `currentZGateVersion` = read `CFBundleShortVersionString`/`CFBundleVersion` from `Bundle.main` and `ZGateVersion.parse`. `AppConfig` gains `var update: UpdateSettings?` (tolerant decode, one line like `splash`).

- [ ] **Step 4: Run full suite** → green.
- [ ] **Step 5: Commit** `feat(update): UpdateCenter checks, alert state, per-tag dismissal`

---

### Task 6: Splash auto-apply (when stopped / next start) + manager hooks

**Goal:** The apply side of locked decision 2: tarball (fork) or brew (official) install driven by UpdateCenter through two `SplashManager` hooks, one-at-a-time guarded, post-apply version-verified, crash-relaunch never blocked (spec §3.4).

**Files:**
- Modify: `ModelProxy/Services/UpdateCenter.swift` (`applySplashUpdate`, `attach(to:)`, pending logic)
- Modify: `ModelProxy/Services/SplashManager.swift` (`start(profile:applyPendingUpdate:)` :213, gate at top; `ownedStoppedHook` fire in `stop()` :221-229)
- Modify: `ModelProxy/Services/SplashInstaller.swift` (move the brew runner here as `static func runBrew(argv:)` seam home; `SplashTabModel.runBrew` default delegates to it)
- Test: `ModelProxyTests/UpdateCenterApplyTests.swift` (new)

**Acceptance Criteria:**
- [ ] `preStartUpdateGate` is awaited at the top of `start(profile:applyPendingUpdate: true)`; `handleChildExit`'s relaunch passes `false` (a down splash never waits on a download).
- [ ] `ownedStoppedHook` fires (fire-and-forget Task) when a deliberate `stop()` lands an owned child in `.stopped`.
- [ ] Auto-apply matrix: stopped + available + `splashAutoApply` → apply once; running owned → deferred (`pendingApply`), applied on the stop hook or next start-gate; running adopted → never.
- [ ] Second `applySplashUpdate()` while one is in flight is a no-op; post-apply re-read must answer the new tag, else `.failed` and alert cleared to non-misleading state.
- [ ] macOS gate: below 26.4 → apply refuses with `.failed` (never downloads).
- [ ] Full suite green.

**Verify:** `xcodebuild test … -only-testing:ZGateTests/UpdateCenterApplyTests -only-testing:ZGateTests/SplashManagerTests` → pass.

**Steps:**

- [ ] **Step 1: Failing tests** — a recording installer seam (`applyFork: @Sendable (SplashRelease) async throws -> String`, `applyBrew: @Sendable ([String]) async throws -> Void`) injected into UpdateCenter.Deps; a real SplashManager with stub binary/probe for hook tests:

```swift
@Suite struct UpdateCenterApplyTests {
    @Test func stoppedAndAutoApplyAppliesImmediately() async { /* available + manager.state == .stopped → applyFork called once with the latest release; states refresh after */ }
    @Test func runningOwnedDefersUntilStopHook() async { /* running(adopted: false) → no apply; fire ownedStoppedHook → apply */ }
    @Test func runningAdoptedNeverApplies() { /* running(adopted: true) + hook → still no apply */ }
    @Test func verifyMismatchFails() { /* applyFork returns tag but installed-version seam still answers OLD tag → .failed */ }
    @Test func concurrentApplyIsGuarded() { /* two parallel applySplashUpdate → seam called once */ }
    @Test func macOSSuppressedRefuses() { /* inject osVersion 15.7 → .failed, no seam call */ }
}
// SplashManagerTests additions:
//   start awaits preStartUpdateGate when applyPendingUpdate (recording gate, order asserted before spawn)
//   relaunch after crash (handleChildExit path) does NOT call the gate
//   deliberate stop fires ownedStoppedHook exactly once; adopted stop never does
```

- [ ] **Step 2: Run** → fails.

- [ ] **Step 3: Implement.** Manager hooks:

```swift
    /// Awaited before spawning when a start may apply a pending splash
    /// update (spec §3.4). Crash relaunch passes applyPendingUpdate: false.
    var preStartUpdateGate: (@MainActor () async -> Bool)?
    /// Fired (fire-and-forget) after a DELIBERATE stop() lands an owned
    /// child in .stopped — UpdateCenter applies a pending update here.
    var ownedStoppedHook: (@MainActor () -> Void)?
```

`start(profile:)` becomes:

```swift
    func start(profile: SplashProfile, applyPendingUpdate: Bool = true) async {
        if applyPendingUpdate, let gate = preStartUpdateGate {
            _ = await gate()
        }
        await stopChildIfAny()
        beginStart(profile: profile)
        if let readinessTask { await readinessTask.value }
    }
```

`handleChildExit`'s relaunch tail becomes `await start(profile: next, applyPendingUpdate: false)`. In `stop()`, after `if child == nil { state = .stopped }`:

```swift
        if case .stopped = state, let hook = ownedStoppedHook {
            Task { @MainActor in hook() }   // fire-and-forget: stop() returns now
        }
```

UpdateCenter additions:

```swift
    private var applying = false
    private var pendingApply = false

    func attach(to manager: SplashManager) {
        manager.preStartUpdateGate = { [weak self] in
            guard let self, self.pendingApply else { return true }
            await self.applySplashUpdate()
            return true   // proceed with start whatever happened
        }
        manager.ownedStoppedHook = { [weak self] in
            guard let self else { return }
            Task { await self.evaluateAutoApply() }
        }
    }

    /// After every check + on the stop hook (spec §3.4 decision 2).
    func evaluateAutoApply() async {
        guard case .available = splashState, settings.splashAutoApply else { return }
        if manager?.state == .stopped { await applySplashUpdate() }
        else if case .running(_, _, false) = manager?.state { pendingApply = true }
        // adopted/external → banner only, never touched
    }

    func applySplashUpdate() async {
        guard !applying, case .available(_, let latest) = splashState else { return }
        guard SplashChip.macOSSupportsSplash(ProcessInfo.processInfo.operatingSystemVersion) else {
            splashState = .failed("needs macOS 26.4+"); return
        }
        applying = true; pendingApply = false; defer { applying = false }
        switch SplashTabModel.installVariant(chipKind: chip) {
        case .fork:
            guard let release = await installerDeps.latestRelease else { splashState = .failed("release unavailable"); return }
            do { _ = try await deps.applyFork(release) }
            catch { splashState = .failed(String(describing: error)); return }
        case .brewOfficial:
            do { try await deps.applyBrew(SplashInstaller.brewArguments(installed: true)) }
            catch { splashState = .failed(String(describing: error)); return }
        }
        // Post-apply verify (spec §3.4): the new version must answer.
        if await deps.installedSplashVersion(chip) != latest {
            splashState = .failed("verify: still \(await deps.installedSplashVersion(chip) ?? "?")")
            return
        }
        await checkNow()
    }
```

Default production deps: `applyFork` = `SplashTarballInstaller().install(release:)`, `applyBrew` = `SplashInstaller.runBrew(argv:)` (moved from `SplashTabModel.runBrewProcess` — keep the view-model seam delegating so its tests keep passing). `checkNow()` ends with `await evaluateAutoApply()` and `attach(to:)` stores a weak manager reference.

- [ ] **Step 4: Run full suite** → green.
- [ ] **Step 5: Commit** `feat(update): splash auto-apply when stopped via manager hooks`

---

### Task 7: AppUpdateService (ZGate self-update: check, stage, swap)

**Goal:** The explicit-click self-updater: anonymous check against the now-public repo, SHA-256 + TeamID verified staging, swap delegated to the bundled `release-swap.sh` spawned detached (spec §3.5).

**Files:**
- Create: `ModelProxy/Services/AppUpdateService.swift`
- Modify: `ZGate.xcodeproj/project.pbxproj` (bundle `scripts/release-swap.sh` as an app resource)
- Modify: `ModelProxy/Services/UpdateCenter.swift` (delegate the ZGate check to this service — one fetcher, no duplication)
- Test: `ModelProxyTests/AppUpdateServiceTests.swift` (new)

**Acceptance Criteria:**
- [ ] `latestRelease()` decodes tag + `ZGate-<tag>.zip` with `sha256:` digest; any failure → `cannotCheck`-equivalent (nil), never a crash.
- [ ] `stage(release:)`: download → digest verify (mismatch throws) → ≥500 MB free on the target volume → `ditto -x -k` into `<appSupport>/updates/<tag>/` → staged `ZGate.app` exists → staged TeamID equals the running app's (else throws).
- [ ] `swap(staged:)`: only when `Bundle.main.bundleURL.path == "/Applications/ZGate.app"`; runs `/bin/zsh <bundled release-swap.sh> <staged>` DETACHED (not awaited); missing script → thrown error the UI can show.
- [ ] Tests NEVER execute the real script — the script path is an injected seam recording argv (verify step runs the REAL script with `--dry-run` once, manually, in Task 12).
- [ ] A Debug build contains `ZGate.app/Contents/Resources/release-swap.sh`.
- [ ] Full suite green.

**Verify:** `xcodebuild test … -only-testing:ZGateTests/AppUpdateServiceTests` → pass; and after a Debug build: `ls "$(xcodebuild -project ZGate.xcodeproj -scheme ZGate -configuration Debug -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR =/{print $3; exit}')/ZGate.app/Contents/Resources/release-swap.sh"` → path exists.

**Steps:**

- [ ] **Step 1: Failing test**:

```swift
@Suite struct AppUpdateServiceTests {
    // fixture builders: zgateRelease(tag:d:) JSON; a real zip made in-test
    // via /usr/bin/ditto -c -k --keepParent on a temp dir containing
    // ZGate.app/Contents/Info.plist stub; digest = SHA256Hex.of(zipData).
    @Test func tagParseAndCompare() {
        #expect(ZGateVersion.parse(tag: "v2.8.9")! == (2, 8, 9))
        #expect(ZGateVersion.parse(tag: "2.8.9")! == (2, 8, 9))
        #expect(ZGateVersion.parse(tag: "junk") == nil)
        #expect(ZGateVersion.isNewer((2, 9, 0), than: (2, 8, 9)))
        #expect(!ZGateVersion.isNewer((2, 8, 9), than: (2, 8, 9)))
    }
    @Test func digestMismatchAbortsStaging() { /* serve wrong digest → stage throws, updates dir has no staged app */ }
    @Test func stagingUnpacksAndVerifiesTeamID() { /* capture stub returns same TeamIdentifier for both → staged app exists */ }
    @Test func teamIDMismatchThrows() { /* staged "TEAM=B" vs current "TEAM=A" → throws */ }
    @Test func swapRefusesNonApplicationsInstall() { /* current bundle path seam → /Volumes/… → throws notProdInstall */ }
    @Test func swapInvokesScriptDetachedWithStagedPath() { /* script-path seam records argv; Process is /bin/zsh, args = [script, stagedPath]; service returns without awaiting completion */ }
    @Test func missingDigestCannotStage() { /* asset without digest → latestRelease filters it out */ }
}
```

- [ ] **Step 2: Run** → fails.

- [ ] **Step 3: Implement.** `AppUpdateService.swift`:

```swift
import CryptoKit
import Foundation
import Observation

@MainActor @Observable
final class AppUpdateService {
    enum StageError: Error, Equatable {
        case notProdInstall, missingScript, checksumMismatch, teamMismatch(String), staging(String)
    }

    static let releasesURL = URL(
        string: "https://api.github.com/repos/froggeric/zgate/releases/latest")!
    static let prodAppPath = "/Applications/ZGate.app"

    struct Deps: Sendable {
        var fetch: @Sendable (URL) async throws -> Data = { url in
            let (d, _) = try await URLSession.shared.data(from: url); return d
        }
        var runCapture: @Sendable ([String]) async throws -> String   // codesign etc.
        var currentBundlePath: @Sendable () -> String = { Bundle.main.bundleURL.path }
        var currentVersion: @Sendable () -> (Int, Int, Int)
        var scriptPath: @Sendable () -> URL?
    }

    var deps: Deps

    /// nil on ANY failure (spec §3.5: honest degrade, no alert).
    func latestRelease() async -> ZGateRelease? {
        guard let data = try? await deps.fetch(Self.releasesURL),
              let rel = try? JSONDecoder().decode(ZGateRelease.self, from: data),
              rel.zipAsset != nil else { return nil }
        return rel
    }

    /// Download → verify → unpack → TeamID check. Returns the staged app URL.
    func stage(_ release: ZGateRelease) async throws -> URL {
        guard let asset = release.zipAsset,
              let hex = asset.digest?.dropFirst("sha256:".count) else { throw StageError.staging("digest") }
        let zip = try await deps.fetch(asset.browser_download_url)
        guard SHA256Hex.of(zip) == String(hex) else { throw StageError.checksumMismatch }
        let updates = AppPaths.appSupport.appendingPathComponent("updates", isDirectory: true)
        // ≥ 500 MB free on the app-support volume (spec §3.5).
        if let values = try? updates.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           values.volumeAvailableCapacityForImportantUsage ?? 0 < 500_000_000 {
            throw StageError.staging("low disk")
        }
        let dir = updates.appendingPathComponent(release.tag_name, isDirectory: true)
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmpZip = updates.appendingPathComponent("dl-\(UUID().uuidString).zip")
        defer { try? fm.removeItem(at: tmpZip) }
        try zip.write(to: tmpZip)
        try await deps.runCapture(["/usr/bin/ditto", "-x", "-k", tmpZip.path, dir.path])
        let staged = dir.appendingPathComponent("ZGate.app")
        guard fm.fileExists(atPath: staged.path) else { throw StageError.staging("no app in zip") }
        // Belt-and-braces identity check beside the sha256 (spec §3.5).
        func teamID(_ url: URL) -> String? {
            try? deps.runCaptureSyncHint(["/usr/bin/codesign", "-dv", url.path])
        }
        // (run codesign via runCapture for both staged and current; parse
        //  TeamIdentifier=(X); unequal → throw .teamMismatch)
        return staged
    }

    /// Spawns the bundled release-swap.sh DETACHED and returns: the script
    /// SIGTERMs this app (its own parent — it is built to outlive it,
    /// scripts/release-swap.sh header). NEVER awaited.
    func swap(staged: URL) async throws {
        guard deps.currentBundlePath() == Self.prodAppPath else { throw StageError.notProdInstall }
        guard let script = deps.scriptPath() else { throw StageError.missingScript }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [script.path, staged.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run()   // fire — the app dies mid-script by design
    }

    /// UpdateCenter-facing check: pure state from latestRelease + version.
    func checkState(current: (Int, Int, Int)) async -> UpdateCenter.ZGateUpdateState {
        guard let rel = await latestRelease(), let tag = ZGateVersion.parse(tag: rel.tag_name) else {
            return .cannotCheck
        }
        if ZGateVersion.isNewer(tag, than: current) {
            return .available(tag: rel.tag_name, current: "\(current.0).\(current.1).\(current.2)")
        }
        return .upToDate
    }
}
```

Resolve the `runCapture` sync/async wrinkle cleanly: make `runCapture` `async` and `await` it twice in `stage` (staged + current bundle TeamID). Default `scriptPath` = `Bundle.main.url(forResource: "release-swap", withExtension: "sh")`. `UpdateCenter.checkNow`'s ZGate half delegates to `appUpdate.checkState(current:)` (inject the service in `attach`).

- [ ] **Step 4: pbxproj resource wiring.** In `ZGate.xcodeproj/project.pbxproj`:
  1. **PBXFileReference section**: add `release-swap.sh /* release-swap.sh */ = {isa = PBXFileReference; lastKnownFileType = text.script.zsh; path = release-swap.sh; sourceTree = "<group>"; };` inside a new group `scripts /* scripts */ = {isa = PBXGroup; children = (…file ref…); path = scripts; sourceTree = "<group>"; };` added to the MAIN group's children (the main group's `path` resolves to the repo root — verify by checking the existing main group block; `ModelProxy` is referenced with `path = ModelProxy` the same way).
  2. **PBXBuildFile section**: `release-swap.sh in Resources /* … */ = {isa = PBXBuildFile; fileRef = release-swap.sh /* release-swap.sh */; };` (generate fresh 24-hex ids unique in the file).
  3. **App target's PBXResourcesBuildPhase**: add the build file to `files = (…)`.
  Then build and run the Verify `ls` — the script must appear in `Contents/Resources`. If the synchronized-groups setup rejects a sibling group, fall back: PBXBuildFile with `fileRef` pointing directly at the file reference (no group needed for resources).

- [ ] **Step 5: Run full suite + Verify ls** → green + file present.
- [ ] **Step 6: Commit** `feat(update): ZGate self-update staging + bundled release-swap invocation`

---

### Task 8: Menu-bar badge, popover banners, app wiring

**Goal:** The visible alert layer: template-safe badge dot on the quota ring (faults still replace the whole icon and outrank it), per-target popover banners with Install/Update + dismiss, UpdateCenter/AppUpdateService wired into the app (spec §5).

**Files:**
- Modify: `ModelProxy/Views/QuotaMenuBarIcon.swift` (badge param + `QuotaRingSpec` constants :16-70, draw :82-163)
- Modify: `ModelProxy/App/ModelProxyApp.swift` (create/inject/start services :41-52, :56-82; `MenuBarLabel` :93-123)
- Modify: `ModelProxy/Views/StatusPopover.swift` (update banner section near :108-152)
- Test: `ModelProxyTests/UpdateAlertUITests.swift` (new)

**Acceptance Criteria:**
- [ ] `QuotaMenuBarIcon.image(weeklyFraction:stale:updateAvailable:)` — badge only on the healthy ring (nil-symbol) state; images differ pixel-wise when the flag flips; still `isTemplate`, black+alpha only.
- [ ] `MenuBarLabel` takes the UpdateCenter and passes `hasActiveAlert`; accessibility text appends "update available".
- [ ] App launch: UpdateCenter started (ZGate check always; splash checks + `attach(to: splashManager)` behind `shouldSupervise`), injected into both scenes' environments.
- [ ] Popover: ZGate banner ("Install…" → confirmation dialog noting the proxy goes down briefly → `stage` + `swap`; non-/Applications installs show "View…" → Releases URL), splash banner ("Update" → `applySplashUpdate()`, disabled while applying); each banner has a dismiss (×) writing the dismissed tag.
- [ ] Full suite green.

**Verify:** `xcodebuild test … -only-testing:ZGateTests/UpdateAlertUITests` → pass.

**Steps:**

- [ ] **Step 1: Failing tests**:

```swift
@Suite struct UpdateAlertUITests {
    @Test func badgeChangesPixels() {
        let a = QuotaMenuBarIcon.image(weeklyFraction: 0.5, stale: false, updateAvailable: false)
        let b = QuotaMenuBarIcon.image(weeklyFraction: 0.5, stale: false, updateAvailable: true)
        #expect(a.isTemplate && b.isTemplate)
        #expect(a.tiffRepresentation != b.tiffRepresentation)
        let c = QuotaMenuBarIcon.image(weeklyFraction: nil, stale: false, updateAvailable: true)
        #expect(c.tiffRepresentation != a.tiffRepresentation)   // no-data ring also badged
    }
    @Test func badgeConstantsStayTemplateSafe() {
        #expect(QuotaRingSpec.badgeAlpha > 0 && QuotaRingSpec.badgeAlpha <= 1)
        #expect(QuotaRingSpec.badgeRadius + QuotaRingSpec.badgeOffset <= QuotaRingSpec.canvas)
    }
    @Test func accessibilityMentionsUpdate() {
        #expect(MenuBarLabel.accessibilityText(
            running: true, quotaPercent: "42%", updateAvailable: true)
            .contains("update available"))
        #expect(!MenuBarLabel.accessibilityText(
            running: true, quotaPercent: "42%", updateAvailable: false)
            .contains("update available"))
    }
}
```

- [ ] **Step 2: Run** → fails.

- [ ] **Step 3: Implement.** `QuotaRingSpec` additions:

```swift
    // Update badge (spec §5): filled dot at the top-right of the ring.
    static let badgeRadius: CGFloat = 2.1
    static let badgeOffset: CGFloat = 3.4   // center offset toward the corner
    static let badgeAlpha: CGFloat = 0.95
```

In `image(…)` (add the param with default `false` so existing callers compile), after `drawMark`:

```swift
        if updateAvailable {
            let center = NSPoint(
                x: rect.midX + QuotaRingSpec.badgeOffset,
                y: rect.midY + QuotaRingSpec.badgeOffset)
            NSColor.black.withAlphaComponent(QuotaRingSpec.badgeAlpha).setFill()
            NSBezierPath(ovalIn: NSRect(
                x: center.x - QuotaRingSpec.badgeRadius, y: center.y - QuotaRingSpec.badgeRadius,
                width: QuotaRingSpec.badgeRadius * 2, height: QuotaRingSpec.badgeRadius * 2)).fill()
        }
```

`MenuBarLabel`: add `let updateCenter: UpdateCenter`; render `QuotaMenuBarIcon.image(weeklyFraction:stale:updateAvailable: updateCenter.hasActiveAlert)`; extract `static func accessibilityText(running:quotaPercent:updateAvailable:) -> String` (pure, tested) and append `, update available` when set.

`ModelProxyApp`: create `let updateCenter = UpdateCenter()` + `let appUpdate = AppUpdateService()` at init (beside `splashManager`), inject `.environment(updateCenter)` / `.environment(appUpdate)` into both scenes, pass `updateCenter` to `MenuBarLabel`, and in the launch `Task` after the splash `configure` guard:

```swift
            updateCenter.attach(
                configLoad: { [weak configStore] in configStore?.config.update },
                configWrite: { [weak configStore] mutate in
                    guard let configStore else { return }
                    var u = configStore.config.update ?? UpdateSettings()
                    mutate(&u)
                    configStore.config.update = u
                    configStore.save()
                },
                appUpdate: appUpdate)
            if SplashManager.shouldSupervise(environment: ProcessInfo.processInfo.environment) {
                updateCenter.attach(to: splashManager)
            }
            await updateCenter.start(splashChecksEnabled: SplashManager.shouldSupervise(environment: ProcessInfo.processInfo.environment))
```

`StatusPopover`: `@Environment(UpdateCenter.self)`, `@Environment(AppUpdateService.self)`; a new `updateBannerSection` ABOVE `bannerSection`:

```swift
    @ViewBuilder private var updateBannerSection: some View {
        if updateCenter.zgateAlert, case .available(let tag, _) = updateCenter.zgateState {
            actionBanner(
                icon: "arrow.down.circle.fill", tint: .orange,
                text: "ZGate \(tag) available",
                primaryTitle: prodInstall ? "Install…" : "View…",
                primary: { prodInstall ? confirmZGateInstall(tag: tag) : openReleases() },
                dismiss: { updateCenter.dismissZGate(tag: tag) })
        }
        if updateCenter.splashAlert, case .available(let installed, let latest) = updateCenter.splashState {
            actionBanner(
                icon: "arrow.down.circle.fill", tint: .orange,
                text: "splash \(latest) available\(installed.map { " · \($0) installed" } ?? "")",
                primaryTitle: "Update",
                primary: { Task { await updateCenter.applySplashUpdate() } },
                dismiss: { updateCenter.dismissSplash(tag: latest) })
        }
    }
```

`actionBanner` extends the existing `banner` with a trailing primary `Button` (`.buttonStyle(.link)`) and an `×` dismiss button; `confirmZGateInstall` presents a `.confirmationDialog("ZGate will quit and restart — the proxy is down for a few seconds. Continue?")` whose confirm runs `stage` → `swap` with a transient "Restarting…" state; failures surface the error string in the banner line. `openReleases` = `NSWorkspace.shared.open(URL(string: "https://github.com/froggeric/zgate/releases")!)`.

- [ ] **Step 4: Run full suite** → green.
- [ ] **Step 5: Commit** `feat(ui): update badge on menu-bar ring + popover update banners`

---

### Task 9: Splash tab install row upgrade + macOS gate

**Goal:** The install row tells the truth per chip (repo, real update verdict via `isOlder`, macOS gate) and its buttons drive the managed paths (spec §5).

**Files:**
- Modify: `ModelProxy/Views/SplashTabView.swift` (`installSection` :347-358, `refreshInstallLine` :364-378, `runInstall` :390-427, `SplashTabModel.installLine` :135-140)
- Test: `ModelProxyTests/SplashTabModelTests.swift` (additions)

**Acceptance Criteria:**
- [ ] Row shows: `<brand> · <fork|official> · <repo slug> · <installed token> installed · <latest> available` and appends `· update available` when `isOlder(installed, latest)`.
- [ ] Below macOS 26.4: row explains `splash needs macOS 26.4+ (this Mac: <os>)` and the button is disabled.
- [ ] Button label `Install` when no binary answers, else `Update`; per-chip latest check (`latestRelease(for: chipKind)`); fork branch = tarball installer (Task 3), official = brew (unchanged).
- [ ] Pure derivations `installButtonState` and the extended `installLine` unit-tested; full suite green.

**Verify:** `xcodebuild test … -only-testing:ZGateTests/SplashTabModelTests` → pass.

**Steps:**

- [ ] **Step 1: Failing tests** (in `SplashTabModelTests.swift`):

```swift
    @Test func installLineIncludesRepoAndVerdict() {
        #expect(SplashTabModel.installLine(
            chip: "Apple M2 Max", variant: "fork", repo: "paperniuk/splash",
            installed: "1.6.1-m1.1", latest: "1.7.0-m1") ==
            "Apple M2 Max · fork · paperniuk/splash · 1.6.1-m1.1 installed · 1.7.0-m1 available · update available")
        #expect(SplashTabModel.installLine(
            chip: "Apple M3", variant: "official", repo: "incoai/splash",
            installed: nil, latest: nil).contains("not installed"))
    }

    @Test func installButtonState() {
        let osOK = SplashChip.macOSSupportsSplash(OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 1))
        #expect(SplashTabModel.installButtonState(supportsOS: osOK, installed: nil) == (label: "Install", enabled: true))
        #expect(SplashTabModel.installButtonState(supportsOS: osOK, installed: "1.6.1-m1.1") == (label: "Update", enabled: true))
        #expect(SplashTabModel.installButtonState(supportsOS: false, installed: nil).enabled == false)
    }
```

- [ ] **Step 2: Run** → fails.
- [ ] **Step 3: Implement.** Extend `SplashTabModel.installLine(chip:variant:repo:installed:latest:)` (parse `SplashVersion.parseTag` for the verdict; keep nil-safe) and add:

```swift
    nonisolated static func installButtonState(supportsOS: Bool, installed: String?)
        -> (label: String, enabled: Bool) {
        (label: installed == nil ? "Install" : "Update", enabled: supportsOS)
    }
```

`refreshInstallLine`: use `SplashChip.current`, per-chip `latestRelease(for:)`, repo slug from `chip.repoSlug`, and `SplashVersion.parseTag` verdict. `installSection` renders the gate (`ProcessInfo.processInfo.operatingSystemVersion`), the button state, and disables while `installBusy`. `runInstall` fork branch is already the Task-3 tarball call; brew branch unchanged.

- [ ] **Step 4: Run full suite** → green.
- [ ] **Step 5: Commit** `feat(splash): truthful per-chip install row with macOS gate`

---

### Task 10: Storage section UI + /status usage + move/clear actions

**Goal:** The Storage settings surface (spec §3.6, §5): model-cache location/size/move/reveal/clear, prefix-cache persistent/dir/quota/write-budget/clear, live `/status` disk usage.

**Files:**
- Create: `ModelProxy/Services/SplashStatusClient.swift`
- Create: `ModelProxy/Services/StorageActions.swift`
- Create: `ModelProxy/Views/SplashStorageSection.swift`
- Modify: `ModelProxy/Views/SplashTabView.swift` (add `storageSection` between `profilesSection` and `installSection`)
- Test: `ModelProxyTests/SplashStatusClientTests.swift`, `ModelProxyTests/StorageActionsTests.swift` (new)

**Acceptance Criteria:**
- [ ] `/status` → `disk` decode: full fixture, minimal fixture, malformed → nil. Client nil-on-failure, injected fetch.
- [ ] `isNamespaceDir`: exactly 32 hex chars, nothing else; `clearPrefixCache(root:)` removes ONLY namespace dirs (files and other dirs survive); throws when root missing.
- [ ] `moveModelCache(from:to:)`: `ditto` copy → `du`-verified sizes within tolerance → source renamed `<src>.zgate-moved-<ts>` (timestamp injectable) → returns backup URL; failure leaves source untouched.
- [ ] UI: model-cache row (path or default, on-disk size async, volume free, Change… NSOpenPanel, Move… with stopped-guard + progress + completion "Delete old location", Reveal, Clear… destructive confirm); prefix-cache Section (persistent toggle → cache-dir picker gated on it, quota Picker Auto/Off/Custom + size field validated `^\d+(\.\d+)?[KMG]$`, write budget optional field, live usage row while running, Clear prefix cache disabled while running); footer note "Profile extraArgs may override these".
- [ ] Every change persists via the existing `saveAndApply` (non-restarting persist for storage fields; restart prompt only when running-and-owned per existing UX).
- [ ] Full suite green.

**Verify:** `xcodebuild test … -only-testing:ZGateTests/SplashStatusClientTests -only-testing:ZGateTests/StorageActionsTests` → pass.

**Steps:**

- [ ] **Step 1: Failing tests.**

```swift
@Suite struct SplashStatusClientTests {
    @Test func decodesFullDisk() throws {
        let json = #"{"disk":{"capacity_bytes":21474836480,"limit_bytes":18000000000,"used_bytes":123,"file_bytes":130,"volume_available_bytes":999,"writes_gated":"no","persistent":true,"taken_back":1}}"#
        let client = SplashStatusClient(fetch: { _ in Data(json.utf8) })
        let d = try await client.diskStatus(port: 8123).unwrap()
        #expect(d.capacityBytes == 21_474_836_480 && d.persistent == true && d.writesGated == "no")
    }
    @Test func minimalAndMalformedReturnNil() { /* {"disk":{}} → non-nil with nil fields is fine; garbage → nil */ }
}

@Suite struct StorageActionsTests {
    @Test func namespaceDirRule() {
        #expect(StorageActions.isNamespaceDir("0123456789abcdef0123456789abcdef"))
        #expect(!StorageActions.isNamespaceDir("0123456789abcdef0123456789abcde"))
        #expect(!StorageActions.isNamespaceDir("zzzz456789abcdef0123456789abcde".replacingOccurrences(of: "z", with: "f") + " extra")) // non-hex / spaces
    }
    @Test func clearRemovesOnlyNamespaces() throws {
        // tmp root with: one 32-hex dir (removed), "keep" dir (stays),
        // "notes.txt" (stays)
    }
    @Test func moveCopiesVerifiesAndBacksUp() async throws {
        // tmp src with a 1 MB file → move to tmp dst: dst has the file,
        // src renamed *.zgate-moved-*, returned backup URL matches
    }
    @Test func moveAbortsWhenTargetTooSmallOrMissing() async throws { /* throws, src untouched */ }
}
```

- [ ] **Step 2: Run** → fails.

- [ ] **Step 3: Implement.** `SplashStatusClient.swift`:

```swift
import Foundation

/// GET /status → disk object (spec §2). Tolerant: unknown keys ignored,
/// missing disk → nil.
struct SplashDiskStatus: Decodable, Equatable, Sendable {
    var capacityBytes: Int?
    var limitBytes: Int?
    var usedBytes: Int?
    var fileBytes: Int?
    var volumeAvailableBytes: Int?
    var writesGated: String?
    var persistent: Bool?
    enum CodingKeys: String, CodingKey {
        case capacityBytes = "capacity_bytes", limitBytes = "limit_bytes"
        case usedBytes = "used_bytes", fileBytes = "file_bytes"
        case volumeAvailableBytes = "volume_available_bytes"
        case writesGated, persistent
    }
    init(from decoder: Decoder) throws { /* try? each */ }
}

struct SplashStatusClient: Sendable {
    var fetch: @Sendable (URL) async throws -> Data
    private struct Envelope: Decodable { let disk: SplashDiskStatus? }
    func diskStatus(port: Int) async -> SplashDiskStatus? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/status"),
              let data = try? await fetch(url) else { return nil }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.disk
    }
    static func endpoint(port: Int) -> URL { URL(string: "http://127.0.0.1:\(port)/status")! }
}
```

`StorageActions.swift`:

```swift
import Foundation

/// Disk-side storage operations (spec §3.6). All process work through an
/// injectable runner; tests pass temp dirs.
struct StorageActions: Sendable {
    var run: @Sendable ([String]) async throws -> Void
    var capture: @Sendable ([String]) async throws -> String
    var now: @Sendable () -> Date

    static func isNamespaceDir(_ name: String) -> Bool {
        name.count == 32 && name.allSatisfy { $0.isHexDigit }
    }

    static var defaultHFCache: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/.cache/huggingface/hub", isDirectory: true)
    }

    /// Wipes ONLY 32-hex namespace dirs under the prefix-cache root — the
    /// same shape splash itself GCs (spec §2). Call with splash stopped.
    static func clearPrefixCache(root: URL) throws {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: root.path)
        for n in names where isNamespaceDir(n) {
            try fm.removeItem(at: root.appendingPathComponent(n, isDirectory: true))
        }
    }

    /// ditto copy → size verify → rename source to `<src>.zgate-moved-<ts>`
    /// (never auto-delete; the UI offers "Delete old location").
    func moveModelCache(from source: URL, to target: URL) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await run(["/usr/bin/ditto", source.path, target.path])
        let srcSize = try await capture(["/usr/bin/du", "-sk", source.path])
        let dstSize = try await capture(["/usr/bin/du", "-sk", target.path])
        func kb(_ s: String) -> Int { Int(s.split(separator: "\t").first ?? "") ?? -1 }
        guard kb(dstSize) >= kb(srcSize), kb(srcSize) > 0 else {
            throw NSError(domain: "StorageActions", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "copy verification failed"])
        }
        let ts = Int(now().timeIntervalSince1970)
        let backup = source.deletingLastPathComponent()
            .appendingPathComponent("\(source.lastPathComponent).zgate-moved-\(ts)")
        try? fm.removeItem(at: backup)
        try fm.moveItem(at: source, to: backup)
        return backup
    }
}
```

`SplashStorageSection.swift` — a `View` taking the tab model + manager (same environment pattern as the tab's other sections), implementing the AC's controls. Notable pieces: size/free rows via `.task` computing `du`/`volumeAvailableCapacity`; `NSOpenPanel(canChooseDirectories: true)` for both pickers; the Move flow gated on `manager.state == .stopped` (else a hint line); quota `Picker` with custom `TextField` + validation regex `^\d+(\.\d+)?[KMG]$` and `0` shown as Off. Persistence: mutate `model.storage…` fields → `configStore.config.splash = model.settings(); configStore.save()` (non-restarting persist, like the profile editor).

- [ ] **Step 4: Run full suite** → green.
- [ ] **Step 5: Commit** `feat(splash): storage & cache settings with move/clear and live usage`

---

### Task 11: About credits + Check for Updates + General update toggles

**Goal:** Spec §5's remaining UI: splash repo credits in About (Apache-2.0, both repos), a Check-for-Updates row, and the two update-settings toggles.

**Files:**
- Modify: `ModelProxy/Views/SettingsView.swift` (`AboutTabView` :934-989 — Credits :946-967, new Updates section)
- Modify: `ModelProxy/Views/GeneralTabView.swift` (`aboutSection` :171-193 — toggles)
- Test: existing suites stay green (static Links; state text via UpdateCenter helpers already tested in Task 5).

**Acceptance Criteria:**
- [ ] Credits section contains, following the existing two-row pattern:
  - `Splash — local inference engine by Inco (Apache-2.0)` → `https://github.com/incoai/splash`
  - `Splash M1/M2 port by paperniuk & contributors (Apache-2.0)` → `https://github.com/paperniuk/splash`
  - the existing descriptive paragraph stays.
- [ ] About "Updates" section: current state line (`up to date` / `<tag> available` / `cannot check — repo unreachable or private`), `Check Now…` button → `updateCenter.checkNow()`, `Install…` when `zgateAlert` and prod install (same confirm flow as the popover — factor the action into a shared helper or call the service directly).
- [ ] General tab: `Check for updates automatically` and `Update splash automatically when stopped` toggles bound to `configStore.config.update` (creating `UpdateSettings()` on first toggle) with `configStore.save()`.
- [ ] Full suite green.

**Verify:** `xcodebuild test -project ZGate.xcodeproj -scheme ZGate -destination 'platform=macOS'` → green.

**Steps:**

- [ ] **Step 1: Implement** the About Credits rows (replace the link-less "Splash local target" block's layout — keep its explanatory text as a third line under the two Link rows):

```swift
                VStack(alignment: .leading, spacing: 6) {
                    Text("Splash — local inference engine by Inco (Apache-2.0)")
                    if let url = URL(string: "https://github.com/incoai/splash") {
                        Link("github.com/incoai/splash", destination: url).font(.callout)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Splash M1/M2 port by paperniuk & contributors (Apache-2.0)")
                    if let url = URL(string: "https://github.com/paperniuk/splash") {
                        Link("github.com/paperniuk/splash", destination: url).font(.callout)
                    }
                }
```

- [ ] **Step 2: Updates section** in `AboutTabView` — `@Environment(UpdateCenter.self)`, `@Environment(AppUpdateService.self)`; a `row("Updates", value: stateText)` + `Check Now…` / `Install…` buttons mirroring the popover logic (shared helper `UpdateActions` or direct calls; disabled while a check/apply runs).

- [ ] **Step 3: General toggles**:

```swift
            Toggle("Check for updates automatically", isOn: Binding(
                get: { configStore.config.update?.autoCheck ?? true },
                set: { ensureUpdateSettings().autoCheck = $0; configStore.save() }))
            Toggle("Update splash automatically when stopped", isOn: Binding(
                get: { configStore.config.update?.splashAutoApply ?? true },
                set: { ensureUpdateSettings().splashAutoApply = $0; configStore.save() }))
```

with `private func ensureUpdateSettings() -> UpdateSettings { if configStore.config.update == nil { configStore.config.update = UpdateSettings() }; return configStore.config.update! }` and the autoCheck toggle also starting/stopping `updateCenter`'s timer via `updateCenter.setAutoCheck(_:)` (a small method that cancels or restarts the repeat task — UpdateCenter reads the flag each cycle anyway; simplest: timer keeps ticking but `checkNow` returns early when `autoCheck == false` EXCEPT for manual calls).

- [ ] **Step 4: Run full suite** → green.
- [ ] **Step 5: Commit** `docs+feat(ui): splash repo credits, check-for-updates, update toggles`

---

### Task 12: Integration verification + docs

**Goal:** Whole-feature verification and the project's documentation conventions.

**Files:**
- Modify: `CHANGELOG.md` (new Unreleased section)
- Create: `docs/05-features/splash-variants-updates-storage.md` (feature doc — **ask the user first** per project CLAUDE.md before writing it)

**Acceptance Criteria:**
- [ ] `xcodebuild test -project ZGate.xcodeproj -scheme ZGate -destination 'platform=macOS'` — FULL suite green.
- [ ] Debug build succeeds; `ZGate.app/Contents/Resources/release-swap.sh` exists.
- [ ] **Dry-run smoke of the real swap script against a staged dummy** (manual, safe — `--dry-run` runs steps A–B read-only): stage the CURRENT app's zip shape into a temp dir and run `zsh scripts/release-swap.sh --dry-run <staged>`; expect exit 0 with the validation plan printed. No real swap, no signals.
- [ ] Live end-to-end check (no code needed): `curl -s https://api.github.com/repos/froggeric/zgate/releases/latest` returns `v2.8.9` (the anonymous path the app uses — verified 2026-11-19; re-run to confirm).
- [ ] CHANGELOG "Unreleased" section listing: per-chip splash support + tarball installer, UpdateCenter + auto-apply, ZGate self-update, storage settings, menu-bar badge, credits, port-desync fix.
- [ ] Feature doc (after user OK): behavior, key files, config keys (`splash.storage`, `update`), how the swap works, rollback.
- [ ] Final commit(s).

**Verify:** full-suite command green + dry-run exit 0 + curl shows the tag.

**Steps:**

- [ ] **Step 1:** Run the full suite; fix anything red.
- [ ] **Step 2:** Debug build + `ls` the Resources script + the `--dry-run` smoke + the curl check.
- [ ] **Step 3:** Manual smoke checklist on this M2 Max (interactive; note results in the handoff): launch Debug build → General tab shows toggles; About shows credits + Updates row; Splash tab shows `Apple M2 Max · fork · paperniuk/splash · <installed> installed · <latest> available` (or the not-installed variant); Storage section renders with the migrated `--cache-dir /Volumes/ssd/ai/cache/splash` values from the owner's config.
- [ ] **Step 4:** CHANGELOG entry; ask the user about the feature doc; write it if approved.
- [ ] **Step 5:** Commit `chore(release-prep): changelog + feature docs for variants/updates/storage wave`.

---

## Self-Review (done at authoring time)

- **Spec coverage:** §3.1→T1/T2, §3.2→T3, §3.3→T3(brew kept)/T6, §3.4→T5/T6, §3.5→T7, §3.6→T4/T10, §4→T4/T5, §5→T8/T9/T10/T11, §6→T2/T3, §7→each task, §8→T12. Gaps: none open.
- **Type consistency:** `SplashChip.binaryName/repoSlug/releasesURL(for:)/macOSSupportsSplash`, `SplashStorage.launchFlags/environment/lift`, `UpdateCenter.SplashUpdateState/ZGateUpdateState/hasActiveAlert/splashAlert/zgateAlert/checkNow/dismissSplash(tag:)/dismissZGate(tag:)/applySplashUpdate/attach(to:)/attach(configLoad:configWrite:appUpdate:)`, `AppUpdateService.latestRelease/stage/swap/checkState`, `ZGateVersion.parse(tag:)/isNewer`, `SplashVersion.parseTag`, `StorageActions.isNamespaceDir/clearPrefixCache/moveModelCache`, `SplashStatusClient.diskStatus(port:)` — used with these exact names across tasks.
- **Placeholders:** none; every code step carries real code or a precise, named edit.
- **Review Focus:** each of the five lines maps to tests in Tasks 3, 5 (×3), 4, 5/7 as listed.


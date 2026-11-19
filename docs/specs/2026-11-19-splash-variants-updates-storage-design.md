# ZGate — Splash Variants, Update Center, Storage Management — Design

- **Date:** 2026-11-19
- **Status:** design approved in chat; spec pending user review
- **Precedes:** implementation plan (writing-plans) — no implementation before
  plan approval
- **Canonical:** this file, in the zgate repo.
- **Context docs:** `docs/specs/2026-11-16-splash-lifecycle-design.md` (the
  wave that built the splash subsystem; §3.2's fork-install mechanics are
  AMENDED by this spec — see §10), `README.md`, splash upstream docs
  (`docs/server.md` of incoai/splash, fetched 2026-11-19).

## 1. Context and problem

Three gaps in the splash subsystem, one missing subsystem, one UI debt:

1. **M3+ machines are second-class.** Chip detection exists, but binary
   resolution, the latest-version check, and install only know the fork:
   `resolvedBinaryPath` probes `splash-m1` names only (a brew-installed
   official `splash` can never be run), and the "available" tag always comes
   from `paperniuk/splash` regardless of chip.
2. **The fork install path is rotten.** Current fork releases ship
   `splash-<tag>-arm64-macos26.tar.gz` + a `.sha256` sidecar; the asset
   picker (exact `splash-m1` name, else the single non-.dmg/non-.sh asset)
   now finds two candidates → `ambiguousOrMissingAsset` → install dead.
   Even if it picked one, `installForkBinary` chmods the **tarball** as a
   binary. The single-binary-asset era it was written for is gone.
3. **No version autodetect or update mechanism** — for splash or ZGate.
   `SplashVersion.isOlder` is tested but has zero production callers; the
   installed version is only computed when the Splash tab renders; nothing
   persists it; nothing alerts.
4. **No storage management.** Splash puts 21–24 GB of model downloads in
   `~/.cache/huggingface/hub` and a prefix cache in
   `~/Library/Caches/Splash` by default; the owner already relocates both by
   hand (`--cache-dir /Volumes/ssd/ai/cache/splash --max-cache-disk 20G` in
   the seeded profile's extraArgs; draft model pinned under
   `/Volumes/ssd/ai/cache/misc/hub`). No UI exists.
5. **No credits** for the splash repos in the About page.

### Locked decisions (user, 2026-11-19)

1. **ZGate self-update: custom updater + bundled `release-swap.sh`.** No
   Sparkle, no new frameworks. Applies **only on explicit click** — never
   silently (this app proxies the session that might drive the update).
2. **Splash updates: auto-apply when stopped.** Not running → apply;
   running and owned → apply on next stop (or just before next start);
   running and adopted → banner only.
3. **Storage scope: model cache AND prefix cache.** Both become
   first-class settings with move/clear/location controls.
4. **`froggeric/zgate` goes public** so update checks need no secrets.
   Until the flip happens the ZGate check degrades to an honest "cannot
   check" state; splash checks are unaffected (both repos public).

### Non-goals

- Delta/patch updates, prerelease channels, staged rollouts.
- Managing the Splash desktop app (DMG) — CLI engine only.
- Model *download* management (weights, revisions, pruning) — splash
  downloads its own models; ZGate relocates and clears the cache, nothing
  else. `brew`-less official installs (manual tarball) are notify-only.
- Keychain migration for any credential (project convention: config.json).

## 2. Grounding facts (observed, not assumed)

Verified 2026-11-19 via GitHub API + live files; line refs are HEAD at
commit `2e31b28`.

**Repos and releases**

| | paperniuk/splash (fork) | incoai/splash (official) |
|---|---|---|
| Chips | M1/M2 (Apple7/8 GPU) only | M3+ (upstream refuses older) |
| Latest tag (2026-11-19) | `1.6.1-m1.1` | `1.7.0` |
| Version scheme | `<upstream>-m1[.N]`, tag == version string | plain `x.y.z`, tag == version |
| Engine tarball | `splash-<tag>-arm64-macos26.tar.gz` + `.sha256` sidecar (65 B hex digest) | same naming (`splash-1.7.0-arm64-macos26.tar.gz`) |
| Sanctioned update | re-run `install-m1.sh` (idempotent, SHA-256 verified, `current` symlink swap) | `brew upgrade splash` |
| License | Apache-2.0 | Apache-2.0 |
| macOS floor | 26.4 (installer enforces) | 26.4 (device check before model download) |

- **`install-m1.sh` mechanics** (read in full, mirrored by our installer):
  download tarball + `.sha256` from
  `https://github.com/paperniuk/splash/releases/download/<tag>/…`; strip
  whitespace from the sidecar, compare SHA-256; unpack with
  `tar -xzf … -C $APP/<tag>.partial --strip-components 1`; `xattr -dr
  com.apple.quarantine` (tolerant); replace `$APP/<tag>`; `ln -sfn <tag>
  $APP/current` where `$APP = ~/Library/Application Support/Splash-M1`;
  write shim `splash-m1` (contents below) into `/opt/homebrew/bin` if it
  exists and is writable, else `~/.local/bin`, chmod 0755; run
  `splash-m1 --version` as sanity.
- **Shim contents** (stable across versions — execs through `current`):
  ```sh
  #!/bin/sh
  export PYTHONDONTWRITEBYTECODE=1
  exec "$APP/current/python/bin/python3" -u "$APP/current/install/launcher.py" "$@"
  ```
- **Version reporting:** packaged installs keep `release.json`
  (`{"version": "<tag>"}`) at the install root — fork:
  `…/Splash-M1/current/release.json`; official (brew): at the Cellar
  package root (binary is a symlink into
  `/opt/homebrew/Cellar/splash/<ver>/…`). `--version` prints
  `Splash <tag>` on both; HTTP endpoints expose **no** version.
- **ZGate releases:** tag `v{marketing}.{build}` (live: `v2.8.9` = 2.8 (9)),
  asset `ZGate-<tag>.zip` with GitHub's `digest` field
  (`sha256:<hex>` — verified live). Repo currently **private** (decision 4).
- **`release-swap.sh`:** zsh; `usage: release-swap.sh [--dry-run]
  <staged-app-path> [log-file]`; self-contained foreground process, never
  reads stdin, outlives its dying parent; steps A–G = validate staged
  bundle (bundle id, codesign, versions) → identify running app by exact
  exe path + port 8787 cross-check → SIGTERM verified pid → wait port free
  → mv-backup + ditto → reopen + wait 8787 → `GET /api/hello`; rollback on
  failure; exit codes 0–7 documented in the header; logs to
  `/tmp/zgate-release-swap.log`.

**Splash server cache surface** (upstream `docs/server.md`)

- Model downloads → Hugging Face cache, default
  `~/.cache/huggingface/hub`, relocated with the `HF_HUB_CACHE` env var;
  existing downloads are **not** moved by splash (hence our Move feature);
  splash pins installed revisions under `refs/splash` inside that cache.
- Prefix/persistent cache: `--persistent-cache` + `--cache-dir` (default
  `~/Library/Caches/Splash/prefix-cache`; `--cache-dir` requires
  `--persistent-cache`); quota `--max-cache-disk` (`auto` = ¼ of volume
  free beyond a 10 GiB floor, cap 32 GiB; `0` = off; `16G` = fixed);
  daily write budget `--max-cache-disk-writes` (`0` = none). Only
  32-hex-digit namespace dirs count as caches; every start removes ones
  unused for 14 days (safe to wipe while stopped). Without
  `--persistent-cache` the SSD cache lives in `$TMPDIR` and **ignores
  `--cache-dir`**.
- `GET /status` reports under `disk`: `capacity_bytes`, `limit_bytes`,
  `used_bytes` (+`kv_bytes`/`kv_blocks`), `file_bytes`,
  `volume_available_bytes`, `writes_gated` (`no|budget|closed`),
  `persistent`, `taken_back`.

**Current code state (the delta this spec builds on)**

- `SplashChip` (`ModelProxy/Services/SplashInstaller.swift:5-30`): sysctl
  brand string → `.forkM1M2` / `.officialM3Plus`; unknown → nil → fork.
- Binary resolution fork-only: `SplashManager.swift:149-155`
  (`binaryPathOverride` → `/opt/homebrew/bin/splash-m1` → app-support
  `bin/splash-m1`).
- Latest check fork-only: `SplashTabView.swift:374` calls
  `latestForkRelease()` unconditionally;
  `SplashInstaller.releasesURL` (:108) is paperniuk-only.
- `SplashVersion.parse/isOlder` (:34-54): numeric-core compare tolerating
  `-m1`; dead code in production.
- `serveArguments(port:)` (`SplashSettings.swift:39-45`): profile flags →
  extraArgs → `--port` if absent. The seeded profile carries cache flags
  in extraArgs (:118-120).
- No update machinery anywhere (no Sparkle, no GitHub call for zgate);
  version display = `FeedbackMail.versionDisplay` (bundle strings).
- Menu bar: `MenuBarLabel` (`ModelProxyApp.swift:93-123`) shows
  `ProxyServer.menuBarSymbol` (`ProxyServer.swift:338-356`, fault symbols
  with priority over the healthy ring) else the `QuotaMenuBarIcon`
  template ring (:81-196). No badge mechanism.
- About: `AboutTabView` (`SettingsView.swift:934-989`); Credits section
  (:946-967) has a link-less "Splash local target" block.
- **Port desync bug:** the splash vendor `baseURL` is hardcoded
  `http://127.0.0.1:8123` (`AppConfig.swift:213`) and does not follow
  `SplashSettings.port`.

## 3. Architecture

### 3.1 SplashChip becomes the variant table

```swift
extension SplashChip {
    var binaryName: String          // "splash-m1" | "splash"
    var repoSlug: String            // "paperniuk/splash" | "incoai/splash"
    var installKind: …              // .tarball(Splash-M1 layout) | .brew
}
```

Consumers: `SplashManager.resolvedBinaryPath` (probes `binaryName` at
override → `/opt/homebrew/bin/<name>` → `~/.local/bin/<name>` → app-support
fallback — new `~/.local/bin` hop mirrors the fork's shim fallback),
latest-check URL, install/update dispatch, version probing. **macOS gate:**
install/update UI and auto-apply require
`ProcessInfo.processInfo.operatingSystemVersion >= (26, 4)`; below it the
row explains ("splash needs macOS 26.4+") and disables actions.

### 3.2 `SplashTarballInstaller` — fork install and update (one mechanism)

Replaces `installForkBinary` entirely (the old direct-binary path is
dead — §1.2). Swift mirror of `install-m1.sh`, uniform asset rule for both
repos (tarball = asset matching `splash-<tag>-arm64-macos26.tar.gz`;
checksum = same + `.sha256`):

1. `GET /repos/<slug>/releases/latest` → tag + asset URLs (nil-on-failure).
2. Download tarball + sidecar (URLSession, cancellable, progress
   published); SHA-256 via CryptoKit; **abort on mismatch**.
3. `mkdir $APP/<tag>.partial` → `/usr/bin/tar -xzf … --strip-components 1`
   → `xattr -dr com.apple.quarantine` (tolerant) → replace `<tag>` dir →
   atomic `current` symlink swap (`ln -sfn` semantics via FileManager).
4. Ensure the shim exists and is correct at `/opt/homebrew/bin/splash-m1`
   (writable) else `~/.local/bin/splash-m1` — exact contents from §2. A
   legacy ZGate-installed plain binary at that path is backed up to
   `splash-m1.zgate-legacy` before the first overwrite.
5. Prune version dirs: keep `current` + the previous one.
6. Sanity: resolved binary `--version` answers the new tag.

Install root and shim dir are injectable (tests + `SPLASH_M1_HOME`-style
override). This installer serves the Install button, the Update button,
and auto-apply.

### 3.3 Official variant — brew (unchanged mechanism, wider use)

Install and update both run `/opt/homebrew/bin/brew install|upgrade
incoai/tap/splash` (existing `runBrew` seam, output streamed to the splash
log surface). Managed auto-apply requires brew presence; a
`binaryPathOverride` official install is notify-only.

### 3.4 `UpdateCenter` — checks, alert state, splash auto-apply

New `@MainActor @Observable` service, started at app launch beside
`QuotaStatusModel`; splash work gated by `SplashManager.shouldSupervise`
(the ZGate check is not). Pure seams: fetch, clock, installer, binary-path
provider.

- **What it checks** (each nil-on-failure — a failed check never alerts):
  splash installed version (release.json at the resolved install root —
  symlink-following walk-up from the binary; fallback `--version`) vs.
  latest tag from the chip's repo; ZGate `(marketing, build)` vs. latest
  tag triple. `SplashVersion.isOlder` gets its first production callers.
- **Cadence:** at launch (+30 s) if last check > 6 h ago, then every 24 h;
  manual "Check Now" everywhere state is shown. Three unauthenticated API
  calls per cycle worst case — well inside 60/h.
- **Splash apply (locked decision 2):** update available + state `stopped`
  → apply via §3.2/§3.3; running & owned → mark pending, apply on the
  running→stopped transition or immediately before the next start;
  running & adopted → banner only. One apply at a time; skip if the state
  changed mid-apply; post-apply version re-read must answer the new tag or
  the state goes to `failed` with the log tail surfaced.
- **Alert state:** `zgateUpdateAvailable(tag:)`, `splashUpdateAvailable(
  installed:latest:)`, aggregated `hasActiveAlert` — each suppressible by
  dismissing **that tag**; dismissal expires automatically when a newer
  tag appears. All persisted (§4).

### 3.5 `AppUpdateService` — ZGate self-update (explicit click only)

1. **Check** (anonymous, decision 4): `GET
   /repos/froggeric/zgate/releases/latest` → tag `v{m}.{b}` + asset
   `ZGate-<tag>.zip` + `digest`. 404/private → honest "cannot check —
   repo unreachable or private" state, no alert, no retry storm.
2. **Stage** (on click): download zip → SHA-256 vs the API `digest` →
   `/usr/bin/ditto -x -k` into
   `…/ZGate/updates/<tag>/` → staged `ZGate.app` must exist and its
   `codesign -dv` TeamIdentifier must equal the running app's. Free-space
   check (≥ 500 MB) before staging; partial downloads cleaned.
3. **Swap:** run the **bundled** `scripts/release-swap.sh` (added to the
   app target's Copy Bundle Resources from the repo path — one file, no
   fork) via `/bin/zsh <script> <staged-path>`, inheriting the
   environment. The script SIGTERMs the app (its own parent — it is
   designed to outlive it), swaps, reopens, health-checks, rolls back on
   failure. The UI relays exit code + log tail. Offered only when the
   running bundle is exactly `/Applications/ZGate.app` (the script's
   constraint); otherwise the banner falls back to "open Releases page".
   Never silent; never automatic.

### 3.6 Storage & cache

New machine-level `SplashStorage` on `SplashSettings` (§4), emitted by
`serveArguments(port:)` **between profile flags and extraArgs** (extraArgs
keep their documented last-word override; `--port` logic unchanged and
scans the full arg list):

```swift
struct SplashStorage: Codable, Equatable, Sendable {
    var modelCacheLocation: String?   // nil = default; → HF_HUB_CACHE env
    var persistentCache: Bool         // → --persistent-cache
    var cacheDir: String?             // → --cache-dir (only when persistent)
    var maxCacheDisk: String?         // nil = auto (no flag); "0" = off; "16G"
    var maxCacheDiskWrites: String?   // nil = none; "200G"
}
```

- **Launch env:** `SplashManager` passes the inherited environment plus
  `HF_HUB_CACHE` when `modelCacheLocation` is set (today it passes none
  explicitly).
- **Migration (one-shot, ConfigStore.load):** when `splash.storage == nil`
  and the *active* profile's extraArgs carry recognized cache flags, lift
  them into `SplashStorage` (parse values, drop the flags from that
  profile only; other profiles keep theirs — extraArgs still win
  per-profile). Guarded by `storage == nil` so it runs once.
- **Move model cache:** requires stopped; source = current setting else
  the HF default; preflight free-space check on the target;
  `/usr/bin/ditto src dst` → size verification → rename source to
  `<src>.zgate-moved-<ts>` → set config → surface "Delete old location"
  (explicit user action, never automatic).
- **Clear prefix cache:** while stopped, remove only 32-hex-digit
  directories under the effective cache root (splash's own GC shape).
- **Clear model cache:** destructive-confirm, removes the HF cache dir
  contents (models re-download on next serve).
- **Live usage:** `GET /status` → `disk` object (tolerant decode of the
  §2 fields) shown in the storage section while running.

## 4. Config changes (all tolerant-decode, absent-key → default)

- `SplashSettings.storage: SplashStorage?` (nil until migrated or set).
- `AppConfig.update: UpdateSettings?`:
  ```swift
  struct UpdateSettings: Codable, Equatable, Sendable {
      var autoCheck: Bool = true            // gates the periodic timer
      var splashAutoApply: Bool = true      // locked decision 2 default
      var lastSplashTag: String?
      var lastZGateTag: String?
      var lastCheckAt: Date?
      var dismissedSplashTag: String?
      var dismissedZGateTag: String?
  }
  ```
- No other config shape changes; old configs load unchanged.

## 5. UI

- **Menu bar:** `QuotaMenuBarIcon.image(weeklyFraction:stale:
  updateAvailable:)` gains a small filled badge dot (top-right, template,
  dark/light safe) driven by `UpdateCenter.hasActiveAlert`. Fault symbols
  (`menuBarSymbol != nil`) still replace the whole icon and always
  outrank the badge. Accessibility label appended.
- **Popover:** an update banner per available target in the existing
  `bannerSection` (orange `arrow.down.circle.fill`): "ZGate 2.8.10 —
  Install / View…" (Install → §3.5 stage+swap with confirm; View →
  Releases page) and "splash 1.6.2-m1 available — Update / View"
  (Update → apply now: owned-running asks to restart; else applies).
  Each dismissible (×) → dismissed tag persisted.
- **Splash tab:** install row upgraded — per-chip repo + installed vs
  latest with a real `update available` verdict (`isOlder`), Update
  button wired to the managed apply, macOS-gate line; new **Storage
  section** (§3.6 controls: model-cache location/size/free/Change/Move/
  Reveal/Clear; persistent toggle; cache dir picker (gated); quota
  Auto/Off/Custom with size validation (`K/M/G`); write budget; usage
  row from /status; Clear prefix cache).
- **About tab:** Check for Updates button + state line (idle /
  up-to-date / `<tag> available` / cannot check); Credits gains
  **"Splash — local inference engine by Inco (Apache-2.0)"** →
  `github.com/incoai/splash` and **"Splash M1/M2 port by paperniuk &
  contributors (Apache-2.0)"** → `github.com/paperniuk/splash`.
- **General tab:** update-settings rows: check-for-updates toggle,
  splash auto-apply toggle.

## 6. Adjacent fixes riding this wave

1. **Port desync:** the splash vendor baseURL derives from
   `SplashSettings.port` at routing time instead of the hardcoded 8123
   (`AppConfig.swift:213`); regression test: change port → routed target
   follows.
2. Asset picker + `installForkBinary` deletion (superseded by §3.2);
   `SplashVersion` moves from dead code to load-bearing.

## 7. Testing (TDD; seams only, no network in unit tests)

- **Variant matrix:** chip → binaryName/repo/installKind; resolution
  order incl. `~/.local/bin` hop and per-chip names (M3+ `splash` found).
- **Tarball installer (behavioral, temp dirs):** real fixture tarball
  built in-test with `/usr/bin/tar`; real SHA-256 (both match and
  mismatch-abort); unpack + `current` swap + shim write (incl. legacy
  backup) + pruning; injectable root/bin dir; failure at each step
  leaves the previous install intact.
- **UpdateCenter:** injected fetch/clock/installer — per-chip repo
  selection; nil-on-failure; dismissed-tag expiry on newer tag; cadence
  gating (launch > 6 h, 24 h timer); apply-when-stopped transitions
  (stopped → apply; owned running → pending → applied on stop/before
  start; adopted → never); one-apply guard; post-apply version
  verification failure path.
- **AppUpdateService:** tag triple parse/compare; staging with fixture
  zip + digest verify (mismatch aborts); TeamID compare stub; swap
  invocation composed with an injectable script path (recorded argv,
  `--dry-run` in tests) — the real swap is NEVER executed by tests.
- **Storage:** arg-emission matrix (defaults → no flags; each flag;
  cacheDir-without-persistent suppressed; extraArgs still win; --port
  scan unaffected); migration lift (values parsed, active profile only,
  one-shot); env injection; `/status` disk decode fixture (full + minimal
  + malformed); clear-prefix-cache removes only 32-hex dirs; move
  mechanics on temp dirs (ditto + verify + rename; failure paths).
- **UI-adjacent:** menu-bar badge flag → image differs (pure drawing
  unit); banner state → visibility matrix. Full suite green before any
  install swap.

## 8. Success criteria

- On this M2 Max: UpdateCenter reports the true fork state (installed
  `1.6.1-m1.1`-class vs live latest) within a launch; simulated-newer
  fixture flips the menu-bar badge and popover banner; dismissing the tag
  clears both until a newer tag.
- Splash stopped + update available + auto-apply on → tarball installer
  runs end-to-end (sandboxed root in tests; real path by manual smoke on
  this machine), `--version` answers the new tag, badge clears.
- M3+ (unit-level): resolution finds `/opt/homebrew/bin/splash`; latest
  check hits incoai; install/update verbs compose brew commands.
- Storage: changing model-cache location injects `HF_HUB_CACHE` into the
  splash process env; persistent+dir+quota+write-budget emit the exact
  documented flags before extraArgs; migration lifts the seeded
  profile's existing flags so the UI shows them truthfully; Clear prefix
  cache wipes only namespace dirs; Move relocates a fixture HF cache and
  leaves a deletable backup.
- Self-update: with the repo public, Check Now finds v2.8.9 vs running
  build; staging verifies digest + TeamID; Install invokes the bundled
  script with the staged path (verified via dry-run); private/404 shows
  the honest degraded state.
- Old configs load unchanged; port change updates the routed splash
  vendor target.

## 9. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Repo flip to public not yet done | ZGate check degrades to explicit "cannot check" (no alert, no retry storm); splash checks unaffected |
| Bundled `release-swap.sh` drifts from the repo file | pbxproj references the repo file itself — one source of truth; script changes ship with the next release |
| App kills itself and the swap fails | Script's own rollback (mv backup back, reopen, exit 5) + UI relays exit codes; explicit-click only |
| GitHub rate limit (60/h shared per IP) | ≤3 calls/cycle, launch-gate >6 h + 24 h cadence, nil-on-failure, persisted lastCheck |
| Downloaded tarball/zip integrity | SHA-256 both (sidecar / API digest); TeamID compare for the app zip; atomic installs only after verify |
| Quarantine on downloaded archives | Installer strips recursively post-extract (mirrors install-m1.sh) |
| GUI-session PATH for the swap script | Script runs via `/bin/zsh` with inherited env; its tools are all in /usr/{bin,libexec},/sbin — verified against the script; dry-run smoke in testing |
| brew absent/slow on M3+ | Existing error path; auto-apply marks failed with log tail, never blocks splash start |
| Storage UI lies vs extraArgs overrides | Migration lifts active-profile flags; UI notes "extraArgs may override" on the storage section |

## 10. Amendments to the 2026-11-16 spec

- §3.2 fork install (direct binary asset + exact-`splash-m1` rule +
  EACCES fallback to app-support bin) is **superseded** by §3.2 here
  (tarball + SHA-256 + Splash-M1 layout + shim). The app-support fallback
  binary path survives only as the last resolution hop for legacy
  installs.
- §4's non-goal "port fixed at 8000" was already lifted (2026-11-18,
  default 8123); this wave removes the last hardcoded 8123 (vendor
  baseURL).
- §2's "install script is never executed" principle is kept and extended:
  ZGate downloads artifacts and performs every step itself; the only
  script ever executed is our own bundled `release-swap.sh`, from a
  digest-verified zip.

## 11. Open items / deployment prerequisites

- **User action:** flip `froggeric/zgate` to public (locked decision 4).
- Release flow unchanged otherwise (notarize → zip after staple → tag
  `v{m}.{b}` → asset `ZGate-<v>.zip`). The updater relies on the
  existing `digest` field — no appcast, no signing keys to manage.
- Deferred: prerelease channels, delta updates, per-profile storage
  overrides, Sparkle migration path (documented decision against).

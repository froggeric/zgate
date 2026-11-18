# ZGate — Splash Lifecycle Management (Package C) — Design

- **Date:** 2026-11-16
- **Status:** design approved in chat; spec pending user review
- **Precedes:** implementation plan (writing-plans) — no implementation before plan approval
- **Canonical:** this file, in the zgate repo. (Pointer stub at
  `zcode/docs/superpowers/specs/` for continuity with the v1 workflow.)
- **Context docs:** `docs/specs/` sibling of the v1 design (zcode:
  `docs/superpowers/specs/2026-11-15-zgate-design.md`), `README.md`, `docs/e2e-checklist.md`

## 1. Context and problem

ZGate routes haiku-class traffic to a local splash server (Anthropic protocol,
`http://127.0.0.1:8000`, vendor "splash (local)"), failing over to relay
GLM-5.3-Flash when splash is down. Today splash is started by hand with a long
command line; nothing starts it at login, nothing restarts it after a crash,
no UI shows what it is doing, and installing/updating it is a README exercise.

Package C gives ZGate ownership of that lifecycle: start/stop/restart, model
selection via saved profiles, install/update with chip detection, and a log
tail. This is the substrate Package D (live activity meter) builds on for
process/health hooks — telemetry itself stays out of scope here.

### Locked decisions (user, 2026-11-16)

1. **Supervision model: ZGate child process.** No launchd, no PID files.
   Accepted trade-off: splash dies when ZGate quits or updates (model reload
   ≈ 1 min per install wave), accepted for simplicity and full stdio access.
2. **Model selection: saved launch profiles.** Named profiles with all serve
   flags; active-profile dropdown; switching = restart with the new profile.
   qwen4 lands as a new profile, zero code change.
3. **Rider (this wave):** auto-class rule gets its peak twin
   (weekdays 07:00–11:00 Europe/Paris → GLM-5.3-Flash), closing the one
   unguarded 3×-billing class. Ships in the default matrix and is applied to
   the live config during this wave's install swap.

### Non-goals

- Token/telemetry metering (Package D).
- Cost estimation of any kind (user-rejected category).
- Model-weight download management — splash fetches weights itself on first
  serve; ZGate only manages the binary.
- Changing the splash port (fixed 8000; the vendor baseURL and health checks
  depend on it — power users can abuse `extraArgs` at their own risk).
- OpenAI-protocol targets; on-demand start from the request path; per-client
  splash configuration.

## 2. Grounding facts (observed, not assumed)

Probed live on this machine (M2 Max, 96 GB) on 2026-11-16:

- **Binary:** `/opt/homebrew/bin/splash-m1`, `splash-m1 --version` prints
  `Splash 1.6.1-m1` (stable shape: `Splash <semver>-m1`).
- **Server:** listening on 8000; `GET /v1/models` returns one resident model
  with rich metadata — `id`, `max_model_len`/`context_length`, `vision`,
  `input_modalities`, `limits{request_bytes,images,image_bytes,pdf_bytes,pdf_pages}`,
  `reasoning{thinks,efforts[],default}`, plus a legacy `models[]` array.
  Decoding tolerates either list.
- **Serve flags in use today** (the seeded profile's source command):
  `serve --model local/qwen3.8-27b-q8 --model-dir <GGUF> --draft-model <DFlash2
  snapshot> --persistent-cache --cache-dir /Volumes/ssd/ai/cache/splash
  --max-cache-disk 20G --mmproj <mmproj-F16.gguf>`.
  Full surface includes `--port`, `--api-key`, `--idle-release`, `--offline`,
  `--max-context`, `--language-only`, `--disable-ane`, … — carried verbatim
  through `extraArgs` when present.
- **Install (M1/M2):** fork `paperniuk/splash`; release assets include the
  binary and a DMG; README offers `curl … install-m1.sh | sh` (we do NOT pipe
  remote scripts — we download the binary asset directly via the GitHub
  releases API and install it ourselves). Running the install script line
  again upgrades; models live in the HF cache and survive upgrades.
- **Install (M3+):** official `brew install incoai/tap/splash` (shell-out to
  brew; not exercisable on this M2 machine — covered by unit tests on the
  command composition only).
- **Chip detection:** `sysctl -n machdep.cpu.brand_string`, e.g.
  `Apple M2 Max` → M1/M2 family → fork; `Apple M3…`/M4 → official.
- **Upstream README notes** relevant to defaults: `--prefill-mode bounded` is
  the default and must be kept (never pass `full` on M1/M2); INT8 KV cache is
  the default and preferred. The manager never passes these flags; it only
  forwards profile args.

## 3. Architecture — three units

### 3.1 `SplashManager` (ModelProxy/Services/SplashManager.swift)

Owns the child `Process` and the splash lifecycle state machine.

```
enum SplashState: Equatable {
    case stopped
    case starting(profile: String)
    case running(profile: String, since: Date, adopted: Bool)
    case crashed(profile: String, lastExit: Int32, nextRetry: Date)
    case stopping
}
```

- **`start(profile:)` / `stop()` / `restart(profile:)`** — public surface.
  `stop()` = SIGTERM → grace (10 s) → SIGKILL → waitpid (no zombies).
- **Launch:** composes `splash serve` + profile args and spawns the resolved
  binary — resolution order: `binaryPathOverride` (if the file exists) →
  `/opt/homebrew/bin/splash-m1` → fallback dir binary. stdout+stderr are
  piped to a ring buffer (last 500 lines, in-memory, main-actor published for
  the log view). Line-buffered reading on a background task.
- **Readiness:** `starting` → `running` on first evidence the server answers:
  poll `GET /v1/models` on 8000 every 500 ms (timeout window 120 s → failed
  start = `crashed`). Log "Ready"-style lines are advisory only; the HTTP
  probe is the truth.
- **Keep-running** (user default, persisted): ZGate starts splash at app
  launch with the active profile when the toggle is on.
- **Crash policy:** unexpected child exit while keep-running on → relaunch
  with exponential backoff 1 s → 2 s → 4 s … 60 s cap; counter resets after
  5 min of stable running. Crash with keep-running off → `stopped`.
- **Ownership — owned vs adopted:**
  - At manager init (or keep-running engage), if 8000 already answers and no
    child is ours, enter `running(adopted: true)`. No signal control; Stop is
    disabled with explanatory text ("external instance — stop it manually or
    Restart to take ownership"); Restart = wait for port free → start owned.
  - Adopted instance dies while keep-running on → start our own (port now
    free). This is exactly the transition for today's externally-started
    server (a background task of the design session).
- **App quit:** SIGTERM to owned child in `NSApplication.willTerminate`
  (plus best-effort in the XPC-less dealloc path). Adopted children are left
  alone.
- **Concurrency:** `@MainActor` observable object; Process I/O off-main;
  state transitions published for SwiftUI. Pure decision logic (backoff
  schedule, arg composition, state folding) factored into internal pure types
  so tests need no real processes.

### 3.2 `SplashInstaller` (ModelProxy/Services/SplashInstaller.swift)

- **Detect chip** → `.forkM1M2` / `.officialM3Plus` (sysctl parse; unknown →
  nil → UI shows both options, user picks).
- **Version status:** `splash-m1 --version` (or `splash --version` for
  official) vs latest release via GitHub API
  `https://api.github.com/repos/paperniuk/splash/releases/latest`
  (`tag_name`, `assets[].browser_download_url`); no auth (public repo).
  Version compare on the semver, `-m1` suffix tolerated.
- **Install/update (fork):** download the binary asset with URLSession to a
  temp file → `chmod +x` → atomic `rename()` into
  `/opt/homebrew/bin/splash-m1`. Asset selection rule: the release asset
  whose name is exactly `splash-m1` (the installed binary's name); if the
  release names it differently, the single non-DMG, non-`.sh` asset; an
  ambiguous release is an error surfaced in the UI, never a guess. On
  EACCES fall back to
  `~/Library/Application Support/ZGate/bin/splash-m1` and remember the path
  (persisted config: `splash.binaryPathOverride`). Refuse to run a downloaded
  binary from its temp location; only after install. Cancellable
  (URLSession task cancel); progress fractions published for the UI.
- **Install (M3+):** run `/opt/homebrew/bin/brew install incoai/tap/splash`
  (or `brew upgrade`), streaming output into the same log surface.
- **Never** pipe remote shell to `sh`; never execute the install script.
- Pure seam: `fetchRelease()` and file operations injected for tests — no
  network in unit tests.

### 3.3 Discovery client (ModelProxy/Services/SplashModelsClient.swift)

- `GET /v1/models` decode → `[SplashModelInfo]` (id, contextLength, vision,
  reasoning efforts). Used by the profile editor to offer a live dropdown of
  what the current splash instance serves, plus free-text entry (the common
  case is a model NOT yet resident — switching profiles restarts the server
  onto it). Failure = empty list + free text still works.

## 4. Profiles and config

```swift
struct SplashProfile: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String                  // "Qwen3.8-27B Q8 (local GGUF)"
    var model: String                 --model
    var modelDir: String?             --model-dir
    var draftModel: String?           --draft-model
    var mmproj: String?               --mmproj
    var extraArgs: [String]           // verbatim, e.g. ["--persistent-cache", "--cache-dir", "/Volumes/ssd/ai/cache/splash", "--max-cache-disk", "20G"]
}

struct SplashSettings: Codable, Equatable {
    var keepRunning: Bool             // default true
    var activeProfileID: UUID?
    var profiles: [SplashProfile]     // default []
    var binaryPathOverride: String?   // default nil
}
```

- `AppConfig.splash: SplashSettings?` — absent on existing configs → defaults
  (decode-tolerant, same pattern as the rest of AppConfig).
- **First run seeds one profile** from the machine's current invocation
  (§2's command) named "Qwen3.8-27B Q8" and makes it active — zero-config for
  the user this machine already is.
- **Switching active profile** = `restart(profile:)`; if state is `stopped`
  and keep-running off, just records the choice.
- Arg composition rule: only non-nil fields become flags; `extraArgs` appended
  verbatim last (so users can override earlier flags per splash's argparse).

## 5. UI

**Settings → new "Splash" tab:**

1. Status block — state line + colored dot (`running · qwen3.8-27b · 2h 13m`,
   `crashed · retry in 12 s`, `stopped`, `starting…`), Start/Stop/Restart
   buttons (enabled per state; Stop disabled when adopted), keep-running
   toggle.
2. Model profiles — active-profile dropdown + edit sheet (name, model w/
   discovery dropdown + free text, modelDir/draftModel/mmproj paths,
   extraArgs token field). Delete/add profiles; deleting the active one
   clears `activeProfileID`.
3. Install row — "M2 Max detected · fork 1.6.1 installed · 1.6.2 available →
   Update" (or Install if missing; progress during download; official/brew
   variant on M3+).
4. Log tail — last lines of the ring buffer, monospaced, auto-scroll,
   copyable (context menu), pause-on-scroll optional (v1: simple).

**Menu-bar popover:** one-line chip under the quota section —
`● splash · qwen3.8-27b` (green/red/gray by state); click → opens Settings →
Splash tab. No further popover surface in C.

Router untouched: the haiku rule's splash→Flash failover already covers
splash-down; no on-demand start from the request path.

## 6. Routing riders in this wave

1. **Auto peak twin (code):** default matrix gains, ahead of the plain auto
   rule, `matchClass: auto, conditions: [timeWindow weekdays 07:00–11:00
   Europe/Paris] → GLM-5.3-Flash` — mirroring the opus twin.
2. **Live config (install-time):** the same rule is inserted into the
   installed `config.json` during this wave's atomic install swap.
3. **README routing note (docs):** document the tier-alias convention that
   CC's `ANTHROPIC_DEFAULT_*_MODEL` env must classify into distinct classes
   (`glm-5.3-opus[1m]` / `glm-5.3[1m]` / `qwen3.8-27b-haiku` as set on this
   machine 2026-11-16), since the classifier keys on those strings. Include
   the companion context-window note: an unrecognized haiku-class ID makes
   CC assume 200k while splash serves 262,144 —
   `CLAUDE_CODE_MAX_CONTEXT_TOKENS=262144` (set in CC env 2026-11-16)
   corrects it and is inert for the `[1m]`-suffixed aliases, which keep
   their assumed 1M window.

## 7. Testing (TDD; every unit watched red first)

- **Manager:** stub executable (a tiny shell fixture) for start/stop/exit
  code paths; injected clock + scheduler for backoff (1→2→4…60, reset after
  5 min); arg composition from profile (nil fields skipped, extraArgs last);
  readiness probe injected (fast success, timeout → crashed); adopted vs
  owned transitions; ring-buffer trim at 500.
- **Installer:** chip-string parse (M1/M2/M3/M4/unknown); version string
  parse + compare (1.6.1-m1 < 1.6.2, equal, greater); releases-JSON decode
  fixture (tag + asset URL pick); EACCES → fallback path recorded; command
  composition for brew variants. All fetch/file ops via injected seams.
- **Discovery:** decode of the real `/v1/models` shape (§2) as a fixture —
  both `data[]` and legacy `models[]`; malformed → empty.
- **Config:** SplashSettings round-trip; absent section → defaults; seeded
  profile fixture matches the current command's args exactly.
- **Router rider:** default matrix contains the auto twin ordered before the
  plain auto rule; condition evaluates inert outside the window (existing
  test patterns).
- Full suite green (346 → ~380) before the wave's install swap.

## 8. Success criteria

- ZGate relaunch (or toggle-on) with no external splash running → splash
  comes up owned with the active profile and serves haiku traffic (live
  round-trip through ZGate:8787 → splash).
- Kill -9 the splash child → ZGate relaunches it within backoff and the
  popover state never lies about it.
- Switching to a second profile restarts onto it; switching back restores.
- Fresh machine (simulated): missing binary → Install row installs fork
  binary for M1/M2 chip string; override path honored when EACCES.
- Auto peak twin present in shipped defaults and live config; inert outside
  07:00–11:00 weekdays Paris.
- Existing configs (no `splash` section) load unchanged; no router behavior
  change on any existing rule.

## 9. Risks and mitigations

| Risk | Mitigation |
|---|---|
| ZGate update/quit kills a loaded model (~1 min reload) | Accepted (locked decision); persistent KV cache shortens reload; install swaps remain atomic and at idle moments |
| Port 8000 race (two starts) | Readiness probe gates `running`; adoption check before any start; start only when port free |
| GitHub API shape change / rate limit | Installer degrades to "unknown latest" UI; current version still shown; install disabled, not misreported |
| Downloaded binary integrity | HTTPS + fixed repo; atomic rename only after full download; version re-read post-install to confirm |
| Settings save while manager busy | Manager consumes a snapshot of config at each action; mid-flight saves queue naturally via next restart |
| Session-owned splash (today's external instance) | Adoption path exists precisely for this; on its death, owned start takes over automatically |

## 10. Open items

None blocking. Deferred by design: `--api-key` on splash (loopback-only
threat model), idle-release tuning UI, Package D telemetry hooks (manager
publishes state; D subscribes).

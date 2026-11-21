# ZGate

Native macOS menu-bar proxy for Claude Code: routes Anthropic-protocol traffic
to the **signed zcode relay** (GLM models) with **quota-aware routing rules**
and an optional **local-model server** (Splash). Menu-bar app — no dock icon,
no window unless you open Settings. Everything a fresh install needs is in
this README.

ZGate is a fork of [model-proxy](https://github.com/n0rvyn/model-proxy) (MIT).
The original project's README is preserved at [`README.upstream.md`](README.upstream.md).

## What ZGate is

ZGate listens on `127.0.0.1` and speaks the Anthropic protocol to Claude Code.
Every request is matched against an ordered rule table (editable in Settings)
and forwarded to its target: the **signed zcode relay** (z.ai GLM models, V4
request signing — nothing ever goes out unsigned to the relay) or a **local
model server** (Splash). Requests are logged for the popover's traffic view;
request/response bodies and credential values are never stored or logged.

### The default routing matrix

Applies to fresh installs (first launch with no config — see
[Configuration](#configuration)). First match wins; order and every field are
editable in Settings → Rules.

| Match | Primary target | Backup | Notes |
|---|---|---|---|
| `auto` (no/unset model) | zcode relay `GLM-5.3` | — | Claude Code auto mode |
| `haiku` class (incl. `glm-5.3-flash`) | zcode relay `GLM-5.3-Flash` | — | fast/background tier |
| `sonnet` class | zcode relay `GLM-5.3` | — | v2.1: same serving as opus |
| `opus` class, weekdays 07:00–11:00 Europe/Paris | zcode relay `GLM-5.3-Flash` | — | peak twin — **disabled** by default (3× peak metering; dormant cost lever) |
| `opus` class | zcode relay `GLM-5.3` | — | |
| `haiku`/`sonnet` (local qwen levers) | splash `local/qwen3.8-27b-q8` | relay `GLM-5.3-Flash` | **disabled** by default — one toggle in Settings → Rules takes that tier local (health-gated) |
| custom rule → `ZCode Off-Peak` (opt-in) | ZCode off-peak ticket plane | rule's backup | **no default rule targets it** — attach the seeded ZCode Off-Peak vendor to a rule (Settings → Rules); window open + surface enabled + `stream: true` → ticket plane, any gate closed → backup; non-streaming requests NEVER queue; no (non-off-peak) backup → 503 `off_peak_unavailable` |
| fallback (catch-all, incl. unknown/local qwen ids) | zcode relay `GLM-5.3-Flash` | api.z.ai edge | no request is ever dropped |

**v2.11 off-peak as a first-class citizen (2026-11-21):** the off-peak
surface (Settings → General → Off-Peak, default OFF) routes generation
through ZCode's off-peak ticket queue: enabling it polls window
availability automatically every 300 s (live status line + popover row,
and it mints the coding-plan key on the first poll), and any routing rule
can target the seeded **ZCode Off-Peak** vendor — window open + surface
enabled + streaming rides the ticket plane, anything else (closed,
disabled, non-streaming) serves the rule's backup, so interactive traffic
is never captured unattended (a non-streaming request can never queue or
see the stream-only error through a rule; no usable backup answers a
clear 503, and the rule editor requires a backup up front). Rule-routed
off-peak requests record token stats under the vendor. The manual
`/async/…` route family remains for batch harnesses, and every toggle in
the app now shows a colored enabled-state (an app accent is defined;
previously all switches rendered grey under the macOS Graphite accent) —
details in
[`docs/05-features/2026-11-20-offpeak-wave2.md`](docs/05-features/2026-11-20-offpeak-wave2.md).

**v2.10 relay fidelity & resilience (2026-11-20):** the relay path mirrors
the official zcode CLI wire face exactly (ordered headers, UA, per-
conversation session ids feeding the proof-of-work and signature inputs),
tracks the server's minimum client version, and canonicalizes retired
model names and out-of-range `max_tokens` before send (documented
routing-compatibility transforms). Upstream failures are classified by
business code with bounded retry policies, connect failures retry on a
short ladder, and a signing outage degrades to a signing-free `api.z.ai`
fallback edge with half-open recovery (an expired login recovers by
signing in again) — wave-1 details in
[`docs/05-features/2026-11-20-relay-fidelity-resilience.md`](docs/05-features/2026-11-20-relay-fidelity-resilience.md).
The class rules above carry no rule-level backup; when signing degrades,
their traffic is served directly by the fallback edge instead.

**v2.1 routing (2026-11-17):** all deliberate work — the opus and sonnet
tiers — goes to full `GLM-5.3`; fast/background chatter (the haiku tier)
goes to `GLM-5.3-Flash`. The local qwen model is off all default routes
(quality ruling, 2026-11-17). The peak twins (auto and opus) ship disabled
by default — a dormant cost lever if relay peak metering is ever confirmed.

Splash — the local Anthropic-protocol server on `127.0.0.1` (port
configurable, default **8123** — moved off 8000 in 2026-11-18 to stop
colliding with local webservers) — is optional and managed from Settings →
Splash (see [Splash](#splash-local-server-optional)); no ENABLED default
rule targets it.

### Claude Code tier aliases

Claude Code sends the strings from its `ANTHROPIC_DEFAULT_OPUS_MODEL`,
`ANTHROPIC_DEFAULT_SONNET_MODEL`, and `ANTHROPIC_DEFAULT_HAIKU_MODEL` env
as the model field, and ZGate classifies those strings: a `haiku` or `flash`
substring → haiku class (the fast tier), `opus`/`fable` → opus, `sonnet` →
sonnet, a bare `glm-5.3` prefix → opus, unset or `auto*` → auto; anything
unrecognized (local qwen ids) falls through to the terminal fallback rule.
The aliases below (set 2026-11-17) deliberately land the opus and sonnet
picks on the **same** class: all deliberate work — main thread and
subagents — runs full GLM-5.3 on the relay, the haiku alias carries
fast/background chatter on GLM-5.3-Flash, and the local qwen model is off
all default routes (quality ruling, 2026-11-17):

| CC pick | Alias | Class | Serves |
|---|---|---|---|
| opus | `glm-5.3[1m]` | opus | relay GLM-5.3 |
| sonnet | `glm-5.3[1m]` | opus | relay GLM-5.3 |
| haiku | `glm-5.3-flash[1m]` | haiku | relay GLM-5.3-Flash |

Also set `CLAUDE_CODE_MAX_CONTEXT_TOKENS=262144`: for model ids it doesn't
recognize, Claude Code would otherwise shrink its context-window assumption
— this pins it at 262,144. The variable is inert for the `[1m]` aliases,
which keep their 1M assumption — the relay's real offering.

## Requirements

- macOS (Apple Silicon), admin access to copy ZGate.app into `/Applications`.
- **Splash** — optional local server; Settings → Splash installs and manages
  it (see [Splash](#splash-local-server-optional)).

## First-run setup

### 1. Build & install (release)

```bash
xcodebuild -project ZGate.xcodeproj -scheme ZGate -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build build
cp -R build/Build/Products/Release/ZGate.app /Applications/
```

(Ad-hoc signed — fine for a personal machine. First build resolves SPM
packages: swift-nio, async-http-client.)

### 2. Sign in (in the app)

ZGate reads credentials from the zcode store — by default the **shared
store** the ZCode GUI and CLI use (`~/.zcode/v2/credentials.json`;
Settings → General → Credentials can switch to an isolated scratch store
instead). If you are already logged into the ZCode GUI or CLI, ZGate uses
that session as-is: the CLI seals its store with a macOS **Keychain**
secret, and ZGate reads it through the same Keychain — expect **one
access prompt on first use** (click Always Allow; denying it is a typed,
recoverable error, never a loop).

Otherwise sign in from the app: the credential row's **Sign In** button
(popover, or Settings → General → Credentials) opens the z.ai approval page
in your browser; ZGate picks the session up live — no terminal command, no
restart. The in-app login writes the shared store in the flavor it already
uses, so a CLI login on the same machine keeps working. The copyable
terminal command remains as a fallback in the login alert.

Interactive login is needed about **once per 180 days** (or on revocation):
while ZGate runs, a background keeper renews the short-lived tokens
automatically (see [Credentials & login status](#credentials--login-status)).

### 3. Launch ZGate

`open /Applications/ZGate.app` — the **ZΓ** status item appears in the menu
bar (no dock icon). It is icon-only: a **quota ring with the ZΓ mark
inside** — the arc is your remaining weekly quota, clockwise from 12
o'clock. The exact percentage lives in the popover (and the VoiceOver
label). Listeners start at launch.
Optional: Settings → General → **Launch at Login** (SMAppService
registers/unregisters the login item).

### 4. Point Claude Code at ZGate

Copy the env line from the popover (it shows the *actual bound port*):

```bash
export ANTHROPIC_BASE_URL=http://127.0.0.1:8787
```

8787 is the default Claude Code port on fresh installs (Codex listens on
8789; 8788 is reserved by zbridge — this fork's retired Node.js predecessor —
on this machine). If the configured port
is taken, ZGate advances to the next free port — the popover line always
tells the truth. Set the tier aliases too — see
[Claude Code tier aliases](#claude-code-tier-aliases).

### 5. First request — two things to expect

- **A few seconds of latency on the very first relay request**: ZGate builds
  its V4 signing session (handshake + key derivation) once, on demand. Later
  requests are fast.
- **If no login is available yet**, the credential row shows red instead
  ("sign in to use the relay" on a fresh install, "login expired — sign
  in" once a stored login has lapsed): click Sign In, complete the browser
  approval, and the row flips to green without restarting ZGate. From then
  on the keeper keeps the ladder renewed.

## Credentials & login status

The popover's credential row (and Settings → General → Credentials) is
always current:

| Face | Meaning |
|---|---|
| ● signed in · N min left | plan token healthy; renewed before it lapses |
| ● renewing | a renewal is in flight or retrying (backoff) |
| ● authorizing… | an in-app login is waiting for browser approval |
| ● sign in to use the relay | no stored login yet (fresh install): click Sign In (red, persistent; the menu-bar icon badges too) |
| ● login expired — sign in | a stored login lapsed: click Sign In (red, persistent; the menu-bar icon badges too) |
| ● degraded (unsigned) | the last request was served by the unsigned fail-open path — working, but not healthy |

- **Auto-renewal**: while ZGate runs, a background keeper mints each new
  plan token ~2 min before its ~52-min expiry and re-evaluates after
  sleep/wake; failures back off instead of looping. Interactive login only
  matters when the ~180-day session itself dies.
- **Hot pickup**: a login made in the ZCode GUI or CLI (shared store) — or
  via Sign In — is adopted by the running app on the next request. Settings
  → General → Credentials → Reload forces it immediately. Restarting ZGate
  is never required for credential changes.

## Splash (local server, optional)

Settings → Splash manages the local server. Keep-running starts splash with
the active profile at ZGate launch (adopting an already-running external
instance instead of double-starting; when that instance dies, ZGate starts
its own). The server is a ZGate child process: quitting ZGate stops it.
Model profiles carry the full `splash serve` command line — switching the
active profile restarts the server onto it; a new model (qwen4, say) is a
new profile, no code change. The Binary row detects the chip (fork
`splash-m1` for M1/M2, Homebrew `incoai/tap/splash` for M3+), checks the
right repo for updates, and installs/updates accordingly — M1/M2 downloads
the release tarball plus its `.sha256` sidecar, verifies the checksum
before unpacking, and installs under
`~/Library/Application Support/Splash-M1/<version>` behind an atomically
swapped `current` symlink (previous version kept; the remote install
script is never executed). Both repos require macOS 26.4+ — below that
the actions disable with an explanation. The Log section tails the
server's last 500 output lines.

Available splash updates badge the menu-bar icon; with **Update splash
automatically when stopped** on (General tab) they apply whenever the
server isn't running — owned servers update on their next stop/start,
adopted external instances are never touched.

**Storage** (same tab) manages the two disk surfaces: the model cache
(`HF_HUB_CACHE` — the multi-GB model downloads; relocate with Move, which
copies + verifies and leaves a deletable backup) and the prefix cache
(`--persistent-cache`, `--cache-dir`, quota, daily write budget, live
usage from `/status`). A one-time migration lifts cache flags from the
seeded profile's extraArgs into these settings; profile extraArgs still
override per-profile.

## Updates (ZGate itself)

ZGate checks its own GitHub releases (anonymously) at launch and daily. An
available update badges the menu-bar icon and offers **Install…** in the
popover and Settings → About — explicit click only, never silent (the
proxy serves the very session that might drive it). Installing downloads
the release zip, verifies its SHA-256 digest and the developer Team ID,
then runs the bundled swap script: the app quits, `/Applications/ZGate.app`
is replaced with a backup kept, the new version reopens and health-checks
(rolling back on failure). Automatic checks can be turned off in General.

## Configuration

- **Config file:** `~/Library/Application Support/ZGate/config.json`
  (renamed from upstream's ModelProxy dir on 2026-11-18 — the app moves it
  once at launch; a pre-rename app re-seeds defaults). Token stats and quota
  history live alongside it. Hand-editing works, but the Settings editor is
  the supported path.
- **Defaults apply on first launch only.** The default matrix above is
  written when ZGate starts with no config.json. An existing install keeps
  its saved config forever — upgrading ZGate never rewrites your rules.
- **Reset to defaults:** quit ZGate (popover → Quit), delete
  `~/Library/Application Support/ZGate/config.json`, relaunch. This
  discards rule edits (not your login — credentials live in the zcode
  store, `~/.zcode` by default, outside ZGate's Application Support).
- **Settings editor:** Settings → Rules gives full CRUD on the rule table —
  add, delete, reorder (order = priority, first match wins), enable/disable,
  and edit every field (match class/model, conditions like time windows and
  quota thresholds, target vendor/model, backups). Changes apply to routing
  immediately.
- **Ports:** edit in Settings → Clients. Edits apply to routing immediately,
  but listeners keep their old ports until you **Pause and Resume** the
  proxy (or relaunch ZGate). If a port is busy at bind time, ZGate advances
  to the next free port and the popover shows the actual port.
- **Quota:** ZGate polls z.ai's official quota monitor
  (`api.z.ai/api/monitor/usage/quota/limit` — every 30 min and after every 25
  relayed requests; warning ≤ 25%, critical ≤ 10% remaining — thresholds
  fixed in this build) and feeds `quota below X%` rule conditions. The menu
  bar shows your **weekly** window's remaining % (the binding plan quota);
  the key it authenticates with is read from your Claude settings file
  (`~/.claude/settings.json`, `env.ANTHROPIC_AUTH_TOKEN`) at poll time —
  ZGate stores only the path, never the key, and never logs it. If the
  settings file is missing or has no token, the ring stays dashed and
  quota-gated rules are skipped; routing is unaffected. Last-known
  values are kept and dimmed when a poll fails while data exists.

## Quota & billing behavior

The menu bar's quota ring (ZΓ mark inside; exact percentages via the
popover and the VoiceOver label) and the popover's quota windows are the
**only user-visible billing surface** — the API quota windows (weekly + 5-hour)
polled from z.ai's monitor API. Those windows meter **everything z.ai
serves you**: direct API calls authenticated by the key in your
`~/.claude/settings.json` **and every request ZGate relays** — relayed
traffic consumes the same quota windows (confirmed 2026-11-17). Direct
usage bills at full price (cache reads bill at full uncached input price),
and `glm-5.3` bills **3× during Paris weekday peak** (07:00–11:00).

Relayed traffic draws the windows down with a **lazy sync lag**: the weekly
window updates in small steps that can lag hours behind, so a flat
menu-bar % right after heavy relay routing is a lag plateau, not exemption.
Splash (local, `127.0.0.1:<port>` — default 8123) never touches z.ai. There is no second
ledger to watch either: the z.ai web dashboard and the ZCode app show the
same quota windows the menu bar polls.

- **The 5-hour window slides:** its reset time is the oldest in-window
  usage + 5 h, not a fixed tumbling boundary. The weekly window syncs
  lazily in 1-pct steps; monitor hourly buckets are UTC+8 with a 15–45 min
  ingestion lag.
- **Counter semantics differ by source, by design:** ZGate's token stats
  count streams whose usage parsed successfully, while z.ai's monitor
  counters include all server attempts (background and failed ones too) —
  expect the totals to disagree. Full tables live in the usage audit
  (external, machine-local:
  `/Volumes/ssd/github/zcode/docs/usage-audit-2026-11-17.md`).

## Release process & signing

Release builds are signed with a **Developer ID Application** certificate
(team 46BZ85ALNS, hardened runtime on) and **notarized** with Apple — no
Gatekeeper prompts on any machine.

1. Bump `CURRENT_PROJECT_VERSION` in the ZGate target (Debug + Release).
2. `xcodebuild -configuration Release build` → BUILD SUCCEEDED.
3. `scripts/notarize.sh <Release>/ZGate.app` — submits (zips for the notary
   service), waits, staples the ticket onto the app, and runs a Gatekeeper
   assessment. One-time setup: `xcrun notarytool store-credentials
   zgate-notary` (app-specific password).
4. `scripts/release-swap.sh --dry-run <app>` then the real run (nohup,
   disowned): SIGTERM the verified prod pid → port free → backup-mv → ditto
   the new app in → relaunch → health check → automatic rollback on failure.
   Log: `/tmp/zgate-release-swap.log`.
5. Version the CHANGELOG (`marketing.build`, e.g. 2.6.4 = 2.6 / build 4),
   push `main`, tag `v<marketing.build>`,
   and publish a GitHub release with the stapled app zipped
   (`ditto -c -k --keepParent`) as the asset.

## Verify install

- [ ] `ZGate.app` runs from `/Applications`, **no dock icon**, and the **ZΓ
      status item is in the menu bar** — quota ring while the proxy serves
      (arc = weekly remaining; dashed ring before the first successful
      poll), pause symbol while paused, hourglass while launching, ⚠ on
      error or when a login is needed
- [ ] The popover's env line shows `http://127.0.0.1:<port>` and the Copy
      button puts `ANTHROPIC_BASE_URL=http://127.0.0.1:<port>` on the
      clipboard
- [ ] One round-trip answers: `ANTHROPIC_BASE_URL=http://127.0.0.1:<port>
      claude -p "say OK"` replies `OK` through the signed relay
- [ ] Request log rows for that round-trip are visible in the popover's
      traffic view (full E2E proof: [`docs/e2e-checklist.md`](docs/e2e-checklist.md))
- [ ] Within a minute of launch the menu-bar ring arc fills to match your
      weekly quota remaining (the ZΓ mark sits inside the ring; the exact
      percentage is in the popover — polled from z.ai's monitor API, which
      needs the API key in your `~/.claude/settings.json`, where Claude
      Code itself put it)
- [ ] Quitting from the popover leaves no listeners behind
      (`lsof -nP -iTCP:<port>` is empty)

## Troubleshooting

- **Credential row red / "login expired":** click **Sign In** (popover row
  or Settings → General → Credentials) — the browser opens, approval
  completes the login in-app, and the running app picks it up. The alert's
  Copy Command button remains as the terminal fallback. Expect this at most
  ~once per 180 days (or after a revocation).
- **Relay 502 on the first request:** either the signing session is still
  building (give it a few seconds and retry), or no login is available — the
  credential row shows red; see above.
- **Port 8787 already in use:** ZGate auto-advances to the next free port —
  check the popover's env line for the actual port and export that. Port
  edits in Settings need Pause/Resume (or relaunch) to rebind.
- **Splash down:** nothing in the default matrix routes to splash, so
  default routing is unaffected. Custom rules targeting splash are held
  back while its probe (`127.0.0.1:<splash port>`) fails and resume automatically when
  it answers again — start it from Settings → Splash; no ZGate restart
  needed.
- **Quota ring stays dashed:** the monitor poll couldn't
  authenticate — check that `~/.claude/settings.json` has
  `env.ANTHROPIC_AUTH_TOKEN` set (Claude Code writes it when configured for
  the z.ai API). The next poll (within 30 min, or popover → Refresh) picks
  it up with no restart; routing is never blocked by an empty bar.
- **Logs:** same Application Support directory as the config
  (`~/Library/Application Support/ZGate/`) when file logging is enabled
  (Settings → Debug). Logs never contain request/response bodies or
  credential values.

## About / attribution

- **ZGate (this fork)** — github.com/froggeric/zgate.
- **model-proxy** by norvyn — MIT; this fork's `LICENSE` is upstream's.
  Original README: [`README.upstream.md`](README.upstream.md).
- **Splash** — local Anthropic-protocol inference server by Inco
  (github.com/incoai/splash, Apache-2.0); M1/M2 port by paperniuk &
  contributors (github.com/paperniuk/splash, Apache-2.0). Managed from
  Settings → Splash (default port 8123).
- End-to-end proof against the live signed relay:
  [`docs/e2e-checklist.md`](docs/e2e-checklist.md).
- Working notes for the fork: [`docs/zgate-notes.md`](docs/zgate-notes.md).

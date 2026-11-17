# ZGate

Native macOS menu-bar proxy for Claude Code: routes Anthropic-protocol traffic
to the **signed zcode relay** (GLM models) with **local-model fallback** and
**quota-aware routing rules**. Menu-bar app — no dock icon, no window unless
you open Settings. Everything a fresh install needs is in this README.

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
| `haiku` class (incl. `glm-5.3-flash`) | splash (local) `local/qwen3.8-27b-q8` | relay `GLM-5.3-Flash` | cheap/local first |
| `sonnet` class (incl. `glm-5.3`, `glm-5.3[1m]`) | zcode relay `GLM-5.3-Flash` | — | **meters at the flash tier — see below** |
| `opus` class, weekdays 07:00–11:00 Europe/Paris | zcode relay `GLM-5.3-Flash` | — | cost lever — **disabled** by default (3× peak metering) |
| `opus` class | zcode relay `GLM-5.3` | — | |
| fallback (catch-all) | zcode relay `GLM-5.3-Flash` | — | no request is ever dropped |

**Cost note, so nobody is surprised:** sonnet-class traffic — which is what
Claude Code's main thread sends — is routed to `GLM-5.3-Flash` on purpose
(owner's explicit cost choice, 2026-11-16). Your main-thread conversations
meter at the cheaper flash tier, not the full-price tier. If you want
main-thread traffic on full `GLM-5.3` instead, edit the sonnet rule's target
model in Settings → Rules — no relaunch needed.

Splash = the local Anthropic-protocol server on `127.0.0.1:8000` (see
[Splash setup](#splash-setup-haiku-route-optional)). Splash down? The haiku
rule's relay backup serves the request automatically.

## Requirements

- macOS (Apple Silicon), admin access to copy ZGate.app into `/Applications`.
- **ZCode.app installed at `/Applications`** — ZGate's login flow borrows its
  CLI binary: `/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs`.
- **node** (any recent version; it only runs the login command above).
- **Splash** (`splash-m1`) — optional, only for the local haiku route.

## First-run setup

### 1. Build & install (release)

```bash
xcodebuild -project ZGate.xcodeproj -scheme ZGate -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build build
cp -R build/Build/Products/Release/ZGate.app /Applications/
```

(Ad-hoc signed — fine for a personal machine. First build resolves SPM
packages: swift-nio, async-http-client.)

### 2. Log in once (the scratch home)

ZGate reads credentials from the zcode scratch home. Log in once from a
terminal — a browser OAuth page opens; complete it and come back:

```bash
ZCODE_DATA_BASE_DIR=$HOME/.zcode-scratch-v3 ZCODE_CREDENTIAL_SECRET_FILE=$HOME/.zcode-scratch-v3/secret.txt node /Applications/ZCode.app/Contents/Resources/glm/zcode.cjs login zai
```

This is needed about **once per 180 days** (or on revocation): ZGate
persists a 180-day business session after the first successful relay
request. When re-login is required, ZGate surfaces an alert containing the
exact command above (with a Copy button) — you don't have to remember it.

### 3. Launch ZGate

`open /Applications/ZGate.app` — the **ZΓ** status item appears in the menu
bar (no dock icon). Listeners start at launch. Optional: Settings → General
→ **Launch at Login** (SMAppService registers/unregisters the login item).

### 4. Point Claude Code at ZGate

Copy the env line from the popover (it shows the *actual bound port*):

```bash
export ANTHROPIC_BASE_URL=http://127.0.0.1:8787
```

8787 is the default Claude Code port on fresh installs (Codex listens on
8789; 8788 is reserved by zbridge on this machine). If the configured port
is taken, ZGate advances to the next free port — the popover line always
tells the truth.

### 5. First request — two things to expect

- **A few seconds of latency on the very first relay request**: ZGate builds
  its V4 signing session (handshake + key derivation) once, on demand. Later
  requests are fast.
- **If your scratch login (step 2) is older than ~1 hour AND ZGate has never
  cached a business session yet**, that first request will fail with a
  credential alert: the 1-hour OAuth token from `login zai` has expired, so
  ZGate can't bootstrap the 180-day session. Re-run the login command from
  the alert (Copy button, browser opens) — from then on the cached session
  carries you for ~180 days and the 1-hour token no longer matters.

## Splash setup (haiku route, optional)

Skip this if you don't run the local haiku route — the haiku rule's relay
backup keeps those requests working either way. To serve the model the
default haiku rule targets, run the owner's splash-m1 command:

```bash
splash-m1 serve \
  --model local/qwen3.8-27b-q8 \
  --model-dir /Volumes/ssd/ai/llm-models/froggeric/Qwen3.8-27B-GGUF/Qwen3.8-27B-Q8_0.gguf \
  --draft-model "/Volumes/ssd/ai/cache/misc/hub/models--incoai--Qwen3.8-27B-DFlash2/snapshots/015e795645c74b1a0eeef3b570031fb62e769bc5" \
  --persistent-cache --cache-dir /Volumes/ssd/ai/cache/splash --max-cache-disk 20G \
  --mmproj /Volumes/ssd/ai/llm-models/froggeric/Qwen3.8-27B-GGUF/mmproj-F16.gguf
```

**Start Splash before haiku-class requests if you want them local.** ZGate
TCP-probes `127.0.0.1:8000`; while Splash is down the health check rules the
haiku rule out and requests skip to the relay `GLM-5.3-Flash` fallback —
they still succeed, just not locally. Nothing to restart: ZGate picks Splash
back up as soon as it answers probes again.

## Configuration

- **Config file:** `~/Library/Application Support/ModelProxy/config.json`
  (directory name kept from upstream model-proxy). Token stats and quota
  history live alongside it. Hand-editing works, but the Settings editor is
  the supported path.
- **Defaults apply on first launch only.** The default matrix above is
  written when ZGate starts with no config.json. An existing install keeps
  its saved config forever — upgrading ZGate never rewrites your rules.
- **Reset to defaults:** quit ZGate (popover → Quit), delete
  `~/Library/Application Support/ModelProxy/config.json`, relaunch. This
  discards rule edits (not your login — credentials live in the scratch
  store).
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
  settings file is missing or has no token, the bar stays empty (bare `ZΓ`)
  and quota-gated rules are skipped; routing is unaffected. Last-known
  values are kept and dimmed when a poll fails while data exists.

## Quota & billing behavior

The menu bar's `ZΓ <N>%` and the popover's quota windows are the **only
user-visible billing surface** — the API quota windows (weekly + 5-hour)
polled from z.ai's monitor API. Those windows meter **direct API calls
only**: calls authenticated by the key in your `~/.claude/settings.json`.
Direct usage bills at full price (cache reads bill at full uncached input
price), and `glm-5.3` bills **3× during Paris weekday peak** (07:00–11:00).

Everything ZGate itself carries is relayed traffic and **does not consume
those windows** — neither the zcode relay (GLM models) nor splash
(`127.0.0.1:8000`, local; splash never touches z.ai at all). Hours of heavy
relay routing leave the menu-bar % unmoved; only direct API calls draw it
down. There is no second ledger to watch either: the z.ai web dashboard and
the ZCode app show the same quota windows, and relayed usage appears on no
user-visible surface — only z.ai's raw model-usage counters record it.

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

## Verify install

- [ ] `ZGate.app` runs from `/Applications`, **no dock icon**, and the **ZΓ
      status item is in the menu bar** (branching-arrows symbol while the
      proxy serves; circled ✕ while stopped)
- [ ] The popover's env line shows `http://127.0.0.1:<port>` and the Copy
      button puts `ANTHROPIC_BASE_URL=http://127.0.0.1:<port>` on the
      clipboard
- [ ] One round-trip answers: `ANTHROPIC_BASE_URL=http://127.0.0.1:<port>
      claude -p "say OK"` replies `OK` through the signed relay
- [ ] Request log rows for that round-trip are visible in the popover's
      traffic view (full E2E proof: [`docs/e2e-checklist.md`](docs/e2e-checklist.md))
- [ ] The menu bar shows `ZΓ <N>%` within a minute of launch (your weekly
      quota remaining, polled from z.ai's monitor API — needs the API key in
      your `~/.claude/settings.json`, which Claude Code itself put there)
- [ ] Quitting from the popover leaves no listeners behind
      (`lsof -nP -iTCP:<port>` is empty)

## Troubleshooting

- **Credential-expired alert** (relogin required): the alert contains the
  exact `login zai` command with a Copy button — copy it, run it in a
  terminal, complete the browser OAuth, then Retry in the alert. Expect this
  at most ~once per 180 days.
- **Relay 502 on the first request:** either the signing session is still
  building (give it a few seconds and retry), or the scratch login is stale
  (older than ~1h with no cached business session yet) — the credential
  alert with the login command appears; see above.
- **Port 8787 already in use:** ZGate auto-advances to the next free port —
  check the popover's env line for the actual port and export that. Port
  edits in Settings need Pause/Resume (or relaunch) to rebind.
- **Splash down:** haiku-class requests silently fall back to relay
  `GLM-5.3-Flash` — they still succeed. Start Splash (command above) to go
  local again; no ZGate restart needed.
- **Quota bar stays empty (bare `ZΓ`):** the monitor poll couldn't
  authenticate — check that `~/.claude/settings.json` has
  `env.ANTHROPIC_AUTH_TOKEN` set (Claude Code writes it when configured for
  the z.ai API). The next poll (within 30 min, or popover → Refresh) picks
  it up with no restart; routing is never blocked by an empty bar.
- **Logs:** same Application Support directory as the config
  (`~/Library/Application Support/ModelProxy/`) when file logging is enabled
  (Settings → Debug). Logs never contain request/response bodies or
  credential values.

## About / attribution

- **model-proxy** by norvyn — MIT; this fork's `LICENSE` is upstream's.
  Original README: [`README.upstream.md`](README.upstream.md).
- **Splash** (`splash-m1`) — the local Anthropic-protocol inference server
  used as the haiku target on `127.0.0.1:8000`.
- End-to-end proof against the live signed relay:
  [`docs/e2e-checklist.md`](docs/e2e-checklist.md).
- Working notes for the fork: [`docs/zgate-notes.md`](docs/zgate-notes.md).

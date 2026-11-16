# ZGate

Native macOS menu-bar proxy for Claude Code: routes Anthropic-protocol traffic
to the **signed zcode relay** (GLM models) with **local-model fallback** and
**quota-aware routing rules**. Menu-bar app — no dock icon, no window unless
you open Settings.

ZGate is a fork of [model-proxy](https://github.com/n0rvyn/model-proxy) (MIT).
The original project's README is preserved at [`README.upstream.md`](README.upstream.md).

## What it does

- Local SwiftNIO listeners on `127.0.0.1` only — point Claude Code at ZGate,
  keep everything else as-is.
- Relay requests are signed (V4 signing quartet per request); ZGate never
  sends an unsigned request to the relay (it 401s them).
- Requests are logged locally for the traffic view; request/response bodies
  are never stored or logged. Credentials stay in the scratch store — token
  values are never displayed or logged.
- Menu-bar item shows live quota (`ZΓ 63%`), traffic log, rules editor and
  settings.

## Setup

### 1. Build & install (release)

```bash
xcodebuild -project ZGate.xcodeproj -scheme ZGate -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build build
cp -R build/Build/Products/Release/ZGate.app /Applications/
open /Applications/ZGate.app
```

(Ad-hoc signed — fine for a personal machine. First build resolves SPM
packages: swift-nio, async-http-client.)

### 2. Log in once (scratch home)

ZGate reads credentials from the zcode scratch home. Log in once from a
terminal (opens a browser):

```bash
ZCODE_DATA_BASE_DIR=$HOME/.zcode-scratch-v3 ZCODE_CREDENTIAL_SECRET_FILE=$HOME/.zcode-scratch-v3/secret.txt node /Applications/ZCode.app/Contents/Resources/glm/zcode.cjs login zai
```

ZGate also persists a 180-day business session, so a browser re-login is
needed at most about once per 180 days, or on revocation. When re-login is
required, ZGate surfaces an alert containing the exact command above (with a
Copy button) — you don't have to remember it.

### 3. Point Claude Code at ZGate

```bash
export ANTHROPIC_BASE_URL=http://127.0.0.1:<port>
```

`<port>` is the **Claude Code listener's configured port** — set it in
Settings → Clients (8787 in this setup; note 8788 is reserved by zbridge on
this machine). The popover and Settings → Advanced show the *actual bound
port* with a copy button: if the configured port is taken, ZGate advances to
the next free port and the displayed line always tells the truth.

### 4. Optional: launch at login

Settings → General → **Launch at Login** (SMAppService; the toggle registers
and unregisters ZGate as a login item).

## Default rules

First match wins; order and every field are editable in Settings → Rules.

| Match | Primary target | Backup | Notes |
|---|---|---|---|
| `auto` (no/unset model) | zcode relay `GLM-5.3` | — | Claude Code auto mode |
| `haiku` class (incl. `glm-5.3-flash`) | splash (local) `Qwen3.8-27B-4bit` | relay `GLM-5.3-Flash` | cheap/local first |
| `sonnet` class (incl. `glm-5.3`, `glm-5.3[1m]`) | zcode relay `GLM-5.3` | — | |
| `opus` class, weekdays 07:00–11:00 Europe/Paris | zcode relay `GLM-5.3-Flash` | — | cost lever — **disabled** by default (3× peak metering) |
| `opus` class | zcode relay `GLM-5.3` | — | |
| fallback (catch-all) | zcode relay `GLM-5.3-Flash` | — | no request is ever dropped |

Splash = the local Anthropic-protocol server on `127.0.0.1:8000` (default
model `mlx-community/Qwen3.8-27B-4bit`). Splash down? The haiku rule's relay
backup serves the request automatically.

## Quota

- ZGate polls the zcode billing endpoints every 30 minutes and after every
  25 relayed requests; thresholds: warning ≤ 25% remaining, critical ≤ 10%.
  The same values feed `quota below X%` rule conditions (Settings → Rules).
  Thresholds are fixed in this build.
- **Current state: fail-open.** Today the billing endpoints return no balance
  numbers for this account (`balance` rejects the reconstructable request
  form; `current` returns empty plans), so ZGate holds no quota snapshot:
  the menu bar shows bare `ZΓ`, quota-gated rules are skipped, and routing is
  completely unaffected. If/when the endpoints serve data, the bar and
  percentage go live with no config change. Last-known values are kept and
  dimmed when a poll fails while data exists.

## Verify install

- [ ] `ZGate.app` runs from `/Applications` (release build above)
- [ ] **No dock icon** (LSUIElement menu-bar app) and a **`ZΓ` item is present
      in the menu bar**
- [ ] The popover's env line shows `http://127.0.0.1:<port>` and
      `ANTHROPIC_BASE_URL=http://127.0.0.1:<port> claude --model glm-5.3 "say OK"`
      answers `OK` through the signed relay (full E2E proof:
      [`docs/e2e-checklist.md`](docs/e2e-checklist.md))
- [ ] Settings → General: **Launch at Login** toggle works — ZGate appears
      in/disappears from System Settings → General → Login Items
- [ ] Quitting from the popover leaves no listeners behind
      (`lsof -nP -iTCP:<port>` is empty)

## Data & config

- Config: `~/Library/Application Support/ModelProxy/config.json` (directory
  name kept from upstream), token stats + quota history alongside.
- Logs: same directory when file logging is enabled (Settings → Debug);
  never contains bodies or credentials.

## About / attribution

- **model-proxy** by norvyn — MIT; this fork's `LICENSE` is upstream's.
  Original README: [`README.upstream.md`](README.upstream.md).
- **Splash** local target — `splash-m1` Anthropic-protocol server on
  `127.0.0.1:8000`.
- End-to-end proof against the live signed relay:
  [`docs/e2e-checklist.md`](docs/e2e-checklist.md).
- Working notes for the fork: [`docs/zgate-notes.md`](docs/zgate-notes.md).

# Changelog

User-facing changes to ZGate. Dates below are authoring dates. Version
numbers follow `marketing.build` (e.g. 2.6.4 = CFBundleShortVersionString
2.6, CFBundleVersion 4).

## [2.7.6] — 2026-11-18

### 2026-11-18 — login flow: visible status, in-app sign-in, auto-renewal

- **Credential status is always visible**: the popover has a credential
  row (green "signed in · N min left", amber "renewing" /
  "degraded (unsigned)", red "login expired — sign in") and the menu-bar
  icon gains a badge when action is needed. Settings → General has a
  Credentials section (Advanced keeps the raw event log).
- **Sign in from the app**: the red row's Sign In button opens the
  browser for z.ai approval and picks the session up live — no terminal
  command, no app restart (the old copyable command remains as a
  fallback).
- **Automatic renewal**: a background keeper re-mints the plan token
  ~2 min before each ~52-min expiry (and on wake), so the ladder stays
  alive while ZGate runs; failures back off instead of looping.
- **Shared credential store**: ZGate now reads the same `~/.zcode`
  store the ZCode GUI/CLI keep fresh — a GUI re-login heals a running
  ZGate on the next request. The isolated scratch store remains
  selectable in Settings.
- **Hot pickup**: refreshed logins (in-app, GUI, or CLI) are adopted by
  the running app; dead cached sessions are invalidated instead of
  retried.
- **Test-host isolation**: running the test suite can no longer mutate
  production config/credential state (the 2026-11-18 incident class).

## [2.6.5] — 2026-11-18

### 2026-11-18 — TTFT columns, cache-read stats, ZGate data dir

- Recent Requests shows TTFT (first relayed byte, seconds) and decode
  speed (tok/s over the streaming window) instead of raw milliseconds;
  column headers align with rows (scrollbar no longer shifts them).
- Statistics splits input into fresh vs cache-read per model — the
  cache-read share is the compaction-discipline lever under the
  cache-reads-bill-as-input doctrine.
- App-support directory renamed `ModelProxy` → `ZGate` (one-time move at
  launch; a pre-rename app re-seeds defaults).
- Feedback address is the fork owner's; credits list this repo.

## [2.6.4] — 2026-11-18

### 2026-11-18 — post-2.6(3) fixes: splash port, qwen levers, signing, UI polish

- Splash port is configurable (Settings → Splash; changing it restarts the
  server) and moved off 8000 — the new default is **8123**, which stops
  colliding with common local webservers. Existing configs migrate once;
  hand-edited ports survive. Managed servers bind it via `--port`.
- Two DISABLED qwen routing rules ship in the default matrix (haiku and
  sonnet → splash `local/qwen3.8-27b-q8`, relay-Flash failover): enabling
  one in Settings → Rules takes that tier local in a single toggle.
- Listener port numbers no longer render with thousands separators
  ("8,787") on the Advanced tab.
- The popover's Recent Requests section renders ~8 rows tall (was
  collapsing to one).
- Release builds are signed with a Developer ID Application certificate
  (hardened runtime on) and `scripts/notarize.sh` submits + staples them.

### 2026-11-17 — clean tier routing (v2.1)

- Routing matrix v2.1: all deliberate work (opus- and sonnet-class) maps to
  relay `GLM-5.3`; the haiku tier rides the fast relay tier `GLM-5.3-Flash`.
- Local qwen (splash) is off every default route — quality ruling, not a
  cost one.
- The two peak twins (weekdays 07:00–11:00 Paris → Flash) stay in the
  matrix but ship disabled — a dormant cost lever, one toggle to re-enable.
- One-time config migration retargets existing live configs to the same
  matrix and persists at first launch (idempotent; configs showing user
  edits are left alone).

### 2026-11-17 — Package C: splash lifecycle management

- Saved named splash launch profiles, managed in a new Settings section.
- Supervised splash child lifecycle: readiness polling, crash backoff
  (1 s → 60 s), adopted-instance takeover (a splash already running is
  adopted, not duplicated), in-memory log ring.
- Chip-gated installer: M1/M2 get the splash fork binary (with an
  Application Support fallback when the install location denies writes);
  M3+ installs via brew.
- `/v1/models` discovery client — splash capabilities are read at runtime
  instead of assumed.
- Config migrations, idempotent on every launch: existing configs get the
  auto-class peak-twin rule inserted, and the splash settings section is
  seeded; fresh installs already carry both.
- App wiring with test-context suppression — a test-hosted ZGate never
  starts a second splash (the machine can only run one).

### 2026-11-16 — wave 1: quota display + routing hardening

- Per-window quota rows (weekly / 5-hour / MCP) with reset countdowns in
  the popover.
- More comfortable type scale in the popover (caption2→caption,
  caption→footnote).
- Opus peak-hours rule (route opus-class to `GLM-5.3-Flash` 07:00–11:00
  Paris weekdays) enabled by default.
- Routing hardening: 429 fail-open follows the rate-limit policy;
  `isLocalTarget` excludes passthrough; catch-all encoded only when true.

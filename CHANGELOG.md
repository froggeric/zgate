# Changelog

User-facing changes to ZGate. Dates below are authoring dates. Version
numbers follow `marketing.build` (e.g. 2.6.4 = CFBundleShortVersionString
2.6, CFBundleVersion 4).

## [2.8.9] — 2026-11-19

### 2026-11-19 — Fresh-install login: the ready payload parses, the setup state is honest

- **The in-app login completed in the browser but could never finish in
  the app.** The ready answer from the OAuth poll nests the access token
  under the provider key (`data.zai.access_token` — the CLI's own parser
  shape, re-verified against the shipped `ZCode.app` bundle), which
  ZGate's parser never read: every genuine "ready" was treated as "keep
  polling", so the chip sat on "authorizing…" for the full 300 s window
  and fell back to the sign-in state even though the browser
  authorization had succeeded. Machines with an existing login never run
  the flow — only fresh installs hit it. The parser now reads the
  provider-nested token (both key spellings, CLI parity), and the test
  fixture — a self-consistent synthetic pair that passed CI while
  production login could not succeed — now pins the real wire shape.
- **Expired sign-in windows fail fast instead of burning in silence.**
  Once a login flow passes its server-side expiry (300 s), the poll
  endpoint answers 400 `invalid_flow` (live-verified); the loop tolerated
  every non-200, so a slow first-browser-login — a fresh machine whose
  browser has no z.ai session yet — hung to the cap with no explanation.
  A permanent 4xx now aborts immediately: "Sign-in window expired —
  retry" for the expired flow, a typed poll error otherwise. 408/429/5xx
  stay tolerated.
- **A successful fresh login now reads "● finish setup in ZCode, then
  Reload" instead of "renewing" forever.** The store the login writes
  carries no project-key location (only a ZCode GUI/CLI login can
  populate it), and the signing chain fails before any network call
  while it's missing — so "renewing" was a promise retrying could never
  keep: the keeper re-seated it every ≤5 min, and after an app restart
  the same machine read green "signed in" until the first keeper
  failure. The face is now derived from the snapshot: a live
  location-less store is action-needed with dedicated copy, and it
  self-clears the moment a GUI/CLI login writes the location — no event,
  no restart. Transient refresh failures over a held session or usable
  cache still read "renewing"; an expired store keeps the expired-login
  red.

## [2.8.8] — 2026-11-19

### 2026-11-19 — Fresh-install login fix, icon-only menu bar, accessible text scale

- **Fresh-install login fixed — two stacked defects.** First, the in-app
  Sign In posted its OAuth init to the wrong origin (`api.z.ai` → nginx
  404): the browser flow had never opened on ANY machine (development
  installs were masked by the 180-day biz-session cache). The origin is
  now the CLI's own `zcode.z.ai/api/v1`, a non-200 init surfaces as
  "Sign-in service unreachable" instead of a bare "client error", and the
  flow is regression-pinned to the CLI base. Second, the shared store
  base was one directory level wrong (`~/.zcode/.zcode/v2` — a path the
  CLI never writes; it writes `~/.zcode/v2`), and CLI logins were
  unreadable anyway: the CLI seals its store with a macOS Keychain secret
  (`enc:v2:os:` envelopes), which ZGate did not know. ZGate now resolves
  the CLI's colocated `credential-secret` file, the legacy `secret.txt`,
  and the Keychain secret — **prompting at most once per login grant**
  (successful reads are cached for the process; a denial is remembered,
  never re-prompted) — and **adopts an existing CLI session as-is**.
  Store writes preserve co-tenancy in BOTH orderings: a login over an
  existing store re-seals it with the store's own flavor (an os-sealed
  CLI store is never re-keyed to a secret file, and keychain
  refusal/unavailability aborts with a typed error instead of
  quarantining a live CLI login), while a ZGate-FIRST login on a virgin
  machine writes the secret to the CLI's own colocated
  `credential-secret` (as a base64url string — a file the CLI resolves
  without env vars), so the CLI keeps working afterwards. Previously that
  path quarantined CLI stores and left the chain location-less (every
  request 502) — and the pre-fix code would have destroyed the CLI login
  on the user's exact fresh-install scenario. The login alert's terminal
  fallback no longer hardcodes dev-machine scratch paths (and follows the
  selected store base), and a machine that never logged in reads "sign in
  to use the relay" instead of a wrong "login expired".
- **The menu bar is icon-only: the ZΓ brand mark now lives inside the
  quota ring.** The `ZΓ 63%` title text is gone; the glyph is drawn
  inside an enlarged ring, shares every ring state (dashed no-data, stale
  dimming), and disappears with the ring whenever a fault symbol
  replaces the icon. The exact percentage remains glanceable in the
  popover and is spoken by the VoiceOver label ("weekly quota N%
  remaining"). Rendering is a deterministic 4x raster (no deprecated
  lockFocus), ink-centered on the glyph's device-metrics box, and pinned
  by geometry + rasterized-ink tests.
- **Accessible text scale.** On macOS, footnote/caption/caption2 are ALL
  exactly 10 pt, and the app's small text was entirely those styles —
  the earlier caption2→caption pass moved nothing. The ladder is now
  tertiary 11 pt (subheadline), secondary 12 pt (callout), primary
  values 13 pt (body — the quota percent and the traffic row's model
  included), across the popover, Settings, every sheet, and both log
  viewers; dense table headers and cells (traffic, statistics, the debug
  log viewer) deliberately hold the 11 pt tertiary floor. The fixed
  widths tuned for 10 pt (popover 400→440 pt, traffic/log columns,
  viewports, the vendor sheet) grew to match, so nothing clips or
  truncates harder.
- **Recent Requests headers can no longer drift off their columns.** The
  column header now lives INSIDE the scroll container as a pinned
  section header (with a material background), so any scrollbar inset
  applies to header and rows alike in every scrollbar state — the old
  outside-the-scroll header sat a gutter to the right of the data on
  machines with persistent scrollbars.
- **tok/s cells show the bare number** ("935", not "935/s") — the unit
  lives in the column header. VoiceOver labels speak the unit only when
  a value exists ("— tok/s" would announce a unit for nothing).

### 2026-11-19 — Apple HIG design pass + the quota ring

- **The menu-bar icon is now a quota ring**: a template ring gauge whose
  arc is your remaining weekly quota (clockwise from 12 o'clock), with the
  `ZΓ <N>%` title kept for the exact number. A dashed ring means "no data
  yet" (never 0%); a dimmed arc means "last known — poll failing". Fault
  states still outrank the ring: pause symbol while paused, hourglass
  while launching, ⚠ on error or when a login is needed. VoiceOver reads
  the whole item as one label ("ZGate, running, weekly quota N%
  remaining"). The ring geometry is unit-tested; rendering was
  pixel-verified at menu-bar size in both light and dark appearances.
- **Accessibility fixes**: icon-only controls meet macOS hit-target
  minimums; Reduce Motion now disables the automatic scroll animations in
  the traffic table and log viewer; the double-dimmed auxiliary traffic
  rows are full-contrast again; the warning-band quota percent renders in
  primary text (yellow digits at 10pt failed contrast); green is reserved
  for process-up status and the quota scale (HTTP 2xx codes no longer
  paint the traffic list green).
- **macOS convention fixes**: the Settings button uses the system
  `SettingsLink` (the manual window-finding dance is gone); all buttons
  use system styles (custom bezels deleted); vendor selection is a real
  pop-up button instead of a fake text field; every edit sheet takes
  Return-to-save / Escape-to-cancel; buttons that open another view carry
  an ellipsis ("Add Rule…", "Add Vendor…", "Sign In…", "Send Feedback…");
  the "Targets" tab is renamed **Vendors** to match everything inside it.
- **Interaction fixes**: a corrupt config.json resets to a session banner
  instead of a launch-time alert; the re-login alert is short (the
  terminal command stays one click away via Copy Command — no more
  transcribing from unselectable alert text); deleting a splash profile
  asks first (with an active-profile warning); the quota refresh button
  shows an in-flight spinner and disables; the Clients port field
  validates visibly and its quick-start command shares the popover's env
  line formatter (same host, same actual bound port); a disabled vendor
  Save now says why next to the field.
- **Dead code removed**: `RoutingTabView.swift` (456 lines of superseded
  editor) and the custom `ButtonStyles.swift`.

### 2026-11-18 — credential store hardening (rides this train)

- **Secret-less store quarantine**: a credential store whose secrets file
  is missing no longer wedges login permanently — ZGate quarantines the
  unusable store and writes a clean one on save, and warns when the saved
  store lacks a project-key location.

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

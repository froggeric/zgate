# Changelog

User-facing changes to ZGate. **Dates below are authoring dates, not release
dates — no version numbers have been assigned yet**, so everything lives
under Unreleased, newest first.

## [Unreleased]

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

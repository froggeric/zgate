# Changelog

User-facing changes to ZGate. **Dates below are authoring dates, not release
dates — no version numbers have been assigned yet**, so everything lives
under Unreleased, newest first.

## [Unreleased]

### 2026-11-17 — Package C: splash lifecycle management (in progress — T8–T11 pending)

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

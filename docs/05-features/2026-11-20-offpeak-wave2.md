# Off-peak wave 2: Settings toggle, automatic status, rule-target routing (2026-11-20)

User-facing behavior of the 2026-11-20 off-peak wave 2 (plan:
`docs/06-plans/2026-11-20-offpeak-wave2-plan.md`). Wave 1 (the manual
`/async/` surface) is described in
[`2026-11-20-relay-fidelity-resilience.md`](2026-11-20-relay-fidelity-resilience.md)
§ "Off-peak async surface" — that surface is unchanged and still available;
this wave adds a Settings face, automatic window status, and routing-rule
integration on top of the same ticket-plane orchestration.

**Billing watch (cardinal):** billing on the ticket plane is UNVERIFIED —
watch the quota monitor (`quota-history-*.json` in Application Support)
across the first auto-routed window before treating it as free.

## Settings surface (General → Off-Peak)

- **"Use ZCode off-peak compute"** toggle plus a live status line
  ("Window open" / "Closed until HH:mm" / "Unavailable (…)"). Applies
  WITHOUT a restart — the toggle flows through `saveAndReload` →
  `updateRouting`, and the availability monitor starts/stops with it.
- **Enabling mints the coding-plan key lazily** via the existing
  fallback-key chain, on the first availability poll (the same minted
  credential the wave-1 surface's control/data planes authenticate with).
- **No advanced knobs in the UI**: `origin`, `maxWaitMinutes`,
  `pollIntervalSeconds`, and `keepaliveSeconds` remain config-file-only
  (the `offPeak` object in `config.json`).

## Availability monitor

While enabled, a monitor polls
`GET /api/v1/off-peak/ticket/availability` every **300 s** (the first poll
fires immediately on enabling); polling stops when the surface is disabled.
The request path never polls — the forwarder reads a cached status, so the
gate adds no request-time call. Status meanings:

| Status | Meaning |
|---|---|
| Window open | the off-peak window is open — gated rule traffic rides the ticket plane |
| Closed until HH:mm | window closed; reopens at the shown local time |
| Unavailable (…) | the poll failed (reason in parentheses); treated as closed for gating |

The popover mirrors the status in a row that renders **only while the
surface is enabled**: "Off-Peak: Window open" (green) / "Off-Peak: Closed
until HH:mm" / "Off-Peak: Unavailable (…)" / "Off-Peak: Checking…" while
the first poll is in flight.

## Rule-target routing

A run-once config migration (**migration 11**) seeds a **"ZCode Off-Peak"
vendor row** (vendorKind `offPeak`). Deletion is respected — once applied,
a user-removed row is never re-seeded. Attach the vendor as a routing
rule's **primary target** to use it. The row's Base URL field is inert for
off-peak targets — the serving origin comes from the `offPeak` config
object, so editing it does nothing.

When a matched rule's primary is the off-peak vendor, the request rides
the ticket plane only when ALL three gates hold:

| Gate | Source |
|---|---|
| Surface enabled | the Settings toggle (offPeak config) |
| Window open | the monitor's cached 300 s status |
| Request has `stream: true` | the inbound request body |

All gates hold → same orchestration as the manual `/async` surface (model
substitution to the rule's target model + GLM canonicalization applied,
then availability wait → take → poll → unsigned data-plane POST → SSE
relay → settle). **ANY gate failure → the rule's backup target serves**
(a relay-kind backup through its own signed ladder; any other kind through
`executeBackupUpstream` with the fallback edge's key lifecycle — lazy key
resolve/mint, 401 re-mint once, 1113 key cooldown — so an edge-vendored
backup with the seeded empty key still serves; final-review fix #2). No
backup — or a backup that is itself an off-peak target — answers an
Anthropic-shaped **503** type `off_peak_unavailable`, message
"Off-peak gate failed (\<the gate that failed\>) and this rule has no
backup target." (final-review fix #3: the terminal names the actual
failed gate — surface disabled / window closed / non-streaming request —
never a hardcoded "window is closed").

**Non-streaming requests NEVER queue.** A non-streaming request on an
off-peak rule always falls back to the backup — it can never receive
`async_stream_required` through a rule and never silently waits in the
ticket queue. (Context: on 2026-11-20 a Claude Code session pointed at
the manual `/async` surface had its compaction fail because that surface
is stream-only — the rule-target design exists so interactive traffic is
never captured unattended.)

Two guards and one bound complete the picture:

- The **rule editor blocks saving** an off-peak primary without a
  NON-offPeak backup target ("An off-peak primary target needs a backup
  target for the closed-window fallback.") — the 503 path is reachable
  only through hand-edited config.
- After orchestration starts there is **no failover-to-backup**: a held
  ticket runs to its `maxWaitMinutes` bound.

## Token stats

Requests served through an off-peak RULE record usage under the ZCode
Off-Peak vendor (Statistics tab). The manual `/async` face records no
token-stats row (the passthrough convention) — its usage shows in the
traffic log only.

History note (final-review fix #5, 2026-11-21): the wave-2 plan's Task 3
originally said "token stats on `/async`". The resolved semantic is the
one above — the manual `/async` face meters NOTHING (it mirrors the
passthrough vendorless convention); only rule-routed off-peak traffic
records stats rows. Do not "restore" the original Task 3 goal without a
fresh decision.

## Colored toggle enabled-states (app AccentColor)

An `AccentColor` asset is now defined (light `#087AFF`, dark `#0A84FF`),
so every toggle's enabled state is colored app-wide — previously the
enabled state inherited the system accent (grey under Graphite).

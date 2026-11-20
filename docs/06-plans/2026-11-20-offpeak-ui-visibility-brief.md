# Wave 2 brief — Off-Peak UI, automatic routing, toggle visibility (DRAFT — awaiting user "continue")

> Status: user requested 2026-11-20 after release 2.10.1: "we need a toggle in the config!
> and the health check + claude use should be automatic, not user driven! also all the
> toggles lack visibility, they are the same grey colour whether enabled or disabled; the
> enabled state need to be coloured. prepare for compaction, then proceed with those when
> i say continue."
> When the user says continue: brainstorm the ONE open design question below (AskUserQuestion),
> then run superpowers writing-plans → subagent-driven-development like wave 1
> (docs/06-plans/2026-11-20-relay-fidelity-resilience-plan.md is the precedent).

## Current state (all verified 2026-11-20)

- Off-peak surface shipped in 2.10.1, default-OFF, **config-only — no Settings UI**.
  Live config currently has `"offPeak": {"enabled": true}` (backup: `config.json.preOffPeak`
  beside it) but it applies only after an app restart.
- `OffPeakConfig` at `ModelProxy/Models/AppConfig.swift:64-88` (Codable, decodeIfPresent —
  partial JSON fine): `enabled`, `origin` (default https://zcode.z.ai), `maxWaitMinutes` 60,
  `pollIntervalSeconds` 5, `keepaliveSeconds` 3. Held on `AppConfig.offPeak` (:140).
- Async context built ONCE at startup: `ProxyServer.swift:311 if offPeakContext == nil`
  (config captured at build; nil'd on stop since the dead-client fix). Hot-reload exists for
  routing/version/edge-target in `updateRouting` (~:474 region) but NOT for offPeak.
- Credential for the plane's `X-Coding-Plan-Api-Key` header: `credentialProvider: { await
  health?.fallbackKey() }` (ProxyServer.swift:322) — lazily mints via the /copy chain on
  first use. Availability requires this header (probe D: 3001 without it).
- Local routes: `POST /async/v1/messages` (stream-only), `GET /async/v1/health`. Usage today:
  manual — `ANTHROPIC_BASE_URL=http://localhost:8787/async claude` for one session.
- Server-driven window: `GET /api/v1/off-peak/ticket/availability` → `can_take_number` +
  `next_take_at` (window was OPEN at 17:43Z on 2026-11-20).
- Open verifications riding this wave: probe-D phase-2 billing (watch quota monitor on first
  real run) and **TokenStatsStore wiring** (off-peak usage currently traffic-row-only — final
  review conditioned this BEFORE real use; auto-routing makes it real, so it moves INTO scope).

## Item 1 — Settings toggle for Off-Peak

- New section in the SwiftUI Settings scene (follow existing section patterns in
  `ModelProxy/Views/`): Off-Peak enabled toggle + status line (see item 2) + optionally the
  advanced knobs (origin/maxWait/poll/keepalive) — decide in brainstorm; default minimal
  (enabled + status only).
- **Must apply WITHOUT restart** (the current restart requirement is part of what the user is
  unhappy about): extend `ProxyServer.updateRouting` to rebuild `offPeakContext` when
  `config.offPeak` changes (mirror the version-pin/edge-target push pattern; the stop/start
  fix already proved rebuild is safe — in-flight orchestrations cancel on channel close).

## Item 2 — automatic health check + claude use (ONE design question for the user)

- **Automatic availability status (uncontroversial):** when enabled, background-poll
  availability at a bounded cadence (suggest 5 min; first poll triggers the lazy key mint —
  confirm user is OK with mint-on-toggle) and surface the result: menu-bar popover line
  and/or Settings status ("window open" / "closed until HH:MM" from `next_take_at`). Bounded,
  fail-open, no polling when disabled.
- **Automatic Claude use — the open question.** Recommended: an **Off-Peak routing target** —
  a new target kind on routing rules so the user attaches off-peak to a rule (e.g. a
  dedicated batch model name or the haiku tier), and matching traffic rides the ticket plane
  automatically when enabled+available, with automatic fallback to the rule's normal target
  when the window is closed. Alternatives: (a) global "night mode" that re-routes a chosen
  tier while the window is open; (b) keep /async manual and only automate the STATUS. Ask
  ONE AskUserQuestion at continue-time with these options; do not guess — interactive
  traffic must never silently land on a minutes-long ticket queue.
- Include TokenStatsStore wiring + a first-run quota-watch note in whatever option builds
  real traffic (billing unverified).

## Item 3 — toggle visibility (enabled state must be coloured)

- All toggles in the app (Settings + popover) currently render the same grey on and off.
  Sweep `grep -rn 'Toggle(' ModelProxy/Views/` and make the ON state visibly colored
  app-wide — likely `.tint(.accentColor)` (or green) on switch-style toggles, or a shared
  toggle style helper if the app uses custom styles. Check first WHY they are grey
  (custom toggleStyle vs checkbox style vs forced gray) — the apple-design skill is
  available for a pass on the chosen treatment; keep the change consistent, not per-view ad hoc.

## Execution notes

- Repo: /Volumes/ssd/github/zgate, on main, working tree clean at 042fba9 (plus this brief).
- Test target: ZGateTests (sources in ModelProxyTests/). Full suite currently 772 green.
- Two known pre-existing test-flake classes (RouterTests port-race; OffPeakTargetTests under
  load) — documented in wave-1 history; re-run solo before blaming a change.
- Wave-1 precedent + conventions: docs/06-plans/2026-11-20-relay-fidelity-resilience-plan.md.

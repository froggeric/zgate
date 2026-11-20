# ADR: Relay fidelity — endpoint discovery, failure philosophy, session identity

**Date:** 2026-11-20
**Status:** Accepted (probe-A outcome folded in — pre-routing pin reverted same day)
**Issue:** how closely ZGate mirrors the official zcode CLI's wire behavior, and what happens when pieces of the plane fail

## Context

The relay path (ADR: 2026-11-15 direct-endpoint connection) worked but
diverged from the official CLI in observable ways: the request face was
assembled from a static capture, sessions were process-global, and every
upstream failure was terminal for the request. The 2026-11-20 wave
(`docs/06-plans/2026-11-20-relay-fidelity-resilience-plan.md`) closed those
gaps; this ADR records the three behavioral decisions and the live evidence
behind them (full probe transcripts: `docs/signing-notes.md` § Task-11).

## Decision 1 — Endpoint discovery mirrors the CLI's lazy cadence, fail-open

`agent/configs` is consulted lazily per request (300 s success TTL / 30 s
failure cooldown / 3 s whole-exchange bound / 256 KiB body bound /
single-flight), exactly the CLI engine's numbers — never a timer. Every
failure mode (fetch error, timeout, invalid payload, no match) leaves the
request's URL untouched: endpoint routing can never be the reason a request
fails.

**Evidence:** the CLI bundle (zcode.cjs 0.17.1) has no polling timer —
refresh rides the request path. Live probe A: the table maps the public api
hosts into the relay and carries NO entry for the CLI's baked-in
pre-routing URL (`zcode-plan/anthropic`); a pin there fails open to itself
and the relay 401s it 4/4, while the identical signed face against the
resolved `ultra-zai` target answers 200. Consequence (revert, same day):
the vendor pin stays the RESOLVED ultra URL; routing still engages for
whatever the table maps.

## Decision 2 — Degraded is a serving state, never terminal

Failure handling follows one philosophy: classify precisely, retry only
what the semantics allow, and keep serving through outages.

- Business codes (parsed JSON only) decide retry/no-retry (taxonomy in the
  feature doc); a 401 ladder rebuilds the signing chain exactly once;
  connect-phase failures get a 2-step retry ladder.
- A transport- or signing-class failure flips `RelayHealth` into
  `degradedSigning` with a half-open probe (60 s base, doubling): while
  degraded, class-routed requests are served DIRECTLY by the fallback edge
  vendor (a signing-free `api.z.ai/api/anthropic` credential minted on
  demand) instead of failing. No-launder: the edge is never used to push a
  request past an upstream 401. A credentials-expired outcome serves the
  same fallback WITHOUT probing — relay health stays untouched (recovery is
  an interactive re-login, and a successful re-login resets health).
- Evidence for the edge: the API-key fallback plane is a real
  Anthropic-compatible surface (billing/monitor endpoints live-verified
  2026-11-16; the mint chain is the same z/login → biz JWT chain the relay
  uses). Live probe A exercised the degraded path end to end: an
  expired-credentials outcome logged the direct degraded serve attempt; the
  mint itself failed only because the login chain was down at that moment —
  the machine, not the outcome, is the decision.

## Decision 3 — Session identity is per-conversation, CLI-`sess_`-shaped

ONE derived identity per exchange (from the inbound Claude Code session
header — read, never forwarded) feeds `x-session-id`, the PoW input and the
Ed25519 signature message. This mirrors the official client's per-conversation
`sess_` semantics (its session ids are `sess_`-scoped conversation ids, not
process ids), which the server can observe in all three places at once.
Garbage/absent inbound headers fall back to a per-process id; subagent-typed
requests keep their type through the fallback.

## Alternatives considered

- **Timer-based endpoint polling** — rejected: the CLI does not do it, and a
  timer burns quota-window traffic while idle.
- **Block-or-fail on mapping unavailability** — rejected: fail-open is the
  CLI's behavior and the only policy that cannot regress availability.
- **Terminal 502 on signing outage** — the pre-wave behavior; rejected this
  wave in favor of the degraded serve (the user's traffic keeps flowing on
  the edge while the signed ladder recovers half-open).
- **Process-global session id** — the pre-wave behavior; rejected: the
  server sees the trio (header, PoW, signature) and a stable id across
  conversations is a fidelity tell.

## Consequences

- Five request transforms are now documented routing-compatibility
  transforms (feature doc table) — the content-modification constraint's
  allowlist grows by exactly these, each byte-preserving outside its field.
- The off-peak async surface (Task 10) rides the same identity/auth
  material on a deliberately UNSIGNED plane (control + data) — a separate
  decision recorded in its own file headers (`OffPeakTarget.swift`,
  `OffPeakTicketClient.swift`).

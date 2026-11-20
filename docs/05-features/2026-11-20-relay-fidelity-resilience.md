# Relay fidelity & resilience wave (2026-11-20)

User-facing behavior of the 2026-11-20 wave (plan:
`docs/06-plans/2026-11-20-relay-fidelity-resilience-plan.md`; decisions:
`docs/03-decisions/2026-11-20-relay-fidelity-endpoint-and-failure.md`; live
wire evidence: `docs/signing-notes.md` § "Task-11 live probes"). Everything
here is relay-path behavior — mapped vendors (DeepSeek-style) and passthrough
clients are untouched.

## The five documented routing-compatibility transforms

The relay path performs exactly these request transforms (documented
routing-compatibility transforms — nothing else in the body is modified, per
the project constraint):

| # | Transform | Where | Behavior |
|---|-----------|-------|----------|
| 1 | Model canonicalization | `RelayTarget.canonicalModel` (`ModelProxy/Proxy/RelayTarget.swift`) | The top-level `model` is rewritten to the GLM-canonical wire name with a byte-preserving splice: retired GLM names map to the current main/flash model, unknown `glm-*` names map to the main model, unknown names to flash. Byte-identical when already canonical. |
| 2 | Provider-prefix strip | same | A provider prefix on the rule target (`anthropic/`, `zai/`, `glm/`, …) is stripped before canonicalization — one layer per plan-snippet semantics. |
| 3 | `max_tokens` clamp | `ProxyForwarder.clampMaxTokensField` | A top-level out-of-range `max_tokens` is clamped into `[1, 131072]` before send (the relay 400s code 1210 otherwise). Byte-identical when absent or in range. |
| 4 | Session derivation | `RelayTarget.SessionIdentity.derive` | ONE per-conversation identity derived per exchange from the inbound Claude Code session header (read, never forwarded) feeds everything upstream: `x-session-id`, the PoW challenge input, and the Ed25519 signature message — mirroring the official CLI's `sess_` semantics. Subagent-typed headers keep their type; a garbage or absent header falls back to a per-process id (subagent-typed when the request looks like one). |
| 5 | Endpoint routing | `EndpointConfigService` / `EndpointMapping` (`ModelProxy/Services/`) | The request URL is resolved through the server's `agent/configs` snapshot (see below). Fail-open: a failed, slow, invalid or missing snapshot never blocks or fails a request — the pinned URL serves. |

## Endpoint discovery (`agent/configs`)

`GET https://zcode.z.ai/api/v1/agent/configs` is refreshed lazily per
request-path consultation — the CLI's cadence, not a timer: 300 s success
TTL, 30 s failure cooldown, 3 s whole-exchange bound, 256 KiB body bound,
single-flight dedupe. The mapping table (live, 2026-11-20) contains two
entries, both mapping the PUBLIC api hosts into the relay:

- `https://api.z.ai/api/anthropic/v1/messages` → `https://zcode.z.ai/api/v1/ultra-zai/anthropic/v1/messages`
- `https://open.bigmodel.cn/api/anthropic/v1/messages` → `https://zcode.z.ai/api/v1/ultra/anthropic/v1/messages`

**The relay vendor's pinned URL is the RESOLVED ultra target**
(`…/ultra-zai/anthropic`). The wave first pinned the CLI's pre-routing URL
(`…/zcode-plan/anthropic`) expecting the mapping to rewrite it; live probe A
showed the table carries no such entry and the relay 401-rejects that URL
deterministically, so the pin was reverted the same day (migration 9 heals
any config the interim build repinned). Because the pin equals a mapping
`to` value, `resolve` leaves it untouched and the request serves as-is —
routing still engages for any future table that maps the pin.

## Failure philosophy: degraded, never terminal

- **Business-code taxonomy** (`RelayErrorTaxonomy`): non-2xx bodies and
  JSON-200 carriers are classified from parsed JSON only — quota
  (1005/1113/1310, 402) never retries and ticks the quota poll; rate limits
  (1302/1303, bare 429) retry once after a backoff; concurrency
  (3008/3009/3010) retries twice in place; risk control (3012, 405) never
  retries; captcha (3007), model (3006) and parameter (1210/3001) errors
  surface as-is.
- **401 ladder:** one passed-through first 401; two consecutive rejects
  force one chain rebuild + one signed retry; a still-failing rebuild may
  try ONE unsigned attempt only if a signed chain had been established in
  the process. Never-launder: the fallback edge is never used to bypass a
  401.
- **Degraded machine** (`RelayHealth`): transport-class failures or a
  credentials-expired outcome enter `degradedSigning` with a half-open
  probe cadence (60 s base, doubling backoff). While degraded, class-routed
  requests serve the fallback edge vendor DIRECTLY (the rule's backup keeps
  its own semantics) — degraded is a serving state, not a terminal one.
  Recovery is automatic (a successful probe or served request restores the
  signed ladder).
- **Connect-retry ladder:** connect-phase transport failures retry twice
  (500 ms, then 1 s backoff) before surfacing.
- **API-key fallback edge:** a signing-free `api.z.ai/api/anthropic`
  credential is minted on demand (run-once config seeding; the minted key
  persists through the app layer). No-balance (1113) cools the key for 1 h
  without touching the relay machine.

## Session identity

See transform 4. The official CLI derives a per-conversation `sess_`-scoped
identity from its own session state; ZGate derives the equivalent from the
Claude Code session header the client already sends. The store's own
identity material is never reused across conversations.

## Version tracking

`VersionPinService` polls `client/configs` (6 h cadence) for the server's
`forceUpdate.minimalVersion` and bumps the impersonated CLI version
(greater-only) across the four version surfaces (UA input,
`x-zcode-app-version`, `x-client-version`, sig-message version), persisting
through the app layer. Live-observed 2026-11-20: the server bumped
`0.17.1 → 3.5.3` and the relay accepted the 3.5.3-stamped face on the very
next request. Silent on every failure — the current pin keeps serving.
Known follow-up: `EndpointConfigService`'s own fetch headers still carry the
bundled default (a fifth version surface; recorded in signing-notes).

## Off-peak async surface (default OFF)

An opt-in surface for ZCode's Off-Peak / Idle Plan ticket queue — batch
generation at off-peak rates through the SAME relay identity.

- **Default OFF:** `offPeak.enabled == false` (absent config = disabled).
  Every `/async/` request then answers a local Anthropic-shaped 404-style
  error and contacts NOTHING. `GET /async/v1/health` answers
  `{"enabled": …}` locally at all times.
- **Usage:** point a batch harness at the async route family of any client
  port — `ANTHROPIC_BASE_URL=http://localhost:<client-port>/async` (e.g.
  `http://localhost:8787/async` for the default Claude Code client) — and
  POST `/v1/messages` with `"stream": true` (stream-only; `stream != true`
  is rejected pre-flight with `async_stream_required`, before any
  ticket-server contact).
- **Ticket lifecycle** per request: availability wait → take → poll (SSE
  `": keepalive"` comments flowing while queued, stopping the instant the
  data plane answers) → unsigned data-plane POST
  `{origin}/api/v1/off-peak/anthropic/v1/messages` with
  `X-Off-Peak-Ticket-ID` → byte-untouched SSE relay → settle (fire-and-forget,
  idempotent; fires on completion, error and client disconnect).
- **Unsigned plane:** the ticket control plane and data plane never carry
  the V4 signing quartet, `x-app-id` or `x-api-key`. Auth is the zcode plan
  JWT (`Authorization: Bearer …`) + `X-Coding-Plan-Api-Key` (the Task-7
  minted credential) on every call.
- **Bounds:** availability+queue wait ≤ `maxWaitMinutes` (default 60);
  control-plane tolerance 3 consecutive failures → 529-shaped abort;
  data-plane read timeout `maxWait + 30 min`; pre-flight body bound 4 MiB.
- **Live status (probe D, 2026-11-20):** the control plane answers a
  well-formed availability envelope with the plan JWT (the
  `X-Coding-Plan-Api-Key` header is a required parameter — its absence is a
  400 `parameter error`, any non-empty value passes availability). The full
  round-trip awaits the first real minted key; weekly-quota non-movement
  must be confirmed by the user's own monitor when it runs.

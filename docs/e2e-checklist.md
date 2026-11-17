# ZGate E2E checklist (spec §Verification 4–5)

Executor-run end-to-end proof, 2026-11-16 (02:02–02:29 CET). The GUI-bound
steps live in `scripts/e2e/zgate-up.sh` / `zgate-down.sh` (build the isolated
app, swap in the default rule table + seeded signing cache, launch, click the
status item); `ModelProxyTests/E2E.smoke.swift` (`ZGATE_E2E=1`, forwarded with
the `TEST_RUNNER_` prefix through xcodebuild) drives the real `claude`
invocations and asserts on the app's on-disk request log and persisted
artifacts.

## Run book

```bash
scripts/e2e/build.sh                 # isolated app copy (bundle local.zgate.mac.e2e)
scripts/e2e/zgate-up.sh              # default rule table, port 8787, signing cache seeded
cp docs/e2e-checklist.md "${TMPDIR%/}/zgate-e2e/e2e-checklist.md"   # see note below
# splash provisioning (AC2 up-half) RETIRED with ac2a under v2.1 — nothing
# in the harness touches splash; the AC2 section below keeps the pre-v2.1
# evidence for history.
TEST_RUNNER_ZGATE_E2E=1 TEST_RUNNER_ZGATE_E2E_PHASE=A \
  TEST_RUNNER_ZGATE_E2E_CHECKLIST="${TMPDIR%/}/zgate-e2e/e2e-checklist.md" \
  xcodebuild -project ZGate.xcodeproj -scheme ZGate -destination 'platform=macOS' \
  test -only-testing:ZGateTests/E2ESmokeTests
# then the Phase B half (v2.1: no E2E test touches splash — ZGATE_E2E_SPLASH
# and the splash provisioning above were retired with ac2a; left visible for
# pre-v2.1 history):
TEST_RUNNER_ZGATE_E2E=1 TEST_RUNNER_ZGATE_E2E_PHASE=B \
  TEST_RUNNER_ZGATE_E2E_CHECKLIST="${TMPDIR%/}/zgate-e2e/e2e-checklist.md" \
  xcodebuild … -only-testing:ZGateTests/E2ESmokeTests   # (as above)
scripts/e2e/zgate-down.sh            # kill app, restore the live Application Support
```

The checklist copy is staged into `$TMPDIR` because the repo sits on a
removable volume: a headless test host's `open()` on `/Volumes/ssd/...`
blocks forever in the removable-volume TCC check (found the hard way — two
runs hung in `open()` on this very file). Only AC4 reads it, and only the
staged copy is touched.

Environment observed this run: app pid 94255, listeners `127.0.0.1:8787`
(Claude Code) and `:8789` (Codex); 8788 (zbridge, live traffic) untouched
throughout. Signing chain rebuilt from the seeded biz session — no z/login
(the scratch store's OAuth token is expired, 1 h TTL):

```
[02:02:37] [proxy] INFO  [ProxyServer] Relay signing context ready (relay vendor configured)
[02:02:37] [proxy] INFO  [ProxyServer] Claude Code listening on 127.0.0.1:8787
```

## AC1 — signed relay round trip

- [x] `ANTHROPIC_BASE_URL=http://127.0.0.1:8787 claude --model glm-5.3 "say OK"` → `OK`

Isolated `claude -p "say OK" --model glm-5.3` (own `CLAUDE_CONFIG_DIR`, dummy
API key, nothing inherited) answered exactly `OK`. App request log:

```
[02:26:09] [proxy] INFO  [Proxy] [6812DEDD] POST /v1/messages?beta=true model=glm-5.3 mapped → zcode relay → https://zcode.z.ai/api/v1/ultra-zai/anthropic body=46498B …
[02:26:10] [proxy] DEBUG [Proxy] [6812DEDD] Response: 200 OK model=glm-5.3 vendor=zcode relay 894ms
```

A 200 from the zcode relay only happens with the V4 signing quartet — the
relay 401s valid tokens unsigned (Task 5's live finding), so the 200 proves
the signed ladder served the request. Token stats recorded the serving
target: `GLM-5.3` under the relay vendor.

## AC2 — haiku class: relay flash tier (v2.1); was splash local + fallback

**v2.1 (2026-11-17):** no default route touches splash — glm-5.3-flash maps
directly to relay `GLM-5.3-Flash` (pinned by the live-config test and by
`ac2b` in PHASE=B). Everything below this banner is the pre-v2.1 record of
the splash-up/down behavior, kept as history; do not provision splash for it.

- [x] Splash UP: haiku-class request goes local (live-verified 2026-11-16 — see below)
- [x] Splash DOWN: same request falls back to GLM-5.3-Flash

Same `claude -p "say OK" --model glm-5.3-flash` with splash down. Wire
evidence — the request took the haiku rule (splash primary), splash refused
the connection, and the SAME request ID was served 200 by the relay:

```
[02:28:28] [proxy] INFO  [Proxy] [A80E7C0E] POST /v1/messages?beta=true model=glm-5.3-flash mapped → splash (local) → http://127.0.0.1:8000 body=46513B …
[02:28:38] [proxy] ERROR [Proxy] [A80E7C0E] Local target upstream error for splash (local): connection reset (error set): Connection refused) (errno: 61)
[02:28:39] [proxy] DEBUG [Proxy] [A80E7C0E] Response: 200 OK model=glm-5.3-flash vendor=zcode relay 11096ms
```

(An identical earlier run — request `42CBFF66`, 10821 ms — exercised the same
path.) Popover TrafficLog (Task 9's request log, screenshot readback) names
the serving target: row `02:28:40 | main → GLM-5.3-Flash | … | — | 200`,
splash health chip `⚠ splash n/a`, env line
`export ANTHROPIC_BASE_URL=http://127.0.0.1:8787`.

**Splash-up half — RESOLVED 2026-11-16 (live, owner's production splash).**
The E2E harness's own download of the 4-bit MLX checkpoint had stalled (three
frozen blob transfers); the owner instead runs splash with their GGUF q8
quant (the README's verbatim command — `local/qwen3.8-27b-q8` from a local
model dir). With that server up, the post-reinstall verification sent real
haiku-class requests through the live app: the log shows
`mapped → splash (local)` and `Response: 200 … vendor=splash (local)`, the
splash chip `✓`, and the fallback half above was verified separately the
same way. The route is proven in production daily use, which is the stronger
form of this check. (Historical note: the stall itself was real — a ~16 GB
download froze at ~3.8 GB and was killed; pre-downloading weights before
Phase A remains the advice for anyone re-running the harness's splash half.)

## AC3 — streaming tool-use conversation through the proxy

- [x] one real Claude Code tool round-trip completes

`claude -p "Read notes.txt … reply with exactly the marker line"` with
`--allowedTools=Read` (equals form — `--allowedTools` is variadic and swallows
a following positional prompt) and a fresh canary file. The reply contained
the canary verbatim — impossible without the Read tool actually executing —
and the log shows the two-turn relay round-trip (second turn carries the
tool_result and signed thinking, `signature=true`):

```
[02:26:09] [proxy] INFO  [Proxy] [D0EAA2F8] POST /v1/messages?beta=true model=glm-5.3 mapped → zcode relay … body=46597B … thinking=true signature=false
[02:26:10] [proxy] DEBUG [Proxy] [D0EAA2F8] Response: 200 OK model=glm-5.3 vendor=zcode relay 861ms
[02:26:12] [proxy] INFO  [Proxy] [175F6F29] POST /v1/messages?beta=true model=glm-5.3 mapped → zcode relay … body=47200B … thinking=true signature=true
[02:26:13] [proxy] DEBUG [Proxy] [175F6F29] Response: 200 OK model=glm-5.3 vendor=zcode relay 815ms
```

## AC4 — metering ratio — EXECUTED 2026-11-16 (self-serve, API instruments)

**Conclusion: the 2/3 relay-metering ratio is not verifiable from any
API-accessible surface.** The zcode relay's metering lives in the
zcode-plan ledger (`zcode.z.ai/api/v1/zcode-plan/billing/*` — still
400/3001-dead in every request form), not in the api-key monitor. What the
controlled experiment established (values approximate; exact counts withheld
from this committed file):

- **Monitor `model-usage` = RAW token counters** on both paths. A paired
  direct-vs-relay probe of near-identical small payloads produced a counter
  delta exactly equal to the SUM of both responses' usage — to the token.
  Raw telemetry, no metered value, both surfaces included.
- **Monitor quota windows track ONLY direct usage.** A controlled direct
  burn of ~2M raw tokens moved the 5-hour window +2 pct within a minute
  (⇒ ~1M value per pct on that window; weekly window unmoved — too large or
  lazily updated). A relay burn through ZGate moved nothing, and the
  afternoon's observational evidence agrees: many tens of millions of raw
  relay tokens (a full day of heavy relay routing) produced ZERO visible
  movement in either window while direct probes moved them immediately.
- **Therefore relay traffic does not draw down the monitor-visible quota** —
  it bills against a separate (inaccessible) ledger. Operationally this
  means heavy relay routing does not visibly consume the api-key quota
  windows; the 2/3 number itself remains the V1–V3 console-derived finding,
  manually checkable in the z.ai web dashboard (user-present step).
- **Bonus finding:** the relay upstream prompt-caches aggressively — a
  repeated identical payload bulk bills at cached rates on repeat calls
  (`cache_read` ≈ the whole prompt). Cost lever: stable repeated contexts
  through the relay are cheap; distinct fillers are required when a test
  needs full-price burns.

Original plan (identical small payload both paths, balance deltas) is
superseded: the balance endpoints that plan assumed are dead (Task 8), and
the working monitor instruments turn out to be raw-only + direct-only as
above.

## AC4 addendum (2026-11-17)

**Correction (2026-11-17, later the same day):** the two "unmetered"
conclusions below — and the "therefore" bullet of AC4 above — are WRONG.
Relay usage IS metered against the same quota windows, with a lazy sync
that can lag hours; the flat window readings were lag plateaus, not
exemption (confirmed by steady ~1 pct/~20 min drain under load). Current
doctrine lives in README §Quota & billing behavior. Everything below this
banner is the morning audit's historical record, kept as-is; where it says
"unmetered", read "metered, with lazy-sync lag".

Follow-up audit closing what the section above left open (full tables in
the usage audit — external, machine-local:
`/Volumes/ssd/github/zcode/docs/usage-audit-2026-11-17.md`; exact counts
again withheld from this committed file; probe report:
`zcode/docs/zcode-plan-billing-probe-2026-11-17.md`):

- **No second ledger exists.** The z.ai web dashboard and the ZCode app
  were user-checked: both surface only the same quota windows the monitor
  API returns. The zcode-plan billing routes
  (`zcode.z.ai/api/v1/zcode-plan/billing/current|balance`) exist — a
  404-discriminator probe distinguishes them from the router's plain 404 —
  but return 401/empty under every CLI credential, and empty under a
  logged-in browser session too. Relay usage is therefore unmetered against
  any user-visible quota; only the raw model-usage counters record it.
- **Relay-unmetered confirmed at scale:** a 23.5M-raw-token relay burst
  (381 calls) landing entirely inside the sliding 5-hour window left it at
  1%, and the weekly window stayed flat through hours of heavy relay
  traffic. (Sharpens the AC4 wording above: not "a separate inaccessible
  ledger" — no user-visible ledger at all.)
- **The earlier "~27M direct flash" gap is decomposed:** mostly Claude Code
  harness background fast-model calls (topic/title/summary — whole-context
  sized, relayed through ZGate, so no transcript rows), plus
  ingestion-timing artifacts and the known deliberate probe burns. Zero MCP
  vision calls occurred.
- **Counter semantics — why three sources disagree:**

  | source | what it counts |
  |---|---|
  | monitor `model-usage` | all server attempts, incl. background + failed |
  | ZGate token stats | streams that reached usage-parse |
  | transcripts | successful messages only (CC re-writes each message once per content block; dedupe by `message.id` is mandatory) |

- **Window mechanics:** the 5-hour window is sliding, not tumbling — reset
  time = oldest in-window usage + 5 h. Monitor hourly buckets are UTC+8
  with 15–45 min ingestion lag; the weekly window syncs lazily in 1-pct
  steps.
- **Minted plan-token TTL measured ≈ 52 min** (fixed server-anchored
  expiry) — not the ≈3 h the zbridge notes assumed.

## Test results (this run)

(Pre-v2.1 run — under v2.1, `ac2a` no longer exists and `ac2b` is
splash-independent; expect one fewer gated test.)
Phase A (splash down): 4 passed, 2 skipped (`ac2a` needs splash up;
`ac2b` is Phase B). Phase B: `ac2b` passed. Offline suite (no env):
319 passed / 0 failed / 8 skipped (2 pre-existing live smokes + these 6
gated E2E tests) — 327 total, 22 suites.

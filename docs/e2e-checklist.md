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
# splash (AC2 up-half): splash-m1 serve --model mlx-community/Qwen3.8-27B-4bit
TEST_RUNNER_ZGATE_E2E=1 TEST_RUNNER_ZGATE_E2E_PHASE=A \
  TEST_RUNNER_ZGATE_E2E_CHECKLIST="${TMPDIR%/}/zgate-e2e/e2e-checklist.md" \
  [TEST_RUNNER_ZGATE_E2E_SPLASH=1] \
  xcodebuild -project ZGate.xcodeproj -scheme ZGate -destination 'platform=macOS' \
  test -only-testing:ZGateTests/E2ESmokeTests
# kill splash, then the fallback half:
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

## AC2 — haiku class: splash local, fallback to relay flash

- [ ] Splash UP: haiku-class request goes local (PENDING — see below)
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

**Splash-up half — PENDING (requires user attention).** What was tried within
the ~10-minute budget: `splash-m1 serve --model mlx-community/Qwen3.8-27B-4bit
--host 127.0.0.1 --port 8000` (README start; binary present at
`/opt/homebrew/bin/splash-m1`, `HF_HOME=/Volumes/ssd/ai/cache/misc` has no
cached copy of the 4-bit checkpoint). The 16.07 GB download stalled at 3.8 GB
with three parallel blob transfers frozen for 3+ minutes; process killed, port
8000 left free. To run this half: pre-download the model once (`splash-m1
serve` finishes preparing weights on a later start), then re-run Phase A with
`TEST_RUNNER_ZGATE_E2E_SPLASH=1`. The app-log assertion is the mirror of the
fallback half: routing line `mapped → splash (local)` and
`Response: 200 … vendor=splash (local)`, splash chip `✓`.

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

## Test results (this run)

Phase A (splash down): 4 passed, 2 skipped (`ac2a` needs splash up;
`ac2b` is Phase B). Phase B: `ac2b` passed. Offline suite (no env):
319 passed / 0 failed / 8 skipped (2 pre-existing live smokes + these 6
gated E2E tests) — 327 total, 22 suites.

# ZGate working notes

Living notes for ZGate work on top of the model-proxy fork. Baseline: upstream commit `7cdad2c` (model-proxy main, 2026-11-15), forked as `zgate-main`.

## Directory map (upstream names kept — source renames are out of scope)

| Plan-style path | Actual on-disk path |
|---|---|
| `ZGate/...` (app source) | `ModelProxy/...` |
| `ZGateTests/...` (unit tests) | `ModelProxyTests/...` |
| `ZGateUITests/...` | `ModelProxyUITests/...` |
| `ZGate.xcodeproj` | `ZGate.xcodeproj` (renamed) |

App source layout: `ModelProxy/App`, `ModelProxy/Proxy`, `ModelProxy/Models`, `ModelProxy/Services`, `ModelProxy/Views`, `ModelProxy/Assets.xcassets`. When a later task says "add `ZGate/Services/Foo.swift`", create `ModelProxy/Services/Foo.swift`.

The **module name is `ZGate`** (follows target name): tests must `@testable import ZGate`. Class names inside sources still carry `ModelProxy` prefixes (e.g. `ModelProxyApp`) — unchanged by design.

## Project identity (set in Task 0)

- Project: `ZGate.xcodeproj`; targets `ZGate`, `ZGateTests`, `ZGateUITests`
- Product: `ZGate.app`, executable `ZGate`, display name `ZGate`
- Bundle ids: app `local.zgate.mac`, unit tests `local.zgate.macTests`, UI tests `local.zgate.macUITests`; e2e harness override `local.zgate.mac.e2e` (`scripts/e2e/env.sh`)
- Entitlements: `ModelProxy/ModelProxy.entitlements` is now an **empty dict** (Task 4, user ruling 2026-11-15: App Sandbox OFF). Xcode 26 re-injects the sandbox from the `ENABLE_APP_SANDBOX` build setting, so that flag is also `NO` in the app target's Debug+Release — the file edit alone is not enough. `Info.plist` is an empty stub — identity keys come from `GENERATE_INFOPLIST_FILE` build settings (e.g. `INFOPLIST_KEY_CFBundleDisplayName`)

## Xcode project format — how to add new Swift files

`project.pbxproj` is `objectVersion = 77` / `preferredProjectObjectVersion = 77` with **`PBXFileSystemSynchronizedRootGroup`** for all three targets. Consequences:

- **New files need NO pbxproj edits.** Drop a `.swift` file into `ModelProxy/` (or a subfolder) and it joins the `ZGate` target automatically; same for `ModelProxyTests/` → `ZGateTests`. There are no per-file `PBXBuildFile`/`PBXFileReference` entries to add.
- The only membership exception: `ModelProxy/Info.plist` is excluded from the app target's compile/resources (it is the `INFOPLIST_FILE`).
- **New SPM dependencies DO require pbxproj edits** (`XCRemoteSwiftPackageReference` + `XCSwiftPackageProductDependency` + `PBXBuildFile` in Frameworks). Prefer Xcode GUI for that, or copy the existing swift-nio entries' shape.
- Target UUIDs (stable, for scheme/scripts): app `993E69E52F5A71A800B382DB`, unit tests `993E69F42F5A71AC00B382DB`, UI tests `993E69FE2F5A71AC00B382DB`.

Shared scheme: `ZGate.xcodeproj/xcshareddata/xcschemes/ZGate.xcscheme`. Its **Test action runs `ZGateTests` only** — the `ZGateUITests` target is empty Xcode template scaffolding (zero test functions) and its runner cannot initialize in an unattended shell ("Timed out while enabling automation mode" — macOS UI-automation consent is not grantable from an agent context; upstream's own docs always ran `-only-testing:ModelProxyTests`). Re-add the UITests testable to the scheme if that ever changes. Nothing was deleted.

## Build & test (verified green, 2026-11-15)

```bash
xcodebuild -project ZGate.xcodeproj -scheme ZGate -destination 'platform=macOS' build   # ** BUILD SUCCEEDED **
xcodebuild -project ZGate.xcodeproj -scheme ZGate -destination 'platform=macOS' test    # ** TEST SUCCEEDED **, 177 tests / 11 suites (Swift Testing), exit 0
```

Machine: Xcode 27.2 (project was created with 26.3 — `LastUpgradeCheck = 2630`), Swift 6.4.2 toolchain, macOS 26.2 arm64. The CoreSimulator version-mismatch warning xcodebuild prints is noise (macOS destination, no simulator involved). First build resolves SPM packages (~1 min).

Language/concurrency settings (matter for new code): `SWIFT_VERSION = 5.0` (language mode 5 on a Swift 6.4 toolchain), `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`, `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES`. Proxy-layer code is async; upstream convention keeps NIO proxy code SwiftUI-free.

SPM packages (top-level): swift-nio 2.95.0 (NIO, NIOCore, NIOHTTP1, NIOPosix), async-http-client 1.32.0. Resolved transitives (22 packages total, see `Package.resolved`): swift-nio-ssl 2.36.0, swift-nio-http2 1.40.0, swift-nio-transport-services 1.26.0, swift-nio-extras 1.32.1, swift-crypto 4.2.0, swift-certificates 1.18.0, swift-log 1.10.1, swift-collections 1.3.0, swift-algorithms 1.2.1, swift-atomics 1.3.0, swift-async-algorithms 1.1.3, swift-service-lifecycle 2.10.1, swift-service-context 1.3.0, swift-system 1.6.4, swift-http-types 1.5.1, swift-http-structured-headers 1.6.0, swift-numerics 1.1.1, swift-asn1 1.5.1, swift-configuration 1.2.0, swift-distributed-tracing 1.4.0.

Deployment target: `MACOSX_DEPLOYMENT_TARGET = 15.6` on all targets (15.7 at project level; target wins).

## Deviations from upstream baseline (all from Task 0, keep in mind for diffs)

1. **Signing is ad-hoc.** Upstream shipped `DEVELOPMENT_TEAM = 2JXYA862GQ` + automatic signing; this machine has none of their identities, so the build failed. All configs now carry `CODE_SIGN_STYLE = Manual`, `CODE_SIGN_IDENTITY = "-"`, `DEVELOPMENT_TEAM = ""` — same recipe as upstream's own e2e `build.sh`. Sandbox entitlements + hardened runtime still work locally. If a real signing identity is ever added, revert these three.
2. **Test imports** updated `@testable import ModelProxy` → `@testable import ZGate` (11 files in `ModelProxyTests/`) — mechanical consequence of the module rename; no test logic touched.
3. **`ModelProxyTests/ModelProxyTests.swift` `hostAppBundleHasExpectedIdentity`** now expects `local.zgate.mac` / `ZGate.app` / executable `ZGate` — this test pins product identity, so it must track the fork identity.
4. **e2e harness** (`scripts/e2e/`) project-identity references updated: `build.sh` (xcodeproj path, scheme, product path), `up.sh`/`down.sh` (executable match strings), `env.sh` (e2e bundle id). Source-derived strings unchanged (app-support dir `~/Library/Application Support/ModelProxy`, `.modelproxy-e2e` marker, `modelproxy-*.log` names — these come from app code and stay ModelProxy).

## Upstream context worth knowing

- Upstream docs tree (`docs/00-AI-CONTEXT.md` is their index); App-Store history in `docs/10-app-store-connect/` (not relevant to the local-only fork).
- Upstream hard constraints (from their CLAUDE.md): proxy must stay pure SwiftNIO, no request/response body logging, localhost-only listeners, SSE chunks forwarded immediately, config in `~/Library/Application Support/ModelProxy/config.json`.
- Pre-existing build warnings: `ResponseRelay.swift` deprecation warnings for NIO `writeAndFlush` — upstream code, not touched.

## Task 4 — SigningClient live smoke (2026-11-15T20:25Z, executor-run)

`SigningClientLiveSmokeTests` in `ModelProxyTests/SigningClientTests.swift` (runs only with
`TEST_RUNNER_ZGATE_LIVE_SMOKE=1 xcodebuild test -only-testing:ZGateTests/SigningClientLiveSmokeTests`
— the `TEST_RUNNER_` prefix is what forwards the env var through xcodebuild into the test host).
Status/ms/lengths only; no credential value is printed or stored.

- **Build 1 — full path** (real scratch store → z/login → mint → handshake):
  z/login `200` in 528 ms, biz JWT 1402 c → mint `200` in 183 ms, project token 463 c →
  handshake `200` in 174 ms, privateCipher 124 c → **Ed25519 key unsealed** (sign/verify
  round trip against the derived public key OK). Biz session persisted to the injected cache
  dir, 0600, fields `{bizJwt, acquiredAtMs, location}` (zbridge-compatible file format).
- **Build 2 — restart on the persisted session** (`store = nil`, so z/login is impossible):
  mint `200` in 168 ms, token 463 c → handshake `200` in 163 ms, cipher 124 c → key OK.
  **z/login requests: 0** — the cached biz session rebuilt the chain without touching the store.

All observed lengths match the wire facts pinned in the task brief (1402/463/124 chars).

### Task 4 wire finding: store location value is an object

Live-checked against the real store (metadata only): the `project-key-location:v1:*` field's
**name** carries the percent-encoded array `["https://api.z.ai","zai",<account>,null,1,"default"]`
while its **value** is the object `{"organizationId":36c,"projectId":37c,"apiKeyId":32c}` —
the mint location. ~~Task 2's `CredentialStore.projectKeyLocation()` parses the value as the
array shape, so it throws on the real store.~~ **Fixed in `b8e7f8c`** — the accessor now parses
the value object (shape-shimmed fixtures), and SigningClient resolves a cold-start location
from the store directly.

## Task 5 — RelayTarget (2026-11-15)

`ModelProxy/Proxy/RelayTarget.swift`: the zcode relay as a forward target (`Vendor.vendorKind
== .relay`). Builds the full header set from scratch (client headers never leak — `anthropic-beta`
is a pinned static, not the client's), rewrites the top-level `model` to the GLM-canonical rule
target via the byte-preserving splice, and signs per request: `x-client-ts/nonce/pow/sig` over
the SigningClient session (stable per-process `x-session-id`, zbridge SESSION_ID parity).
Streaming back stays ResponseRelay's job.

- **Failure policy** (RelayTarget.execute): signing first — cold start waits for the handshake,
  failure is a terminal 502, NEVER an unsigned request (live-verified: the relay 401s valid
  tokens without signing headers). Relay 401 → `noteRelayRejection()`; 2nd consecutive reject →
  one forced chain rebuild + one signed retry; a failing rebuild allows ONE unsigned fail-open
  attempt (auth headers, no signing quartet) but only if a chain had been established in-process;
  terminal 401 paths emit `CredentialEvent.expired`. Relay 429 → one retry after a 1 s backoff,
  then next-rule fallback / 529 (`ProxyForwarder.executeRelay`, same backup selection as the
  plain failover path).
- **Naming note:** the brief's "`CredentialError.expired` event" is implemented as
  `Models/CredentialEvent.swift`'s `CredentialEvent.expired` on a `@MainActor` `CredentialEventChannel`
  (TrafficLog pattern). `CredentialError` is the CredentialStore error enum (Services) — adding a
  case there was outside Task 5's file list; the event type keeps the UI surface in Models.
- **Streaming disconnect:** `ProxyForwarder` step 8 now runs `ResponseRelay.relay` in a child task
  cancelled via `channel.closeFuture` — a mid-stream client disconnect aborts the upstream body
  (AsyncHTTPClient cancels and closes). Without the explicit cancel, the abandoned response body
  does NOT reliably tear the connection down (NIOAsyncSequenceProducer defers deinit-termination
  while elements are buffered). Caveat found while testing: **EmbeddedChannel succeeds writes
  after close** (its `write0` never checks `isOpen`), so disconnect tests must use a real socket
  for the client channel.
- **Relay body is exempt from `sanitizeToolsForVendor`** (byte-unchanged except model, zbridge
  parity), and a relay Vendor's default `replayPolicy` is `.transparent` (the relay is
  Anthropic-protocol end to end; no portable projection).
- **Wiring status:** `ProxyForwarder.forward` takes `relayContext: RelayTarget.Context? = nil`
  (ProxyChannelHandler unchanged). A relay rule reached with no context gets a 502 "no signing
  context configured". Task 6 (Router) constructs the Context (SigningClient + event channel)
  in the server layer and passes it down.
- **Tests** (`ModelProxyTests/RelayTargetTests.swift`, 19): mock relay = local SwiftNIO server
  (scripted responses, chunked SSE with delays, held-open streams, mid-stream disconnect
  counting); signing chain via URLProtocol mock with synthetic JWTs + fixed Ed25519 seed.
  Covers: fixture statics + volatile shapes (sig verified against the fixture public key, PoW
  verified against its identity inputs), model rewrite byte-parity (canonical round-trip), SSE
  byte-identity incl. a split-mid-JSON event, cold start never-unsigned, first-reject
  passthrough, `token expired` → event + no retry, 2-reject ladder (expired + recovery),
  fail-open gate, 429 retry/fallback/529, and full `forward()` integration (200/502/529/backup).


## Task 6 — Conditional router (2026-11-15)

`ModelProxy/Proxy/RouterExtensions.swift` + schema in `ModelProxy/Models/RuleSchema.swift`;
evaluation order extended, not replaced: **exact-match mappings (upstream, untouched) → class
rules in config order (first eligible wins) → terminal catch-all rules → client unmapped
policy** (final safety net; the catch-all normally wins first).

- **Class map** (`ModelClass.classify`): case-insensitive substrings `haiku`→haiku,
  `opus|fable`→opus, `sonnet`→sonnet, `default|^auto`→auto; unset/empty model → auto. CC env
  aliases are first-class: `flash` substring → haiku is checked BEFORE the `glm-5.3` prefix →
  sonnet, so `glm-5.3-flash` → haiku while `glm-5.3` / `glm-5.3[1m]` → sonnet. Unknown names
  classify nil → terminal fallback rule (relay GLM-5.3-Flash in the default table) — a request
  is never dropped for an unmatched model.
- **Rule schema** (`ModelMapping` additions, legacy-tolerant decode): `matchClass: ModelClass?`
  (nil = legacy exact-match on `sourceModel`; for class rules `sourceModel` is a display
  label), `catchAll: Bool`, `conditions: [RuleCondition]?`. `RuleCondition` is the flat spec-§2
  JSON shape (`{"type":"timeWindow","days":"weekdays","from":"07:00","to":"11:00",
  "tz":"Europe/Paris"}` / `{"type":"quotaBelow","percent":20}`). `to` is exclusive; `from > to`
  wraps midnight; `tz` nil = local.
- **Seams for Tasks 7/8** (in RouterExtensions, fakes in tests): `TargetHealthProviding`
  (`lastSuccess(forVendor:) -> Date?`) and `QuotaSnapshotProviding` (`quotaSnapshot() ->
  QuotaSnapshot{fractionRemaining, fetchedAt}`). Conditions evaluate against
  `ConditionContext{now, health, quota}` — `now` injected so tests pin fixed dates.
- **Fail-open semantics:** a condition that cannot be evaluated reads false (rule skipped,
  next rule serves): quota snapshot missing OR older than 2h → `quotaBelow` false (pinned,
  boundary exactly 2h still usable); health seam nil OR vendor never probed → treated healthy;
  a *stale* probe (> 60s old) → primary target unhealthy → rule skipped (boundary exactly 60s
  still healthy). Health gates the rule's PRIMARY target only; backup targets rely on the
  existing failover machinery.
- **Missing model field (fix round 1 precision):** with class/catch-all rules configured, a
  PARSED JSON OBJECT lacking a `model` field routes as class auto (spec §2) instead of the
  legacy 400. Unparseable, empty, or non-object bodies (garbage JSON, bare arrays) are
  answered 400 LOCALLY and never routed — pinned by `unparseableBodiesAnswerLocal400…`.
  Legacy configs (no pattern rules) keep the 400 for both (`RequestRouter`).
- **Failover symmetry (fix round 1):** `targets(for:)` and `updateRouteState(for:)` share
  `firstMatch`'s ELIGIBILITY (conditions + health at call time) — a rule the resolver just
  skipped is never resurrected as a 429-failover candidate, and state writes key by the rule
  that actually served (e.g. the catch-all), not by a skipped class rule. Failover state keys
  by `class:<class>:<vendor>` / `catchall:<vendor>`, so the default table's two opus rules
  (same relay vendor) share one state key — read and write agree.
- **Default rule table** (`AppConfig.makeZGateDefaultRouting`, called by `makeDefault()` —
  first launch only): vendors `zcode relay` (baseURL
  `https://zcode.z.ai/api/v1/ultra-zai/anthropic`, apiKey "", `vendorKind: .relay`,
  `supportsThinkingBlocks: true`, `supportsAnthropicCountTokens: false` → count_tokens
  answered 404 locally) and `splash (local)` (`http://127.0.0.1:8000`, `replayPolicy:
  .portableOnly`). Rules ordered: auto→relay GLM-5.3, haiku→splash Qwen3.8-27B-4bit (backup
  relay GLM-5.3-Flash), sonnet→relay GLM-5.3, opus-peak→relay GLM-5.3-Flash **disabled**
  (weekdays 07:00–11:00 Europe/Paris — placed before plain opus so enabling it wins in the
  window), opus→relay GLM-5.3, fallback (catchAll)→relay GLM-5.3-Flash. JSON pinned by
  `defaultConfigJSONCarriesSpecSection2RuleTable`; upstream's `defaultConfigHasExpectedShape`
  updated (vendors 2 / mappings 6). Existing config.json files are NOT reinstalled.
- **Signing wiring (Task 5's known gap, closed):** `ProxyServer.start` builds ONE
  `RelayTarget.Context` per process when any `.relay` vendor is configured —
  `SigningClient` with a best-effort `CredentialStore.loadDefault()` (no store → requests fail
  as the relay's signing-unavailable 502, never unsigned; the reference is passed around and
  never logged) — plus the shared `CredentialEventChannel` the re-login alert will observe.
  The context flows ProxyServer → ProxyChannelHandler (new `relayContext` param, default nil)
  → `ProxyForwarder.forward` → `executeRelay` → `RelayTarget`. Injectable
  `makeSigningClient` factory for tests. Verified end-to-end over a real socket: a relay-kind
  class rule reaches the signed ladder and its 502 names the signing chain, not the old "no
  signing context configured" guard (which still stands for context-less calls).
- **Tests** (`ModelProxyTests/RouterTests.swift`, 17; suite total 261/17 green): class map
  (CC wire names incl. `glm-5.3[1m]`, missing model, unknown), class-rule resolution through
  `RoutingSnapshot.resolve`, exact-match precedence, timeWindow (fixed 2026-11-09 Monday /
  2026-11-14 Saturday Paris dates, edges, zone awareness via UTC), quotaBelow staleness +
  rule-skip, health staleness + rule-skip, RequestRouter actor path (missing model + legacy
  400), failover targets/state write-back, default-config JSON, legacy decode, wiring (server
  context construction/stability + end-to-end signed-ladder 502).
- Note: the pre-existing "EmbeddedEventLoop is not thread-safe" stderr noise in
  RelayTargetTests (Task 5's documented EmbeddedChannel caveat) is unchanged by Task 6 —
  verified identical counts (84) against the true HEAD baseline (an earlier mis-baseline used
  `git stash` without `-u`, leaving new files behind → build failure read as "0 errors").

## Task 7 — LocalTarget (Splash) + transcript replay (2026-11-15)

`ModelProxy/Proxy/LocalTarget.swift`: Splash as a forward target (loopback baseURL,
`.anthropic` vendor kind — NOT a new VendorKind case). Self-contained module in
RelayTarget's shape; **not yet branched into `ProxyForwarder.forward`** (file-scope
constraint — see below), so live splash traffic still rides the generic mapped path.

- **Wire request:** headers = client's minus hop-by-hop, minus `x-claude-code-*`, minus
  `x-api-key`/`authorization`, nothing added (local trust — the generic mapped path would
  add `Authorization: Bearer ` + empty `x-api-key` for a keyless vendor, which the AC
  forbids). Body = byte-preserving `model` splice (`ProxyForwarder.replaceModelField`) to
  the rule target's model verbatim — NO GLM canonicalization (splash isn't GLM); no
  `targetModel` → body unchanged.
- **Thinking replay is REUSED, not reimplemented:** `TranscriptProjector` keyed on the
  target's `replayPolicy` already strips thinking-like blocks + `signature` fields for
  `.portableOnly` targets that don't accept them (the splash shape:
  `supportsThinkingBlocks` defaults false) and is byte-transparent for `.transparent`
  (relay). Pinned in LocalTargetTests: identical body → splash-shaped target strips
  thinking/signature, relay-shaped target forwards byte-identical. Foreign-signature
  poisoning (plan risk #5) is therefore impossible through the projection path.
- **Fallback ladder** (`executeWithFallback(targets:)`, the `router.targets(for:)` shape):
  local exchange first; 2xx–4xx pass through (client errors are real errors); splash 5xx or
  transport failure walks the backups — relay backups delegate to `RelayTarget.execute`
  (own signed ladder), `.anthropic` backups get `ProxyForwarder.upstreamHeaders` + the same
  model splice. All backups exhausted → `.primaryError` (the local 5xx, rewrapped via
  `RelayTarget.drainErrorBody`) so the client sees the real error; primary unreachable +
  no backup → `.unreachable`.
- **AsyncHTTPClient single-iterator trap:** an `HTTPClientResponse.body` admits ONE
  `for await` iterator EVER — draining a 5xx then streaming the same response crashes
  (`NIOThrowingAsyncSequenceProducer ... only a single AsyncIterator`). Hence the ladder
  returns drainErrorBody's REWRAPPED response (fresh `.bytes` body) for `.primaryError`,
  never the drained original. Same class of bug as Task 5's EmbeddedChannel note.
- **Stream relay** (`relayStream`): pure chunk-for-chunk passthrough (no normalization —
  splash responses aren't projected back); on an upstream cut mid-SSE the client gets a
  terminal `event: error` SSE event (`api_error`, "Local model stream ended unexpectedly")
  then `.end` + close — never a silent EOF. Cut framing in tests: mock promises
  content-length N+1024, delivers N, closes (EOF-framed bodies would make a close look
  like a legal end). Silent-stall (open but mute upstream) is NOT bounded — AsyncHTTPClient
  has no per-body-read deadline; documented limitation.
- **Health** (`LocalHealthMonitor`, same file): implements Task 6's
  `TargetHealthProviding`. TCP connect (NIO `ClientBootstrap`, 2 s timeout) + immediate
  close to loopback vendor endpoints; cadence 20 s keeps success timestamps inside the
  router's 60 s staleness window (the timestamp IS the cache; the router applies freshness).
  Failed probes record nothing — old successes age out (asserted). Wire-level 2xx exchanges
  also `noteSuccess` (relay's `noteRelaySuccess` pattern). Registered in
  `ProxyServer.start` BEFORE the per-client `RequestRouter`s are built (Task 6 lifecycle
  note: routers capture the provider at construction); reconfigured on
  `updateRouting`, stopped in `stop()`. Injected `healthProvider`s (tests) never
  overridden.
- **Tests** (`ModelProxyTests/LocalTargetTests.swift`, 18; suite total 282/18 green):
  strip/keep thinking contract, byte-parity passthrough + credential-stripping header
  capture, no-targetModel passthrough, loopback classification, wire-success health note,
  probe up/down/stale-preserved (ephemeral listener), 5xx→rule-backup fallback THROUGH
  `RoutingSnapshot.targets(for:)` + relayStream to an EmbeddedChannel, 5xx-no-backup
  passthrough, unreachable→backup, stream-cut clean error event (bounded 5 s) + SSE
  well-formedness — plus 5 end-to-end `ProxyForwarder.forward` tests (below). Mock
  splash server pattern from RelayTargetTests; synthetic credentials/signatures only.

### Task 7 wiring round 2 — forward path (2026-11-15)

The Task 7 gap (LocalTarget built but not branched into `forward`) is closed:
`ProxyForwarder.forward` now branches `LocalTarget.isLocalTarget(target)` →
`executeLocal` → `LocalTarget.executeWithFallback(targets:)` where `targets` comes from
`router.targets(for: model)` (same eligibility + class-rule failover arrays the resolver
used), and step 8 streams via `LocalTarget.relayStream` (cut-protected passthrough) instead
of `ResponseRelay.relay` for local responses. Route-state bookkeeping on the local path
does NOT mirror the mapped path's "non-2xx counts a failure" rule: a served <400 splash
response resets the failure count, only an exhausted primary ladder (5xx error body or
unreachable) counts one failure (flipping activeTarget after 10), and a served ≥400
passthrough counts nothing.
The generic mapped path for non-splash anthropic vendors is untouched.

- **Local targets opt OUT of branch coordination:** `forward` drops the projector's
  branch context for local targets (no in-flight dedup/replay/commit). Rationale: the
  local relay is pure passthrough with no replayable capture (a cut ends in a terminal
  error event), and a local model never needs cross-vendor thinking restore; keeping the
  lease would surface 409s to concurrent duplicates for no benefit. Consequence: no
  token-usage extraction and no branch-transcript commit on the splash route (splash is
  local/free; CC resends its own context). Fix round 1: `WebSearchBridge.shouldHandle`
  now EXCLUDES local targets (it ran before the local branch and would have routed
  splash traffic through the generic mapped path — empty auth headers, no ladder, no
  cut-protect); web-search-bearing splash requests ride the local branch instead, and
  `sanitizeToolsForVendor` drops the server-side search tool before the request leaves.
- **Monitor chain:** ProxyServer → `ProxyChannelHandler(localHealth:)` →
  `forward(localHealth:)` → `executeLocal` — so wire-level 2xx splash exchanges warm the
  registered health monitor.
- **E2E pins (5 tests, through forward with mock splash/backup):** 5xx→rule-backup
  (client gets backup's 200, backup request carries the backup rule model), thinking-strip
  + credential-strip + model rewrite on the live path (+ monitor warmed), mid-stream cut →
  clean error SSE event with bounded completion, unreachable-no-backup → 502
  "Local target unreachable", 5xx+failing-backup → splash's own error body streams (the
  drain-then-rewrap single-iterator workaround pinned on the live path — a regression
  here is a process crash, not a test failure).
- **Note on "body byte-unchanged":** on the live splash path the projector re-serializes
  (`sortedKeys`) for `.portableOnly` targets, so byte-parity holds only in the module-level
  test (`LocalTarget.execute` without projection). The E2E pin asserts semantic
  preservation: model swapped, thinking/signature gone, all other content identical.
### Task 8 — QuotaService + live billing wire capture (2026-11-16, executor-run)

`ModelProxy/Services/QuotaService.swift`, `ModelProxy/Models/QuotaEvent.swift`,
fixtures `ModelProxyTests/Fixtures/quota-balance.json` / `quota-current.json` (values
synthetic), tests `ModelProxyTests/QuotaServiceTests.swift` (12 offline + env-gated live
smoke). Suite 297 tests / 20 suites green.

**Auth discovery — the brief's assumption ("quota endpoints take the same auth as the
relay", project-token `relayAuthHeaders`) is disproven by the wire.** Live probe matrix
against the scratch session (minted project token via SigningClient, zcode identity JWT
via CredentialStore):

- `zcode.z.ai` + project token: 401 in every form (bare Bearer+x-api-key, + CLI identity
  headers, + full V4 signing quartet). The gateway does not recognize the project token.
- `api.z.ai` + project token + identity + quartet: gateway 200 but inner `404 NOT_FOUND`
  (`{"code":500,"msg":"404 NOT_FOUND","success":false}`) — no such service behind api.z.ai.
- `zcode.z.ai` + **`Authorization: Bearer <zcodejwttoken>`** (the store's 255-char zcode
  identity JWT, no quartet): **`current` → HTTP 200 `code 0`**. This is the billing auth.
  Confirmed against the ZCode.app bundle (`app.asar`): its billing client
  (`dR`/`Cl`/`AUe`) sends exactly `Authorization: Bearer <zcodejwttoken>` and appends
  `?app_version=<version>` to the balance URL (15 s timeout).

**Pinned response shapes (field names/types only, values never recorded):**

- `GET /api/v1/zcode-plan/billing/current` → `{code: int, msg: string, logid: string,
  data: {plans: array, server_time: int}}`; `plans[]` rows (from the bundle's
  summarizer): `{name: string, plan_id: string, status: string,
  ends_at: number(seconds), user_plan_id: string}`. Live 2026-11-16: 200/code 0,
  `plans` EMPTY for this coding-plan account, byte length 109.
- `GET /api/v1/zcode-plan/billing/balance` → HTTP 400 `{"code":3001,"msg":"parameter
  error","logid":string}` for EVERY reconstructable request form (tried: app_version
  0.0.0-dev / 0.17.1 / 3.18.2, no query, +platform=darwin-aarch64). The success-payload
  shape is pinned from the bundle's own parsers instead:
  `data: {server_time: int, plans: [rows as above], balances: array}` with
  `balances[]` rows `{entitlement_id, show_name, total_units, used_units,
  remaining_units, available_units, reserved_units, user_plan_id, plan_id}` (numbers /
  strings). The bundle normalizes client-side: a plan with `status "active"` but
  `ends_at <= server_time` is expired, and balances of expired plans are dropped;
  balance→plan correlation by `user_plan_id`, else `plan_id`.
- Business-success predicate (bundle `isSuccessfulBusinessEnvelope`):
  `success !== false && (code undefined || 0 || 200)`.
- Version sensitivity: `current` returns `data` only for CLI-style `app_version` values
  (0.17.1 / 0.0.0-dev), not for the desktop app version 3.18.2 (200/code 0, no `data`).

**Data-availability gap (honest):** on the capture day neither endpoint yields quota
numbers for this account (`current` has empty `plans`; `balance` rejects the request
form). The desktop app's actual usage-stats endpoint is
`GET /api/v1/mcp/usage` (`app.asar`: schema `{used, limit, remaining}` wrapped in
`{server_time, next_refresh_at?, level?}`, 15 s timeout) — but its auth needs a
`codingPlanAuthorization` header (a fresh OAuth access token) that ZGate cannot mint
headlessly (store OAuth token is 1 h TTL, no refresh token; probed live: identity JWT
alone → 400/inner-404 on both origins). So the quota % is machinery-complete but
data-empty until either the balance request form or a headless usage-stats auth is
pinned. Until then the service holds no snapshot → router `quotaBelow` fail-opens,
and Task 9's bar shows unknown.

**Service:** lock-guarded `QuotaService: QuotaSnapshotProviding` (LocalHealthMonitor
pattern) — `pollIfDue()` decides due-ness (30 min interval OR ≥25 relayed requests
since the last attempt; an attempt consumes both triggers), background 60 s tick loop
starts at `ProxyServer.start` and outlives server stop; `noteRelayedRequest()` is
counted by RelayTarget's context (one tick per relay EXCHANGE — a rate-limit failover
to a backup relay re-enters execute and ticks again); thresholds 25%/10%
emit `QuotaEvent.levelChanged` through `QuotaEventChannel` (@MainActor, CredentialEventChannel
pattern) on band CROSSINGS only (first observation is silent); failed polls keep the
last-known snapshot and set `stale`; history in `quota-history-<date>.json`
(token-stats pattern, Application Support, fraction+timestamp only), pruned >30 days.
Registration mirrors Task 7: `quotaProvider` set in `ProxyServer.start` BEFORE routers
are built; injected providers never overridden; polling only when a relay vendor AND
the credential store exist.

**Live smoke** (`QuotaServiceLiveSmokeTests`, `TEST_RUNNER_ZGATE_LIVE_SMOKE=1`):
balance 400/3001 recorded, current 200 + shape printed, then `pollNow()` through the
real service — `stale=true hasSnapshot=false` (the correct live outcome today). One
excursion outside the file list: `RelayTarget.Context` gained an optional
`quota: (any QuotaRelayCounting)?` + one call at `execute()` entry (4 additive lines,
default nil) — required to wire the "after every 25th relayed request" trigger.

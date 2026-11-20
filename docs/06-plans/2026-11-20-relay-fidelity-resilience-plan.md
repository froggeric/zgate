# Relay Fidelity & Resilience Wave — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make ZGate's relay behave exactly like the official zcode CLI 0.17.1 client — server-driven endpoint routing, exact wire face, per-conversation sessions, live version tracking — and make it resilient: business-code error taxonomy, retired-model hygiene, API-key degraded fallback with half-open recovery, connect retries.

**Architecture:** Four new service types alongside the existing signing chain (`EndpointConfigService`, `VersionPinService`, `ApiKeyMinter`, `RelayHealth`), one pure-logic engine (`EndpointMapping`), and surgical changes to `RelayTarget` / `ProxyForwarder` / `ProxyServer`. All fidelity values come from the official CLI bundle at `/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs` (v0.17.1 — same as our pin), reverse-engineered read-only on 2026-11-19.

**Tech Stack:** Swift 6, SwiftNIO, AsyncHTTPClient (HTTP/1.1 only — same as the CLI's undici), XCTest (`ModelProxyTests`).

**Spec:** This document, §Background + Global Constraints. Source research: 2026-11-19 workflow study (peers: TriDefender/zcode-api, dengyie/zcode2api, liu5269/zcode2api) and 2026-11-20 official-CLI grounding workflow. User decisions recorded in `~/.claude/projects/-Volumes-ssd-github-zgate/memory/zgate-relay-upgrade-wave-scope.md`.

## Background (spec)

What the official CLI actually does (all verified against `zcode.cjs` symbols, not inferred):

1. **Endpoint routing** — the CLI never polls on a timer. Every model request is wrapped by `createProviderEndpointRoutingFetch`; `resolve()` calls `ensureFresh()`, which refreshes `GET https://zcode.z.ai/api/v1/agent/configs` only when the cached snapshot is expired. Constants: success TTL **300 s**, failure cooldown **30 s**, request timeout **3 s**, max response **256 KiB**, single-flight. Response: `{code:0, data:{proxyEndpoint:{mapping:[{from,to,zcodeAuthorizationHeader?}]}}}` (≤256 entries). Validation: `from`/`to` must be bare https URLs (no userinfo/query/hash); duplicate `from` rejects the whole refresh; `zcodeAuthorizationHeader` must literally equal `X-ZCode-Authorization` AND `to` must share the endpoint origin AND its path must be `/api/v1/ultra` or `/api/v1/ultra-zai` — otherwise the whole refresh is rejected. Lookup key: `scheme//host:port(default 443)+path` with trailing slashes stripped; on match the request URL is rewritten to `to` (query preserved) and, when flagged, `X-ZCode-Authorization: Bearer <zcodejwttoken>` is added (credentials-store key `zcodejwttoken`). **On any failure the last snapshot keeps serving; with no snapshot the request goes to the original pinned URL — the official client fails open.**
2. **Pinned URL** — the CLI's own provider table pins `https://zcode.z.ai/api/v1/zcode-plan/anthropic` (→ `/v1/messages`) for account plans. The `ultra-zai` path ZGate pins appears in the CLI **only** as a server-issued mapping target. ZGate pinned the *resolved* URL instead of the pre-routing URL + mapping.
3. **Wire face** — Node undici → HTTP/1.1. Ordered headers: `content-type`, `anthropic-version`, `authorization` (Bearer project JWT; the BYO-key template adds `x-api-key`, account plans do not), `http-referer`, `user-agent "ZCode/<ver> ai-sdk/anthropic/3.0.81"`, `x-zcode-app-version`, `x-title "Z Code@cli"`, `[x-release-channel — only when env-provided]`, `x-client-language`, `x-client-timezone`, `x-zcode-agent`, `x-platform`, `x-os-category`, `x-os-version`, then attribution: `x-request-id`, `x-zcode-session-type`, `x-zcode-trace-id`, `[x-query-id]`, `[x-zcode-query-source]`, `[x-zcode-session-features]`, `x-session-id`, `[anthropic-beta]`, then the signing block: `x-client-ts`, `x-client-version`, `x-client-sig`, `x-client-nonce`, `x-app-id: zcode`, `x-client-pow`. **No `X-Device-Mid` on the CLI face** (desktop-only), no `x-stainless-*`. ZGate's current UA literal `ZCode/0.17.1 ai-sdk/provider-utils/4.0.27 runtime/node.js/22` is a divergence from the official `ai-sdk/anthropic/3.0.81`.
4. **Sessions** — `x-session-id` is the current conversation's id with its prefix stripped (`sess_`/`subagent_agent_`); ids are `sess_ + UUID` per conversation, persisted under `~/.zcode/v2/sessions`; subagent turns carry `subagent_agent_` ids and `x-zcode-session-type: subagent` (enum `main|subagent|sidechat|other`); query ids `query_ + UUID` (prefix stripped). Signing REQUIRES `X-Session-Id`; the sig message and PoW include it, so per-request derivation stays self-consistent.
5. **Version** — the CLI reports `__ZCODE_VERSION__` (0.17.1); it has **no self-update**. The authoritative external signal is `GET https://zcode.z.ai/api/v1/client/configs?app_version=<ver>&platform=darwin-aarch64` → `data.configs.forceUpdate.minimalVersion` (server-enforced minimum).
6. **API-key edge** — first-class CLI provider template `zai-api`: `https://api.z.ai/api/anthropic` → `/v1/messages`, headers `x-api-key: {apiKey}.{secretKey}` (replaces authorization), `content-type`, `anthropic-version`, `User-Agent ZCode/<ver>`, `X-ZCode-App-Version`, `X-ZCode-Agent`, `HTTP-Referer`. No captcha on this channel. Key secret from the `/copy` chain (Task 7). User live-verified 2026-11-19: **this edge bills the same weekly quota**.
7. **Error taxonomy** (peers, single-account adaptation) — parse the envelope `code` from JSON only, **never substring** (20-digit logids collide). `1005/1113/1310` + status `402` → quota exhausted (no retry); `1302/1303` → true rate limit (backoff, no in-place retry); `3008/3009/3010` → concurrency (short backoff + retry); `3012`/`405` → risk control (NO retry, long cooldown); `3007` → captcha (surface, we do not solve); `3006` → model not allowed (prevented proactively); `1210` → `max_tokens` out of `[1,131072]` (clamp proactively). `1114` does not exist in any peer — do not add it.

## Global Constraints

- **Loopback-only, no body storage, no content logging** — unchanged project constraints.
- **Content transforms are limited to documented routing-compatibility transforms**: model-field canonicalization (Task 5), provider-prefix strip (Task 5), `max_tokens` clamp to `[1,131072]` (Task 5). These extend the documented transform list — Task 9 updates the feature docs accordingly. No system-prompt injection anywhere in this wave.
- **Never send unsigned requests to the zcode relay plane** (ultra/zcode-plan 401-rejects unsigned tokens — live-verified). Unsigned traffic exists only on the `api.z.ai/api/anthropic` fallback edge (Task 7), which is the CLI's own BYO-key mode.
- **Fail-open policy for endpoint config only**: `agent/configs` failures fall back to the pinned pre-routing URL exactly as the CLI does. Signing failures follow the existing ladder + Task 7 degraded mode.
- **Business codes are parsed from parsed JSON only** — substring matching on error bodies is forbidden (logid collision).
- All new upstream calls go through AsyncHTTPClient with bounded timeouts (3 s config fetch, 20 s version fetch, 15 s minter/ticket calls) and bounded body reads (256 KiB config, 4 MiB async pre-flight cap).
- **The off-peak plane (`/api/v1/off-peak/*`) is UNSIGNED — never V4-sign those paths (official client rule `isUnsignedModelRequestPath`)** and its local surface is **default-OFF, stream-only** (`stream: true` required), loopback-only like everything else.
- New `.swift` files must land in the `ModelProxy` target (executor confirms via build; the project uses synchronized file groups).
- Every existing test that pins the old header set / URL / ladder must be updated **in the same task** that changes the behavior — no deferred test fixes.

**User decisions (already made):**
- "We need to mimic the official client" — cadences and wire shapes follow the CLI, not the peers.
- API-key fallback edge approved; user verified it bills the same weekly quota.
- **Off-peak `/async` plane is pursued and included in this wave** (user 2026-11-20), default-OFF behind config, gated on probe D (Task 11): coding-plan JWT acceptance + billing confirmation.
- No captcha automation, no claim racing, no highspeed draw — planes hard-requiring captcha stay out.
- Template/system-prompt injection has no first customer in this wave — the CLAUDE.md content-modification constraint stays untouched.

## Review Focus

1. **Hostile/malformed `agent/configs` mapping** (non-https, userinfo credentials, >256 entries, duplicate `from`, `X-ZCode-Authorization` pointing at a non-allowlisted path) → the whole refresh is rejected and the previous snapshot (or pinned URL) keeps serving; never rewrite to an unvalidated target. → Task 1 validator tests.
2. **Config fetch hangs or is slow** → relay request must not block >3 s; fail open to pinned URL. → Task 1 timeout test (stub server sleeps 5 s).
3. **Degraded-mode flapping** (signing chain flapping up/down) → recovery probes respect min interval with exponential backoff (60 s → 300 s cap); never one probe per request. → Task 7 `RelayHealth` tests.
4. **Retired model / oversized `max_tokens` from stale client configs** (GLM-5.2, `max_tokens: 200000`) → rewritten/clamped before send; a 3006 or 1210 never reaches upstream. → Task 5 tests.
5. **Error envelope with colliding substrings** (20-digit logid containing `1113`/`3009`, envelope code 1302) → classified from the parsed `code` field only (rate limit, not exhausted). → Task 6 tests.

---

### Task 1: Endpoint routing engine — `EndpointMapping` + `EndpointConfigService` + pre-routing URL migration

**Goal:** Replicate the CLI's `ProviderEndpointRoutingService`: lazy 5-min-TTL refresh of `agent/configs`, strict mapping validation, per-request URL resolution with fail-open, and repin the relay vendor to the CLI's baked-in pre-routing URL.

**Files:**
- Create: `ModelProxy/Services/EndpointMapping.swift` (pure logic: parse/validate/resolve)
- Create: `ModelProxy/Services/EndpointConfigService.swift` (actor: fetch/cache/single-flight)
- Modify: `ModelProxy/Proxy/RelayTarget.swift:358-431` (`sendOnce` resolves URL; `relayHeaders` gains the `X-ZCode-Authorization` header when flagged)
- Modify: `ModelProxy/Proxy/ProxyServer.swift:148-197` (own one `EndpointConfigService`, pass into relay context/targets)
- Modify: `ModelProxy/Models/AppConfig.swift:214` + ConfigStore (one-time migration: relay vendor baseURL `…/ultra-zai/anthropic` → `…/zcode-plan/anthropic`)
- Test: `ModelProxyTests/EndpointMappingTests.swift`, `ModelProxyTests/EndpointConfigServiceTests.swift`

**Acceptance Criteria:**
- [ ] `EndpointMapping.parse` rejects: non-https `from`/`to`, URLs with userinfo/query/fragment, >256 entries, duplicate `from`, `zcodeAuthorizationHeader` values other than `X-ZCode-Authorization`, and flagged entries whose `to` origin ≠ `https://zcode.z.ai` or path ∉ {`/api/v1/ultra`, `/api/v1/ultra-zai`}. Each rejection drops the whole mapping.
- [ ] `resolve("https://zcode.z.ai/api/v1/zcode-plan/anthropic/v1/messages")` with a mapping `from: …/zcode-plan/anthropic → to: …/ultra-zai/anthropic` (flagged) returns the rewritten URL with query preserved and `addZcodeAuthorization = true`.
- [ ] Lookup is trailing-slash-insensitive; non-matching URLs return unchanged.
- [ ] `EndpointConfigService` refreshes lazily: first `resolve` fetches; within 300 s serves cache; after 300 s refetches; on fetch failure serves the last snapshot and retries no sooner than 30 s; a fetch slower than 3 s times out and fails open.
- [ ] No snapshot at all (fresh install, offline) → `resolve` returns the original URL (fail-open), never throws, never blocks the request path more than 3 s.
- [ ] The relay request path consults the service per request; when flagged, `x-zcode-authorization: Bearer <zcodejwttoken>` is added (token from CredentialStore; header omitted if token absent — fail-open).
- [ ] Existing installs migrate the relay vendor baseURL to `https://zcode.z.ai/api/v1/zcode-plan/anthropic` once, idempotently; a user-edited vendor URL is left alone.

**Verify:** `xcodebuild test -project ZGate.xcodeproj -scheme ZGate -destination 'platform=macOS' -only-testing:ModelProxyTests/EndpointMappingTests -only-testing:ModelProxyTests/EndpointConfigServiceTests` → all pass.

**Steps:**

- [ ] **Step 1: Write failing tests for the mapping engine**

```swift
// ModelProxyTests/EndpointMappingTests.swift
import XCTest
@testable import ModelProxy

final class EndpointMappingTests: XCTestCase {
    private let payload: (String, String, String?) -> Data = { from, to, flag in
        let entry: [String: String] = flag.map { ["from": from, "to": to, "zcodeAuthorizationHeader": $0] }
            ?? ["from": from, "to": to]
        let envelope: [String: Any] = ["code": 0, "data": ["proxyEndpoint": ["mapping": [entry]]]]
        return try! JSONSerialization.data(withJSONObject: envelope)
    }

    func testValidFlaggedMappingRewritesURLAndFlagsAuthorization() {
        let m = EndpointMapping.parse(payload("https://zcode.z.ai/api/v1/zcode-plan/anthropic",
                                              "https://zcode.z.ai/api/v1/ultra-zai/anthropic",
                                              "X-ZCode-Authorization"))!
        let r = m.resolve("https://zcode.z.ai/api/v1/zcode-plan/anthropic/v1/messages?beta=1")
        XCTAssertEqual(r?.url, "https://zcode.z.ai/api/v1/ultra-zai/anthropic/v1/messages?beta=1")
        XCTAssertEqual(r?.addZcodeAuthorization, true)
    }

    func testTrailingSlashesAreStrippedForLookup() { /* from ends with '/', resolves */ }

    func testNonMatchingURLOffersNoRewrite() { XCTAssertNil(m.resolve("https://other.example/x")) }

    func testRejectsNonHTTPS() { /* to: http://… → parse returns nil */ }
    func testRejectsUserinfoQueryFragment() { /* from: https://u:p@z/…, to with ?q, #frag → nil */ }
    func testRejectsDuplicateFrom() { /* two entries same from → nil */ }
    func testRejectsOversizedTable() { /* 257 entries → nil */ }
    func testRejectsFlagOnDisallowedTarget() { /* to: https://api.z.ai/api/v1/ultra (foreign origin) flagged → nil;
                                                  to: https://zcode.z.ai/api/v1/other flagged → nil */ }
    func testRejectsNonZeroEnvelopeCode() { /* {"code":42,…} → nil */ }
}
```

- [ ] **Step 2: Run tests → fail** (`EndpointMapping` does not exist — build error is the red state).

- [ ] **Step 3: Implement the engine**

```swift
// ModelProxy/Services/EndpointMapping.swift
import Foundation

/// Pure port of the CLI's ProviderEndpointRoutingService mapping rules
/// (zcode.cjs 0.17.1 — P_t/Iha/Aha/xha/xvo). No network, fully testable.
struct EndpointMapping: Equatable {
    struct Entry: Equatable {
        let from: URL
        let to: URL
        let flaggedForZcodeAuthorization: Bool
    }

    let entries: [Entry]
    private static let endpointOrigin = URL(string: "https://zcode.z.ai")!
    private static let authorizationTargetAllowlist: Set<String> = ["/api/v1/ultra", "/api/v1/ultra-zai"]

    static func parse(_ data: Data) -> EndpointMapping? {
        guard data.count <= 256 * 1024,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["code"] as? Int) == 0,
              let mapping = (((json["data"] as? [String: Any])?["proxyEndpoint"] as? [String: Any])?["mapping"] as? [[String: Any]]),
              mapping.count <= 256 else { return nil }
        var seen = Set<String>(), entries: [Entry] = []
        for raw in mapping {
            guard let fromS = raw["from"] as? String, let toS = raw["to"] as? String,
                  let from = validatedURL(fromS), let to = validatedURL(toS),
                  seen.insert(key(from)).inserted else { return nil }
            var flagged = false
            if let header = raw["zcodeAuthorizationHeader"] as? String {
                guard header.caseInsensitiveCompare("X-ZCode-Authorization") == .orderedSame,
                      to.schemeAndHostAndPort == endpointOrigin.schemeAndHostAndPort,
                      authorizationTargetAllowlist.contains(to.normalizedPath) else { return nil }
                flagged = true
            }
            entries.append(Entry(from: from, to: to, flaggedForZcodeAuthorization: flagged))
        }
        return EndpointMapping(entries: entries)
    }

    func resolve(_ raw: String) -> (url: String, addZcodeAuthorization: Bool)? {
        guard let url = URL(string: raw) else { return nil }
        let requestKey = key(url)
        guard let entry = entries.first(where: { key($0.from) == requestKey }) else { return nil }
        return (absolute(entry.to, query: url.query), entry.flaggedForZcodeAuthorization)
    }

    // key = scheme//host:port(443 default)+path, trailing slashes stripped (Aha)
    private static func key(_ u: URL) -> String {
        let port = u.port ?? 443
        return "\(u.scheme!)//\(u.host ?? ""):\(port)\(u.normalizedPath)"
    }
    private static func validatedURL(_ s: String) -> URL? {
        guard let u = URL(string: s), u.scheme == "https", u.host != nil,
              u.user == nil, u.password == nil, u.query == nil, u.fragment == nil else { return nil }
        return u
    }
}
```

(Add the small `URL` helpers `normalizedPath` / `schemeAndHostAndPort` / `absolute(_:query:)` in the same file; `normalizedPath` strips trailing slashes.)

- [ ] **Step 4: Tests pass.** Commit: `feat(relay): endpoint mapping engine with CLI validation rules`.

- [ ] **Step 5: Write failing service tests** (fake AHC transport injected like `QuotaService` tests do — mirror their stub-server pattern):

```swift
func testLazyRefreshWithinTTL() async { /* stub serves mapping; two resolves → one fetch */ }
func testFailureKeepsLastSnapshotAndCoolsDown30s() async { /* stub fails; resolve still rewrites; immediate refresh attempt suppressed */ }
func testSlowFetchTimesOutAndFailsOpen() async { /* stub sleeps 5 s; resolve returns original URL, elapsed < 4 s */ }
func testNoSnapshotFailsOpen() async { /* offline stub; resolve returns original */ }
func testSingleFlight() async { /* 5 concurrent resolves during expiry → 1 fetch */ }
```

- [ ] **Step 6: Implement `EndpointConfigService`** — an actor modeled on `QuotaService`'s shape (config struct, bounded fetch via AsyncHTTPClient, `Date`-injected for tests): `resolve(_ url: String) async -> (url: String, addZcodeAuthorization: Bool)` always returns (fail-open). Config request headers: `user-agent: ZCode/<clientVersion>`, `x-zcode-app-version: <clientVersion>`, `x-api-key-id: <signing session apiKeyId when available>`, `accept: application/json`. Inject `now: () -> Date` for deterministic TTL tests.

- [ ] **Step 7: Wire into the relay path** — `ProxyServer.start` builds one `EndpointConfigService` (alongside the relay context, `ProxyServer.swift:148-197`) and passes it to `RelayTarget`; `sendOnce` builds `raw = target.baseURL + head.uri`, then `let resolved = await endpointConfig.resolve(raw)` and uses `resolved.url`; `relayHeaders` gains a `zcodeAuthorization: String?` parameter emitted as `x-zcode-authorization: Bearer <jwt>` right after `authorization` when non-nil. Token: `CredentialStore`'s zcode plan JWT (`zcodejwttoken`); omit when absent.

- [ ] **Step 8: Config migration** — new idempotent ConfigStore migration (follow the existing one-time-migration pattern referenced at `AppConfig.swift:202-206`): if a relay vendor's baseURL is exactly `https://zcode.z.ai/api/v1/ultra-zai/anthropic`, rewrite to `https://zcode.z.ai/api/v1/zcode-plan/anthropic`. Any other value (user-edited) is untouched. Update `RouterTests`/`E2E.smoke.swift` URL pins accordingly.

- [ ] **Step 9: Full test run + commit** `feat(relay): lazy agent/configs routing with fail-open + pre-routing URL pin`.

### Task 2: CLI-face header fidelity — exact ordered header set, correct UA

**Goal:** Rebuild `relayHeaders` so the wire matches the official CLI face: exact insertion order, UA `ZCode/<ver> ai-sdk/anthropic/3.0.81`, `x-release-channel` omitted (CLI sends it only when env-provided), signing block last in CLI order.

**Files:**
- Modify: `ModelProxy/Proxy/RelayTarget.swift:33-47` (constants), `:382-431` (`relayHeaders`)
- Test: `ModelProxyTests/RelayTargetTests.swift:566-659` (header statics), fixture `ModelProxyTests/Fixtures/v3-relay-request.json`

**Acceptance Criteria:**
- [ ] Header insertion order is exactly: `content-type`, `anthropic-version`, `authorization`, `http-referer`, `user-agent`, `x-zcode-app-version`, `x-title`, `x-client-language`, `x-client-timezone`, `x-zcode-agent`, `x-platform`, `x-os-category`, `x-os-version`, `x-request-id`, `x-zcode-session-type`, `x-zcode-trace-id`, `x-query-id`, `x-zcode-query-source`, `x-session-id`, `anthropic-beta` (only when non-empty), then when signed: `x-client-ts`, `x-client-version`, `x-client-sig`, `x-client-nonce`, `x-app-id`, `x-client-pow`, then `x-api-key` (kept this wave; Task 9 probe decides dropping it).
- [ ] UA is built, not literal: `"ZCode/\(clientVersion) ai-sdk/anthropic/3.0.81"`.
- [ ] `x-release-channel` no longer sent; `x-zcode-session-features` not sent (empty).
- [ ] PoW/sig inputs unchanged (`CryptoCore.swift:56-57,98` message shapes) — signatures stay valid.
- [ ] Fixture `v3-relay-request.json` regenerated to the new order; header-statics tests updated in the same commit.

**Verify:** `xcodebuild test … -only-testing:ModelProxyTests/RelayTargetTests` → all pass, including updated fixture test.

**Steps:**

- [ ] **Step 1: Update the fixture + header tests to the new expected order** (red).
- [ ] **Step 2: Rewrite `relayHeaders`** — same building blocks, reordered; replace the `userAgent` literal with:

```swift
static func userAgent(for version: String) -> String { "ZCode/\(version) ai-sdk/anthropic/3.0.81" }
```

- [ ] **Step 3: Run tests green; full `ModelProxyTests` suite; commit** `feat(relay): exact CLI 0.17.1 header face (order + UA)`.

### Task 3: Session identity — per-conversation `x-session-id` + subagent session-type

**Goal:** Derive `x-session-id` from the inbound Claude Code session header (stable per conversation), mark subagent turns (`x-claude-code-agent-id` present) with `x-zcode-session-type: subagent` and a per-agent session id, keeping PoW/sig inputs consistent; per-process UUID stays the fallback.

**Files:**
- Modify: `ModelProxy/Proxy/RelayTarget.swift` (`Context.sessionID` at `:100-101` becomes fallback; new `SessionIdentity.derive(from:fallback:)`)
- Test: `ModelProxyTests/RelayTargetTests.swift:661-685` (session-stability pins)

**Acceptance Criteria:**
- [ ] With `x-claude-code-session-id: <uuid>` inbound: `x-session-id` equals the sanitized uuid, identical across requests in one conversation, different across conversations.
- [ ] With `x-claude-code-agent-id` present: type is `subagent` and the id is `<session>-<8-hex hash of agent id>` (mirrors the CLI's per-agent `subagent_agent_` sessions); without it: `main`.
- [ ] Garbage inbound ids (non-hex, >64 chars, <8 chars) fall back to the per-process UUID.
- [ ] PoW and Ed25519 sig messages use the derived id (self-consistent — server sees one session id everywhere).
- [ ] No inbound CC headers → behavior identical to today (per-process UUID, `main`).

**Verify:** `xcodebuild test … -only-testing:ModelProxyTests/RelayTargetTests` → session tests updated and green.

**Steps:**

- [ ] **Step 1: Failing tests** — derive/sanitize cases + a relay-level test asserting two requests with the same CC session header produce identical `x-session-id` (inspect via a stub upstream server capturing headers, mirroring the existing stub-server test style).

```swift
static func sanitize(_ raw: String?) -> String? {
    guard let raw, raw.count >= 8, raw.count <= 64 else { return nil }
    let cleaned = raw.lowercased().filter { $0.isLetter && $0.isASCII && $0.isHexDigit || $0 == "-" }
    return cleaned.count >= 8 ? cleaned : nil
}
static func shortHash(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8).description
}
```

- [ ] **Step 2: Implement** — extract at `execute()` entry (`head` is already a parameter, `RelayTarget.swift:127`), thread a `SessionIdentity` through `relayHeaders`; `Context.sessionID` remains the fallback.
- [ ] **Step 3: Green + commit** `feat(relay): per-conversation session identity with subagent derivation`.

### Task 4: Live version tracking — `VersionPinService` + constant unification

**Goal:** Poll `client/configs` for `forceUpdate.minimalVersion`; bump the impersonated version when the server minimum rises; unify the scattered version constants (UA, `x-zcode-app-version`, `x-client-version`, sig message) to a single configurable source with `0.17.1` fallback.

**Files:**
- Create: `ModelProxy/Services/VersionPinService.swift`
- Modify: `ModelProxy/Models/AppConfig.swift` (new persisted `relayClientVersion: String`, default `"0.17.1"`), `ModelProxy/Proxy/RelayTarget.swift:34` (read from config instead of static), `ModelProxy/Signing/SigningClient.swift:126-128` — **leave `mintClientVersion "0.0.0-dev"` untouched** (distinct by design, `docs/signing-notes.md:24-31`).
- Test: `ModelProxyTests/VersionPinServiceTests.swift`, updated `RelayTargetTests` header statics.

**Acceptance Criteria:**
- [ ] `GET https://zcode.z.ai/api/v1/client/configs?app_version=<current>&platform=darwin-arm64` (20 s timeout, optional `Authorization: Bearer <zcodejwttoken>`) parses `data.configs.forceUpdate.minimalVersion`.
- [ ] When `minimalVersion` is semver-greater than the pinned version, the pin updates and persists (`relayClientVersion` in config.json); otherwise no change. Failure → keep current, silent.
- [ ] UA, `x-zcode-app-version`, `x-client-version`, and the sig-message version input all derive from the single configured value.
- [ ] Poll cadence: at launch, then every 6 h; no user-visible UI in this wave.
- [ ] Semver comparison: `0.17.1 < 0.18.0`, `0.17.1 !< 0.17.1`, `1.0.0 > 0.99.99`.

**Verify:** `xcodebuild test … -only-testing:ModelProxyTests/VersionPinServiceTests -only-testing:ModelProxyTests/RelayTargetTests` → green.

**Steps:**

- [ ] **Step 1: Failing tests** — semver compare cases; stub-server poll test (minimalVersion `0.18.0` → pin bumps; fetch failure → unchanged).
- [ ] **Step 2: Implement** the service (actor, `now`-injected, modeled on `QuotaService`), a tiny `SemVer` parse/compare helper, config field + wiring; `RelayTarget` takes the version as a parameter (default keeps tests deterministic).
- [ ] **Step 3: Green + full suite + commit** `feat(relay): server-driven client-version pin via forceUpdate.minimalVersion`.

### Task 5: Model hygiene — retired aliases, provider-prefix strip, `max_tokens` clamp

**Goal:** Prevent guaranteed-fail 3006/1210 requests: canonicalize retired model names before send, strip provider prefixes, clamp `max_tokens` into `[1,131072]`.

**Files:**
- Modify: `ModelProxy/Proxy/RelayTarget.swift:50-57` (`glmCanon`), `:437-463` (`canonicalModel`, `wireBody`), `ModelProxy/Proxy/ProxyForwarder.swift:1094+` (new `clampMaxTokensField`)
- Test: `ModelProxyTests/RelayTargetTests.swift:551-561` (canonical table pins)

**Acceptance Criteria:**
- [ ] `glm-5.2`, `glm-5.1`, `glm-5.1-highspeed`, `glm-5-turbo`, `glm-4.7`, `glm-turbo` → `GLM-5.3`; their `-flash` variants → `GLM-5.3-Flash` (existing flash-substring rule wins first).
- [ ] `zai/GLM-5.3`, `bigmodel/glm-5.3` → prefix stripped before canonicalization.
- [ ] Older family names (`GLM-4.6`, `GLM-4.5-Air`, …) still pass through verbatim; unknown `glm-*` still falls back to `GLM-5.3`; non-GLM unknowns still `GLM-5.3-Flash`.
- [ ] `wireBody` clamps `max_tokens` (top-level, when present) into `[1,131072]` via a byte-preserving splice; absent field untouched; in-range values byte-identical.
- [ ] Both transforms are recorded as documented routing-compatibility transforms (docs land in Task 9).

**Verify:** `xcodebuild test … -only-testing:ModelProxyTests/RelayTargetTests` → green with new table cases.

**Steps:**

- [ ] **Step 1: Failing tests** — the alias/prefix/clamp cases above (clamp tested through `wireBody` with embedded JSON fixtures, asserting byte-equality for in-range values).
- [ ] **Step 2: Implement** — extend `glmCanon` with the retired keys; strip prefix at the top of `canonicalModel`:

```swift
static func canonicalModel(_ model: String) -> String {
    var lowered = model.trimmingCharacters(in: .whitespaces).lowercased()
    for prefix in ["zai/", "bigmodel/"] where lowered.hasPrefix(prefix) {
        lowered = String(lowered.dropFirst(prefix.count))
    }
    // … existing flash / glm-5.3 / glmCanon / fallback chain unchanged …
}
```

and a `ProxyForwarder.clampMaxTokensField(_ body: Data, min: Int = 1, max: Int = 131_072) -> Data` sibling of `replaceModelField` (scan for the top-level `"max_tokens":` key, splice only when out of range).

- [ ] **Step 3: Green + commit** `feat(relay): retired-model aliases, provider-prefix strip, max_tokens clamp`.

### Task 6: Business-code error taxonomy

**Goal:** Parse upstream business codes from drained error bodies (JSON only) and route remediation by class instead of status-code + substring greps.

**Files:**
- Create: `ModelProxy/Proxy/RelayErrorTaxonomy.swift`
- Modify: `ModelProxy/Proxy/RelayTarget.swift:205-314` (`handleReject`, `handleRateLimited`), `:470-495` (`drainErrorBody` → returns `RelayUpstreamError`), `sendOnce` response-head check for 200-carried envelopes
- Test: `ModelProxyTests/RelayErrorTaxonomyTests.swift`, ladder tests `:846-1133`

**Acceptance Criteria:**
- [ ] `drainErrorBody` extracts `code` (Int) + `message` from the envelope shapes `{code, msg|message}`, `{error:{message, code}}`, `{error:{type,message}}` — parsed JSON only.
- [ ] Classification: `1005/1113/1310` + HTTP `402` → `.quotaExhausted`; `1302/1303` → `.rateLimited`; `3008/3009/3010` → `.concurrencyLimited`; `3012` or HTTP `405` → `.riskControl`; `3007` → `.captchaChallenge`; `3006` → `.modelNotAllowed`; `1210/3001` → `.invalidParameter`; `1114` is never classified (does not exist upstream).
- [ ] Remediation: exhausted → no retry, quota poll tick, caller fallback (Task 7), surface 429-shaped error to client; rateLimited → existing single backoff retry then fallback; concurrencyLimited → up to 2 in-place retries (3 s, 6 s, ±1 s jitter); riskControl → no retry, enter `RelayHealth.riskCooldown` (Task 7), surface clear 502; captcha → surface (never solve); modelNotAllowed/invalidParameter → surface 400 as-is (Tasks 5 prevents the common cases).
- [ ] 401 handling unchanged: VERIFY ladder + `'expired'` relogin detection remain (they match envelope fields, not raw substrings over logids).
- [ ] A 200 response whose body is a business envelope (`code != 0`, no `type:"message"`) is classified, not relayed as success.

**Verify:** `xcodebuild test … -only-testing:ModelProxyTests/RelayErrorTaxonomyTests -only-testing:ModelProxyTests/RelayTargetTests` → green.

**Steps:**

- [ ] **Step 1: Failing taxonomy tests**, including the collision case:

```swift
func testLogidCollisionDoesNotMisclassify() {
    let e = RelayUpstreamError(status: 429, code: 1302,
        message: "rate limited, logid 11139999999999993009")
    XCTAssertEqual(RelayErrorTaxonomy.classify(e), .rateLimited)   // not exhausted/concurrency
}
```

- [ ] **Step 2: Implement** `RelayUpstreamError`, `RelayErrorTaxonomy.classify`, rework `drainErrorBody` (keep the re-wrap behavior — one iterator per body), wire the branches into `handleReject`/`handleRateLimited`; add the 200-envelope check at `sendOnce` (drain only when `content-type` is JSON and the parsed top level has `code`).
- [ ] **Step 3: Update ladder tests + green + commit** `feat(relay): business-code error taxonomy driving remediation`.

### Task 7: Unsigned API-key fallback edge + `RelayHealth` degraded machine

**Goal:** Mint the signing-free `api.z.ai/api/anthropic` credential via the `/copy` chain, add it as a fallback vendor, and degrade to it with half-open recovery probes so signing-chain outages become degraded-service instead of terminal 502s.

**Files:**
- Create: `ModelProxy/Signing/ApiKeyMinter.swift`, `ModelProxy/Proxy/RelayHealth.swift`
- Modify: `ModelProxy/Signing/SigningClient.swift` (expose the cached biz JWT + `api/biz` call helper; `mintProjectToken` at `:414-447` is the structural template), `ModelProxy/Proxy/ProxyForwarder.swift:859-922` (`executeRelay` degraded routing), `ModelProxy/Models/AppConfig.swift` + ConfigStore (fallback vendor seed + migration), `ModelProxy/Proxy/ProxyServer.swift:369-389` (health actor owned alongside routing)
- Test: `ModelProxyTests/ApiKeyMinterTests.swift`, `ModelProxyTests/RelayHealthTests.swift`, `ProxyForwarderTests` degraded-path cases

**Acceptance Criteria:**
- [ ] Mint chain (15 s per call, all against `api.z.ai`): existing biz JWT → `GET /api/biz/customer/getCustomerInfo` → org `默认机构` else first / project `默认项目` else first → `GET /api/biz/v1/organization/{o}/projects/{p}/api_keys` → find `name == "zcode-api-key"` → else `POST` create → `GET …/api_keys/copy/{apiKey}` → `data.secretKey` → credential `"{apiKey}.{secretKey}"`, persisted as the fallback vendor's `apiKey` (config.json, per project convention).
- [ ] Fallback vendor: `vendorKind .anthropic`, `baseURL https://api.z.ai/api/anthropic`, `stripsClaudeOnlyRequestFields true`, `applyGLMCanonicalization true` (new flag — Task 5's `canonicalModel` applied to the model field on this path so GLM names never leak raw); seeded + migrated as the catch-all rule's backup, idempotently, without touching user-edited rules.
- [ ] `RelayHealth`: `degradedSigning` entered on `.signingUnavailable`/post-retry `.transportFailed`; while degraded, a signed attempt runs only when `now >= nextProbeAt` (60 s base, ×2 backoff, 300 s cap); probe success → healthy (reset); `credentialsExpired` serves fallback without probing (recovery = relogin); `riskCooldown(900 s)` from Task 6 blocks relay attempts (client gets a clear 502) without touching the fallback.
- [ ] Fallback failures never launder relay state: a fallback 401 re-mints the key once; a fallback `1113` (key no balance) cools the key 1 h and surfaces; relay health is untouched by fallback outcomes.
- [ ] No fallback configured (user removed the vendor) → behavior identical to today.

**Verify:** `xcodebuild test … -only-testing:ModelProxyTests/ApiKeyMinterTests -only-testing:ModelProxyTests/RelayHealthTests` → green; full suite green.

**Steps:**

- [ ] **Step 1: Failing `RelayHealth` tests** — enter/exit degraded, probe interval 60→120→240→300 cap, probe success resets, risk cooldown blocks, credentialsExpired does not probe.
- [ ] **Step 2: Implement `RelayHealth`** (actor, `now`-injected; state machine exactly as the AC describes).
- [ ] **Step 3: Failing minter tests** — stub server for the 5-call chain (happy path; missing key → create; missing `secretKey` → throws).
- [ ] **Step 4: Implement `ApiKeyMinter`** (struct taking a biz-JWT provider closure + HTTP execute closure for testability; real wiring in `ProxyServer`).
- [ ] **Step 5: Wire degraded routing into `executeRelay`** — on relay-terminal outcomes consult `RelayHealth`, serve via the existing backup path (`ProxyForwarder.swift:905-911`), mint lazily on first use, re-mint on fallback 401. Config migration seeds vendor + backup rule.
- [ ] **Step 6: Green + full suite + commit** `feat(relay): API-key fallback edge with half-open recovery (degraded, never terminal)`.

### Task 8: Connect-retry ladder

**Goal:** Retry connect-phase transport failures (before the response head) up to 2 times with 500 ms × attempt backoff, using fresh requests (body is `Data`, reusable).

**Files:**
- Modify: `ModelProxy/Proxy/RelayTarget.swift:195-198` (catch site), `:358-375` (`sendOnce`)
- Test: `ModelProxyTests/ConnectRetryTests.swift` (new class — stub server refuses/closes N connections then serves)

**Acceptance Criteria:**
- [ ] Connect-class failures (`ConnectionError`, `ChannelError`, AHC connect timeouts) retry: attempt 0 → fail → 500 ms → attempt 1 → fail → 1000 ms → attempt 2.
- [ ] Failures after the response head (mid-body IO) and non-connect errors fail immediately (existing `.transportFailed`).
- [ ] A fresh `HTTPClientRequest` is built per attempt (never re-use a consumed request).
- [ ] Success on attempt 2 returns normally; three connect failures → `.transportFailed` (then Task 7 degraded routing may take over).

**Verify:** `xcodebuild test … -only-testing:ModelProxyTests/ConnectRetryTests` → green.

**Steps:**

- [ ] **Step 1: Failing tests** — stub server closes the first two connections then serves 200 (assert 200 + exactly 3 connection attempts); stub that always closes (assert `.transportFailed` after 3).
- [ ] **Step 2: Implement** the retry loop in `sendOnce` with a conservative classifier:

```swift
private func isConnectPhaseFailure(_ error: Error) -> Bool {
    error is ConnectionError || error is ChannelError
        || (error as? HTTPClientError).map { "\($0)".localizedCaseInsensitiveContains("connect") } == true
}
```

- [ ] **Step 3: Green + commit** `feat(relay): pre-write connect-retry ladder (2×500ms)`.

### Task 9: Off-peak ticket control plane — `OffPeakTicketClient`

**Goal:** Implement the official-client ticket-queue control plane (availability / take / status / settle) as a standalone, stub-testable client for the Off-Peak / Idle Plan — an unsigned coding-plan perk.

**Files:**
- Create: `ModelProxy/Services/OffPeakTicketClient.swift`
- Test: `ModelProxyTests/OffPeakTicketClientTests.swift`

**Acceptance Criteria:**
- [ ] `GET {origin}/api/v1/off-peak/ticket/availability` → `(canTake: Bool, nextTakeAt: Int64?)` (`next_take_at` mandatory when `can_take_number` is false).
- [ ] `POST /api/v1/off-peak/ticket` body `{"task_id": <id>}` → `OffPeakTicket {ticketID, state ∈ queued|ready|active|settled|expired|not_found, position?, activeDeadline?, nextPollAfter?}`.
- [ ] `POST /api/v1/off-peak/ticket/status` body `{"ticket_ids": [...]}` (≤100 ids per batch — chunk larger sets) → `(tickets, nextPollAfter?)`; `active_deadline` is the unix-second deadline to **start using** a ready ticket.
- [ ] `POST /api/v1/off-peak/ticket/{id}/settle` — any 4xx treated as success (server already cleaned up); 8 s timeout, never throws to the caller.
- [ ] All calls: `{code:0, data:…}` envelope, success only on numeric `code == 0` (mirror `QuotaService.MonitorEnvelope`); 15 s timeout; auth = `Authorization: Bearer <zcode plan JWT>` + `X-Coding-Plan-Api-Key: {apiKey}.{secretKey}` + the CLI identity header set (Task 2); **never V4-signed**.
- [ ] Envelope `code != 0` throws a typed error carrying `code` + `msg` (no substring parsing).

**Verify:** `xcodebuild test … -only-testing:ModelProxyTests/OffPeakTicketClientTests` → green.

**Steps:**

- [ ] **Step 1: Failing tests** against a stub HTTP server (mirror `QuotaService` test style): happy paths for all four calls; `next_take_at` present when `can_take_number:false`; `code:42` envelope throws with the code attached; settle receives 404 and still returns normally; a 101-id status batch splits into two POSTs.

```swift
// ModelProxy/Services/OffPeakTicketClient.swift
struct OffPeakTicket: Codable, Equatable {
    enum State: String, Codable { case queued, ready, active, settled, expired, notFound = "not_found" }
    let ticketID: String
    let state: State
    let position: Int?
    let activeDeadlineMs: Int64?
    let nextPollAfterSeconds: Int?
}

struct OffPeakTicketClient {
    // Official desktop-client protocol (unsigned plane). All calls 15 s timeout,
    // envelope success = numeric code == 0 only. Chunked status batches ≤ 100 ids.
    let origin: String
    let jwtProvider: () async -> String?          // zcode plan JWT (zcodejwttoken)
    let credentialProvider: () async -> String?   // "{apiKey}.{secretKey}" from ApiKeyMinter
    let execute: (HTTPClientRequest, Data?) async throws -> (Int, Data)   // injected for tests
}
```

- [ ] **Step 2: Implement** the four calls on that shape; real wiring lives in Task 10.
- [ ] **Step 3: Green + commit** `feat(offpeak): ticket-queue control plane client`.

### Task 10: Async relay surface — `/async/v1/messages` + orchestrator

**Goal:** Expose an opt-in, default-OFF local async surface: pre-flight → availability wait → ticket take → poll with SSE keepalives → unsigned data-plane call with `X-Off-Peak-Ticket-ID` → untouched SSE relay → settle. State machine WAIT→READY→DONE/EXPIRED/ABORT.

**Files:**
- Create: `ModelProxy/Proxy/OffPeakTarget.swift` (orchestrator + data plane + keepalive bridge)
- Modify: `ModelProxy/Proxy/ProxyServer.swift:236-254` (route `"/async/"` prefix to the handler when enabled, before normal forward), `ModelProxy/Models/AppConfig.swift` (+ ConfigStore migration: new `offPeak` section)
- Test: `ModelProxyTests/OffPeakTargetTests.swift`

**Acceptance Criteria:**
- [ ] Config: `OffPeakConfig {enabled=false, origin="https://zcode.z.ai", maxWaitMinutes=60, pollIntervalSeconds=5, keepaliveSeconds=3}` persisted via ConfigStore; migration adds the section to existing installs without touching anything else.
- [ ] Local routes: `POST /async/v1/messages` (Anthropic passthrough) and `GET /async/v1/health` (`{"enabled":…}`); disabled or unknown async path → standard Anthropic-shaped 404-style error. Usage: point a batch harness at `ANTHROPIC_BASE_URL=http://localhost:9090/async`.
- [ ] Pre-flight before ANY ticket is taken (never leak a ticket on a malformed request): config enabled; body ≤ 4 MiB; parseable JSON; `stream == true` (else local error `async_stream_required`); model canonicalized via Task 5 helpers.
- [ ] Availability false → wait until `next_take_at` (bounded by `maxWaitMinutes`), downstream keepalives flowing, then re-check; `can_take` → take with `task_id = "zgate-" + uuid`.
- [ ] Poll loop: `pollIntervalSeconds` or server `next_poll_after` (server wins when larger); 3 consecutive poll failures tolerated (backoff `min(pollInterval, 2 s)`) before aborting; while queued, emit `: keepalive\n\n` downstream every `keepaliveSeconds` — keepalives stop the moment the data-plane stream starts (never inside an SSE frame).
- [ ] Data plane: `POST {origin}/api/v1/off-peak/anthropic/v1/messages`, headers = Task 2 identity set + `Authorization: Bearer <zcode JWT>` + `X-Coding-Plan-Api-Key` + `X-Off-Peak-Ticket-ID`; **unsigned**; SSE frames relayed untouched via the existing `ResponseRelay`; usage accounting unchanged.
- [ ] Settle fired on completion, error, or client disconnect (fire-and-forget, never blocks the response); `expired`/`not_found` mid-wait → exactly one re-take within `maxWaitMinutes`, else a 529-shaped Anthropic error to the client.
- [ ] Long-wait tolerance: the async path's upstream read timeout is `maxWaitMinutes + 30 min` (not the 300 s relay default); downstream writes are SSE-comment heartbeats so idle TCP never dies.

**Verify:** `xcodebuild test … -only-testing:ModelProxyTests/OffPeakTargetTests` → green; full suite green.

**Steps:**

- [ ] **Step 1: Failing tests** with a stub ticket server + stub LLM SSE server (mirror the `RelayTarget` stub-server tests): full happy path (assert keepalive bytes precede the stream, SSE payload bytes are untouched, settle called once); availability-false→wait→true; 3 poll failures tolerated then 4th aborts; expired→re-take once; non-stream rejected with `async_stream_required` and **zero** ticket-server calls; oversized body rejected pre-take; disabled → error without contacting anything.
- [ ] **Step 2: Implement** `OffPeakConfig` + migration; `OffPeakTarget` orchestrator (inject `OffPeakTicketClient`, clock, and sleeper for determinism); the `/async/` route branch in `ProxyServer`'s channel-handler glue.
- [ ] **Step 3: Green + full suite + commit** `feat(offpeak): opt-in async relay surface with ticket orchestration`.

### Task 11: Live probes, e2e, and docs

**Goal:** Verify the fidelity changes against the real plane and land the documentation wave.

**Files:**
- Modify: `scripts/e2e/scenarios.sh` (append relay-fidelity scenarios where the rig allows), `docs/00-AI-CONTEXT.md` (feature list touch), new `docs/05-features/2026-11-20-relay-fidelity-resilience.md`, `docs/03-decisions/` amendments (endpoint discovery; failure philosophy; session identity), `CHANGELOG.md`, `docs/signing-notes.md` (new pins).
- Probe: manual, gated on the user's live account, `max_tokens: 8` payloads only.

**Acceptance Criteria:**
- [ ] Live probe A: with the migrated pre-routing pin, a debug-build relay request resolves through `agent/configs` to the ultra target and succeeds (traffic log shows the mapped URL + `x-zcode-authorization` when flagged). If the pre-routing URL itself fails while mapping is unavailable, revert migration target to ultra-zai and record the finding in signing-notes.
- [ ] Live probe B: request without `x-api-key` (Authorization only) on the relay plane — if green, flip the default to CLI-faithful (drop `x-api-key`) and update fixture/tests; if rejected, keep both headers and record why.
- [ ] Live probe C: fallback edge round-trip on `api.z.ai/api/anthropic/v1/messages` with the minted key (user confirms the weekly-quota monitor move they already verified in principle).
- [ ] Live probe D: off-peak round-trip with the user's account — availability → take → one `max_tokens: 8` data-plane request → settle, during the server's off-peak window; user confirms the weekly-quota monitor did NOT move. If the JWT is rejected on the plane or billing does consume the weekly quota, flip `offPeak.enabled` semantics to requires-manual-activation + document the finding (surface stays, default-OFF unchanged).
- [ ] e2e rig (`scripts/e2e/up.sh` + `scenarios.sh`) green on the isolated build; no regression in the existing scenario set; new scenarios where the rig allows (mapping fail-open via stubbed configs origin; degraded fallback with a dead signing stub; async happy path against stub ticket+LLM servers).
- [ ] Docs: feature doc covers the five transforms (model canonicalization, prefix strip, max_tokens clamp, session derivation, endpoint routing) as documented routing-compatibility transforms **plus the off-peak surface (unsigned plane, ticket lifecycle, default-OFF)**; ADR amendments record the fail-open philosophy change (endpoint config + degraded fallback + async plane) with the evidence; CHANGELOG entry drafted.

**Verify:** `scripts/e2e/build.sh && scripts/e2e/up.sh && scripts/e2e/scenarios.sh && scripts/e2e/down.sh` → all scenarios pass; `xcodebuild test -project ZGate.xcodeproj -scheme ZGate -destination 'platform=macOS'` → full suite green.

**Steps:**

- [ ] **Step 1:** Run probes A–D against a debug build with the user's account; record outcomes in `docs/signing-notes.md`; apply the probe-B and probe-D decisions.
- [ ] **Step 2:** Extend e2e scenarios (mapping fail-open, degraded fallback, async happy path).
- [ ] **Step 3:** Write the docs wave + CHANGELOG.
- [ ] **Step 4:** Full test suite + e2e green; commit `docs(feature): relay fidelity & resilience wave` and `chore(release-prep)` per repo convention.

---

## Out of scope (recorded — rejected by user decision 2026-11-20)

- Captcha automation, claim racing, highspeed draw — rejected (ban risk; "speed is already ok, higher speed would deplete the quota faster").
- Start-plan plane (3012 content gate + captcha) — rejected; the CLAUDE.md content-modification constraint stays untouched this wave.

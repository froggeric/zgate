# Signing intelligence — zcode relay (Task 1 findings)

> **2026-11-18 — superseded in parts by ZGate 2.7.6's native login stack.**
> ZGate now runs the OAuth flow in-app (`oauth/cli/init` → browser → poll,
> `ModelProxy/Signing/ZaiLoginClient.swift`), reads the shared `~/.zcode`
> store by default, renews tokens proactively (`CredentialKeeper`), and
> adopts external logins without restart. The scratch-home terminal remedy
> below is historical (kept as the alert's fallback path). The wire/protocol
> findings remain accurate.

Observed 2026-11-15. Sources: live instrumented runs (`capture2.js`, this task — failed run
2026-11-15T18:13Z with expired credentials; successful run 2026-11-15T18:25Z after user
re-login), V3 wire capture (`/Volumes/ssd/github/zcode/wire.log`, 2026-11-15T17:08Z),
credential-store metadata decode (`inspect-store.js`), and static reading of the CLI bundle
(`/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs`, 15.7 MB). No credential value
appears anywhere in this document; token references are by length and truncation form only.

## The one-line answers

- **Relay `authorization` + `x-api-key` provenance (live-confirmed 18:25Z):** both headers
  carry the *same* value — the **project access token**, minted per CLI run by
  `POST https://api.z.ai/api/biz/v1/organization/<orgId>/projects/<projectId>/api_keys/<apiKeyId>/access_tokens`
  (body `{"clientType":"zcode","clientVersion":"0.0.0-dev"}` — exactly 50 B, matching the
  observed `bodyLen` in both captures; bundle-derived, not wire-captured: the CLI computes
  `JSON.stringify({clientType:"zcode",clientVersion:dx})` with `dx = __ZCODE_VERSION__ ??
  "0.0.0-dev"`, and the standalone CLI leaves `__ZCODE_VERSION__` undefined — corroborated at
  runtime by `client/configs?app_version=0.0.0-dev`. **Task 4 note:** the mint body carries
  the bundle-version constant `"0.0.0-dev"`, *not* the app version — `x-client-version:
  0.17.1` on the relay comes from a different version source (the signer's `clientVersion`
  input), so the two are genuinely different values in the real client; re-derive from a fresh
  capture when implementing the mint). `x-api-key` = the token raw
  (463-char JWT); `authorization` = `"Bearer " + token` (470 = 7 + 463). It is **not** a
  credential-store field (store has `oauth:zai:access_token` 404-char and `zcodejwttoken`
  255-char — no length match) and **not** a handshake response field (the handshake response
  carries only the signing-key cipher, below). The token lives in an in-process cache keyed by
  origin/family/account/usageScene/loginGeneration; only the *location* (org/project/apiKeyId)
  is persisted, as store key `project-key-location:v1:[...]` (155 B plaintext).
  **The mint call's own auth** (live-observed): `Bearer <z/login-minted biz JWT>` (header
  length 1409 = 7 + 1402) — *not* the store's 404-char `access_token` and *not*
  `zcodejwttoken` (255/262). Per-invocation chain: store `access_token` → `z/login` →
  1402-char biz JWT → `access_tokens` mint → 463-char project token → handshake
  `Authorization` = relay `x-api-key` (raw) / `authorization` (`Bearer ` + token).
  Task 4 implication: ZGate must replicate the full mint chain per run (or cache the project
  token in memory for its TTL); there is no way to read a relay-ready token from the store.
- **Access-token expiry flow (observed live):** with the store's 1-h `oauth:zai:access_token`
  expired, the CLI fails before any handshake/relay traffic: `POST api.z.ai/api/auth/z/login`
  with body `{"token":"<expired access_token>"}` (416 B = 12 + 404) returns HTTP 200 with a
  business-layer login failure → `[project-access-token] project_token_login_failed` →
  `Turn execution failed`, exit 1. **No refresh/exchange endpoint fires** (none exists: the
  store has no refresh token — field list below). Re-login (browser OAuth) is the only recovery.
  The long-lived `zcodejwttoken` (no `exp` claim) still authenticates
  `GET zcode.z.ai/api/v1/client/configs` (`Bearer` + 255 + 7 = the 262-char header) — so the
  control plane works while the billing/relay path is dead.

## Credential store layout (`~/.zcode-scratch-v3/.zcode/v2/credentials.json`)

Envelope: `enc:v2:env:<24-hex keyFingerprint>:<iv>.<tag>.<ct>`, AES-256-GCM, key =
`sha256(secret.txt content)`. Fields (decrypted metadata only):

| Store key | Plaintext | Notes |
|---|---|---|
| `oauth:active_provider` | 3 B | provider id, not a token |
| `oauth:zai:access_token` | 404-char JWT | iss `user-service`, `token_type: access_token`, TTL exactly 3600 s, **no refresh token anywhere in the store** |
| `oauth:zai:user_info` | 5106 B JSON | profile blob |
| `zcodejwttoken` | 255-char JWT | payload has `user_id`, `token_version`, `sub`, `iat` — **no `exp`** (long-lived) |
| `oauth:session_revision` | 36 B | uuid |
| `account-provider:account:zai-individual-coding-plan:identity` / `:auth-source` | 36 B / 5 B | plan identity |
| `project-key-location:v1:%5B…%5D` | 155 B JSON | URL-decoded key: `["https://api.z.ai","zai","<uuid>",null,1,"default"]` — persisted org/project location for the api_keys flow |

## CLI startup flow (endpoint sequence)

Fresh-token run (wire.log V3, all 200): `GET zcode.z.ai/api/v1/client/configs` (Bearer
zcodejwttoken) → `GET cdn-zcode.z.ai/.../zcode-builtin-production-43.json` → `POST
api.z.ai/api/auth/z/login` `{"token":<access_token>}` → short-lived biz JWT (1401-char; used
raw on `GET api.z.ai/api/biz/customer/getCustomerInfo`, as `Bearer` on the api_keys calls) →
`GET .../api_keys` (finds the key named `zcode-api-key`, id `b5f4e699…888920`/32-hex) → `POST
.../api_keys/<id>/access_tokens` (**mints the 463-char project token**) → `GET
zcode.z.ai/api/v1/agent/configs` (header `x-api-key-id`) → `POST
api.z.ai/api/paas/c1f3a7e2/v2/client` (handshake) → `POST
zcode.z.ai/api/v1/ultra-zai/anthropic/v1/messages` (relay).

Expired-token run (this task, 2026-11-15T18:13Z): `client/configs` 200 (zcodejwttoken still
valid) → CDN config 200 (cache hit) → `z/login` HTTP 200/business-failure → hard stop, exit 1.
Store file untouched (sha256 `0622ed87…`, mtime unchanged by the failed run).

Successful instrumented run (this task, 2026-11-15T18:25Z, fresh store, all 200, stdout `OK`):
`z/login` (416 B body, no auth header) → `access_tokens` mint (auth `Bearer …(1409)`, body
50 B) → `agent/configs` → handshake → relay. Note the deltas vs the first-ever run:
`client/configs`/CDN were cache-skipped ("not-due"), and `getCustomerInfo` + `api_keys` list
did **not** fire at all — the org/project/apiKeyId location came from the store's
`project-key-location:v1` cache, so with a warm location the CLI goes straight from `z/login`
to the mint. `z/login` itself fires on every invocation, using the store `access_token`.

## Handshake `POST api.z.ai/api/paas/c1f3a7e2/v2/client`

- Request: header `Authorization: <project token>` (463) — same value as the body's
  `accessToken` field; body `{accessToken: <463>, nonce, sig, ts}` (598 B total). The signer
  (`ClientRequestSigningV4Signer`) takes the project token as its `apiKey`; `KLr()` parses it:
  a 3-dot-part JWT-style string yields `{apiKeyId: <part[1].api_key>, secret: wholeToken,
  credential: wholeToken, handshakeField: "accessToken"}` (a 2-part `id.secret` key would use
  `handshakeField: "apiKey"`).
- `sig` = signature over `"get_sign_key\n<apiKeyId>\n<ts>\n<nonce>"` (bundle const
  `bia="get_sign_key"`); `nonce` = 16 random bytes hex (32 chars).
- **Live shapes (18:25Z capture, recursively typed, zero values):**
  - request body: `{"accessToken": "<str:463>", "nonce": "<str:32>", "sig": "<str:44>", "ts": "<str:13>"}`
    (598 B total; `sig` 44 chars = base64 of 32 bytes; `ts` = ms epoch)
  - response body: `{"code": "<num>", "msg": "<str:20>", "data": {"privateCipher": "<str:124>"}, "success": "<boolean>"}`
    — confirms the static contract: the only signing-relevant field is `privateCipher`
    (124-char string); `privateCipher` + `apiKeyId` + secret feed the HKDF key schedule
    (`WD_CLIENT_SIGN_KDF_SALT` / `getSignKey_hmac` / `ed25519_priv`, constants already pinned
    in the plan) → the ed25519 private key used for `x-client-sig`. Non-200 `code` or missing
    `privateCipher` → `handshake-business`/`handshake-protocol` error; all handshake error
    kinds are `failOpenEligible` (client falls back to sending the relay request *unsigned* —
    which the relay rejects with 401 per the earlier live probe; Task 5's "no cold-start
    fail-open" stands).

## Relay request — fixture

`ModelProxyTests/Fixtures/v3-relay-request.json` (plan path
`Tests/ZGateTests/Fixtures/v3-relay-request.json`): url/method/headers of the official CLI
0.17.1 wire face, regenerated 2026-11-20 (relay-fidelity Task 2) to the exact CLI insertion
order, 27 headers. Value policy: credential-bearing headers (`authorization`, `x-api-key`,
`x-client-sig`) and per-request IDs/nonces keep the wire.log capture's already-truncated forms
(≤28 chars, length suffix preserved — the `(463)`/`(470)`/`(88)` lengths are the observed
plan-token/sig lengths Tasks 4–5 need). Whitelisted non-credential headers are full values.

- Header order (the fixture object lists them in this order; undici/HTTP 1.1 preserves it):
  `content-type`, `anthropic-version`, `authorization`, `http-referer`, `user-agent`,
  `x-zcode-app-version`, `x-title`, `x-client-language`, `x-client-timezone`, `x-zcode-agent`,
  `x-platform`, `x-os-category`, `x-os-version`, `x-request-id`, `x-zcode-session-type`,
  `x-zcode-trace-id`, `x-query-id`, `x-zcode-query-source`, `x-session-id`, `anthropic-beta`,
  then the signer block `x-client-ts`, `x-client-version`, `x-client-sig`, `x-client-nonce`,
  `x-app-id`, `x-client-pow`, then `x-api-key`. ZGate additionally inserts its Task-1 routing
  header `x-zcode-authorization` immediately after `authorization` when endpoint routing flags
  it (ZGate's own, not part of the CLI face).
- `anthropic-beta` recovered **byte-exact** from the bundle literal
  `ke.add("mid-conversation-system-2026-04-07")` — 34 chars, head `mid-conversation-s` /
  tail `-04-07` / length all match the wire.log truncation, and the 18:25Z live run sent the
  identical value.
- `user-agent` official CLI composition (Task 2): `ZCode/<version> ai-sdk/anthropic/3.0.81` —
  built from `clientVersion`, never a frozen literal. The earlier capture's
  `ai-sdk/provider-utils/… runtime/node.js/22` tail was the pre-Task-2 divergence, now fixed.
- `x-release-channel` is no longer listed (the CLI sends it only when env-provided) and
  `x-zcode-session-features` is never sent (empty) — the earlier 28-header capture's
  `x-release-channel: production` was the one extra name; the other 27 are live-confirmed.

### Relay request/response body shapes (18:25Z, typed, zero values — for Task 5)

- request (86 749 B): `{model: <str:7>, max_tokens: <num>, metadata: {user_id: <str:122>},
  system: [{type: <str:4>, text: <str:35>}], messages: [{role: <str:4>, content: [{type:
  <str:4>, text: <str:22>, cache_control: {type: <str:9>}}]}], tools: […], tool_choice:
  {type: <str:4>}, stream: <boolean>, thinking: {type: <str:7>}, output_config: {effort: <str:3>}}`
- response: `text/event-stream`; first SSE event (message_start):
  `{type: <str:13>, message: {id: <str:34>, type: <str:7>, role: <str:9>, model: <str:7>,
  content: [], stop_reason: <object>, stop_sequence: <object>, usage: {input_tokens: <num>,
  output_tokens: <num>}}}` — SSE chunks must be forwarded immediately (upstream constraint).

## Signing headers set by the signer (bundle static, `sendSigned`)

`X-Client-Ts` (ms), `X-Client-Nonce` (32-hex), `X-Client-Pow` (proof-of-work over
`{apiKeyId, appId:"zcode", powBits:8, sessionId, ts, nonce}`), `X-Client-Sig` (signature over
`"<apiKeyId>\n<ts>\n<clientVersion>\n<sessionId>\n<nonce>"` with the handshake-derived ed25519
key), `X-Session-Id` (copied from the model request), `X-App-Id: zcode`, `X-Client-Version`.
The signer never touches `authorization`/`x-api-key` — those are pre-built model-request
headers (the agent/configs proxy mapping's `zcodeAuthorizationHeader` flag includes them on
relay-destined requests). On a 401 the signer retries once with a fresh handshake, then
switches to unsigned bypass for the process lifetime.

## Capture log

`/Volumes/ssd/github/zcode/capture2.log` holds the full 18:25Z JSONL (request/response records
under the header policy; shape records for the handshake and relay). The earlier 18:13Z
expired-token transcript is preserved in `/Volumes/ssd/github/zcode/task-1-report.md` —
`capture2.log` is truncated fresh by each direct run. Scratch store was re-login-refreshed at
18:24:36Z (access token exp 19:24:36Z); re-login command for future expiry (interactive,
human-only):

```bash
ZCODE_DATA_BASE_DIR=$HOME/.zcode-scratch-v3 ZCODE_CREDENTIAL_SECRET_FILE=$HOME/.zcode-scratch-v3/secret.txt \
node /Applications/ZCode.app/Contents/Resources/glm/zcode.cjs login zai
```

# Signing intelligence — zcode relay (Task 1 findings)

Observed 2026-11-15. Sources: live instrumented run (`capture2.js`, this task), V3 wire capture
(`/Volumes/ssd/github/zcode/wire.log`, 2026-11-15T17:08Z), credential-store metadata decode
(`inspect-store.js`), and static reading of the CLI bundle
(`/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs`, 15.7 MB). No credential value
appears anywhere in this document; token references are by length and truncation form only.

## The one-line answers

- **Relay `authorization` + `x-api-key` provenance:** both headers carry the *same* value — the
  **project access token**, minted per CLI run by
  `POST https://api.z.ai/api/biz/v1/organization/<orgId>/projects/<projectId>/api_keys/<apiKeyId>/access_tokens`
  (body `{"clientType":"zcode","clientVersion":"0.17.1"}`, 50 B). `x-api-key` = the token raw
  (463-char JWT); `authorization` = `"Bearer " + token` (470 = 7 + 463). It is **not** a
  credential-store field (store has `oauth:zai:access_token` 404-char and `zcodejwttoken`
  255-char — no length match) and **not** a handshake response field (the handshake response
  carries only the signing-key cipher, below). The token lives in an in-process cache keyed by
  origin/family/account/usageScene/loginGeneration; only the *location* (org/project/apiKeyId)
  is persisted, as store key `project-key-location:v1:[...]` (155 B plaintext).
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

## Handshake `POST api.z.ai/api/paas/c1f3a7e2/v2/client`

- Request: header `Authorization: <project token>` (463) — same value as the body's
  `accessToken` field; body `{accessToken: <463>, nonce, sig, ts}` (598 B total). The signer
  (`ClientRequestSigningV4Signer`) takes the project token as its `apiKey`; `KLr()` parses it:
  a 3-dot-part JWT-style string yields `{apiKeyId: <part[1].api_key>, secret: wholeToken,
  credential: wholeToken, handshakeField: "accessToken"}` (a 2-part `id.secret` key would use
  `handshakeField: "apiKey"`).
- `sig` = signature over `"get_sign_key\n<apiKeyId>\n<ts>\n<nonce>"` (bundle const
  `bia="get_sign_key"`); `nonce` = 16 random bytes hex (32 chars).
- Response (bundle static reading): `{code: 200, msg?, data: {privateCipher: <string>}}`;
  `privateCipher` + `apiKeyId` + secret feed the HKDF key schedule (`WD_CLIENT_SIGN_KDF_SALT` /
  `getSignKey_hmac` / `ed25519_priv`, constants already pinned in the plan) → the ed25519
  private key used for `x-client-sig`. Non-200 `code` or missing `privateCipher` →
  `handshake-business`/`handshake-protocol` error; all handshake error kinds are
  `failOpenEligible` (client falls back to sending the relay request *unsigned* — which the
  relay rejects with 401 per the earlier live probe; Task 5's "no cold-start fail-open" stands).
- **Live response SHAPE still pending**: this task's run died at `z/login` (expired access
  token) before any handshake fired. After re-login, one `node /Volumes/ssd/github/zcode/capture2.js`
  run prints it (recursively typed, zero values) plus the relay request header set with full
  non-credential values.

## Relay request — fixture

`ModelProxyTests/Fixtures/v3-relay-request.json` (plan path
`Tests/ZGateTests/Fixtures/v3-relay-request.json`): url/method/headers from the wire.log V3
capture, 28 headers. Value policy: credential-bearing headers (`authorization`, `x-api-key`,
`x-client-sig`) and per-request IDs/nonces keep wire.log's already-truncated forms (≤28 chars,
length suffix preserved — the `(463)`/`(470)`/`(88)` lengths are the observed plan-token/sig
lengths Tasks 4–5 need). Whitelisted non-credential headers are full values.

- `anthropic-beta` recovered **byte-exact** from the bundle literal
  `ke.add("mid-conversation-system-2026-04-07")` — 34 chars, head `mid-conversation-s` /
  tail `-04-07` / length all match the wire.log truncation. Fixture carries the full value.
- `user-agent` is the one gap: wire.log has only `ZCode/0.17.1 ai-sd….js/22(60)`. Confirmed
  composition facts: prefix `ZCode/0.17.1` (CLI), second segment `ai-sdk/anthropic/3.0.81`
  (bundle const `$Qs`, the only `ai-sdk/anthropic/` literal), and an ai-sdk runtime-suffix
  builder `runtime/node.js/${process.version}` — but no composition of these reproduces the
  observed length-60 string ending `.js/22`, so the full value is **not** asserted here. The
  post-re-login capture2 run logs it in full (whitelisted header).

## Signing headers set by the signer (bundle static, `sendSigned`)

`X-Client-Ts` (ms), `X-Client-Nonce` (32-hex), `X-Client-Pow` (proof-of-work over
`{apiKeyId, appId:"zcode", powBits:8, sessionId, ts, nonce}`), `X-Client-Sig` (signature over
`"<apiKeyId>\n<ts>\n<clientVersion>\n<sessionId>\n<nonce>"` with the handshake-derived ed25519
key), `X-Session-Id` (copied from the model request), `X-App-Id: zcode`, `X-Client-Version`.
The signer never touches `authorization`/`x-api-key` — those are pre-built model-request
headers (the agent/configs proxy mapping's `zcodeAuthorizationHeader` flag includes them on
relay-destined requests). On a 401 the signer retries once with a fresh handshake, then
switches to unsigned bypass for the process lifetime.

## Open item (blocking nothing in Tasks 2–3; blocks live confirmation for 4–5)

Scratch home needs re-login (interactive browser OAuth, human required):

```bash
ZCODE_DATA_BASE_DIR=$HOME/.zcode-scratch-v3 ZCODE_CREDENTIAL_SECRET_FILE=$HOME/.zcode-scratch-v3/secret.txt \
node /Applications/ZCode.app/Contents/Resources/glm/zcode.cjs login zai
```

Then one run of `node /Volumes/ssd/github/zcode/capture2.js` (prints shape logs; whitelisted
headers in full) captures the handshake response shape, relay header set, and the full
`user-agent`, closing the two pending observations above.

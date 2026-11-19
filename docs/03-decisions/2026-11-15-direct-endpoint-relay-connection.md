# ADR: Direct-endpoint connection to the zcode relay

**Date:** 2026-11-15 (recorded 2026-11-19)
**Status:** Accepted
**Issue:** fork routing — how GLM traffic reaches z.ai

## Context

ZGate must relay Anthropic-protocol requests to z.ai's GLM models, which are
served through the zcode relay
(`https://zcode.z.ai/api/v1/ultra-zai/anthropic/v1/messages` — the default
`zcode relay` vendor baseURL, `ModelProxy/Models/AppConfig.swift`). The relay
demands the CLI's full ClientRequestSigningV4 chain: it 401-rejects requests
carrying valid tokens but no signing headers (live-verified — there is no
unsigned cold path; `ModelProxy/Proxy/RelayTarget.swift` doc comment).

## Alternatives considered (all dead ends — verified 2026-11-15)

- **Proxy through the locally-installed zcode CLI.** No such mechanism
  exists: the CLI exposes no local proxy port. Its plugins are MCP tool
  servers only; its app-server is a session/agent stdio protocol with no raw
  `/v1/messages` endpoint; `zcode -p` double-agents rather than proxies.
  Evidence (external, machine-local): the dead-end list in
  `/Volumes/ssd/github/zcode/GATEWAY-SPEC.md`.
- **Proxy through the locally-installed ZCode GUI.** Same verdict: the GUI
  exposes no listener; its "HTTP proxy" setting is outbound-only (routes the
  GUI's own traffic through a proxy).
- **Indirect vendor surfaces.** z.ai's official docs (docs.z.ai/devpack,
  zcode.z.ai/en/docs) document only direct endpoints for external tools.

## Decision

**Connect direct-endpoint and reimplement the signing chain natively.** The
sole relay vendor (`vendorKind == .relay`) POSTs straight to the remote relay
(`ModelProxy/Proxy/RelayTarget.swift`), with the full chain in Swift
(`ModelProxy/Signing/SigningClient.swift`, `CryptoCore.swift`): `~/.zcode`
store decrypt → `api.z.ai/api/auth/z/login` → biz JWT → mint project token →
`/api/paas/c1f3a7e2/v2/client` handshake → Ed25519 unseal; then per-request
`x-client-ts`/`-nonce`/`-pow`/`-sig` plus identity headers pinned from the
zcode CLI bundle (UA `ZCode/0.17.1`).

The locally installed ZCode GUI/CLI plays exactly one role for ZGate:
**credential source** — one login populates the shared `~/.zcode` store that
SigningClient reads. Since ZGate 2.7.6, in-app OAuth (`ZaiLoginClient`) makes
even that optional. The ZCode app is never a network hop.

### Ethics note

The chain is genuine, not spoofed: ZGate derives real keys from the user's
own legitimate login and performs the real handshake, proof-of-work, and
Ed25519 signatures. No header bytes are forged to masquerade as another
client.

## Lineage

`zbridge.mjs` (2026-11-15, `/Volumes/ssd/github/zcode/zbridge.mjs` —
single-file zero-dependency Node proxy on `127.0.0.1:8788`) used the same
direct-endpoint method; ZGate is its native-Swift port (`RelayTarget.swift`
doc comment: "Mirrors the zbridge request builder"). Cutover 2026-11-16:
Claude Code's `ANTHROPIC_BASE_URL` flipped from zbridge `:8788` to ZGate
`:8787`; port 8788 stays reserved for zbridge on this machine.

## Consequences

- Signing failure on cold start is a terminal 502 — a request never leaves
  unsigned (failure policy in `RelayTarget`).
- The chain must track the CLI bundle: UA/version pins are pinned constants
  that age with the CLI (`docs/signing-notes.md`).
- Wire behavior is pinned by `ModelProxyTests/Fixtures/v3-relay-request.json`
  and live-proven in `docs/e2e-checklist.md` AC1.

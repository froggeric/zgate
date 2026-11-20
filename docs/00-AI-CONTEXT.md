# ZGate - AI Context

> AI assistant entry document for this project. Fork of
> [model-proxy](https://github.com/n0rvyn/model-proxy) (upstream README kept
> at `README.upstream.md`); app renamed ModelProxy → ZGate on 2026-11-18
> (source dir `ModelProxy/` and test names kept).

## One-line Description

macOS menu bar app: transparent local API proxy routing Claude Code / Codex
requests to the **signed zcode relay** (z.ai GLM models — direct endpoint,
full V4 signing chain in Swift) or a local model server (Splash), by model ID.

## Core Features

### Local HTTP Proxy

Listens on localhost, intercepts Anthropic-format API requests, routes via
exact-match mappings then class rules in config order (conditions: time
window / quota / health), terminal catch-all last — no request is dropped.

**Key Files:**
- `ModelProxy/Proxy/ProxyServer.swift` - NIO HTTP server
- `ModelProxy/Proxy/RequestRouter.swift` / `RoutingSnapshot.swift` - model matching, class rules, failover
- `ModelProxy/Proxy/ResponseRelay.swift` - response forwarding (streaming + non-streaming)

### Signed zcode relay (direct endpoint)

The sole GLM vendor POSTs straight to
`https://zcode.z.ai/api/v1/ultra-zai/anthropic/v1/messages` — never through
the local ZCode CLI/GUI (no local proxy port exists; the app is a credential
source only). Full ClientRequestSigningV4 chain in Swift; unsigned requests
are never sent (the relay 401s them). Decision record:
`docs/03-decisions/2026-11-15-direct-endpoint-relay-connection.md`.

**Key Files:**
- `ModelProxy/Proxy/RelayTarget.swift` - relay forward target, per-request signing, failure policy
- `ModelProxy/Signing/SigningClient.swift`, `CryptoCore.swift` - store decrypt → z/login → token mint → handshake → Ed25519
- `ModelProxy/Signing/ZaiLoginClient.swift`, `CredentialKeeper.swift`, `BizSessionCache.swift` - in-app OAuth, renewal
- `ModelProxy/Services/CredentialStore.swift` - shared zcode credential store access

### Relay fidelity & resilience (2026-11-20 wave)

The relay path mirrors the official CLI wire face with ONE per-conversation
session identity, resolves URLs through the server's `agent/configs` table
(fail-open), tracks the server's minimum CLI version, performs the five
documented routing-compatibility transforms (model canonicalization,
provider-prefix strip, max_tokens clamp, session derivation, endpoint
routing), classifies upstream failures by business code with per-class retry
policy, and serves degraded traffic from a signing-free api.z.ai fallback
edge instead of failing. An opt-in (default OFF) off-peak `/async/` surface
routes through ZCode's Off-Peak ticket queue. Feature doc:
`docs/05-features/2026-11-20-relay-fidelity-resilience.md`.

**Key Files:**
- `ModelProxy/Services/EndpointConfigService.swift` - lazy agent/configs routing (fail-open)
- `ModelProxy/Proxy/RelayErrorTaxonomy.swift` / `RelayHealth.swift` - failure classes, degraded machine + fallback edge
- `ModelProxy/Services/VersionPinService.swift` - server-driven CLI-version pin
- `ModelProxy/Proxy/OffPeakTarget.swift` / `ModelProxy/Services/OffPeakTicketClient.swift` - off-peak async surface

### Configuration

Manages vendors, model mappings, routing rules, and client-specific settings
(Claude Code / Codex).

**Key Files:**
- `ModelProxy/Models/AppConfig.swift` - top-level config model, default routing
- `ModelProxy/Models/Vendor.swift` - vendor definition (endpoint, vendorKind, models)
- `ModelProxy/Models/ClientConfig.swift` - per-client settings (port, tier mappings)

### Menu Bar UI

Status, quota ring, traffic log, token stats.

**Key Files:**
- `ModelProxy/App/ModelProxyApp.swift` - app entry, MenuBarExtra
- `ModelProxy/Views/StatusPopover.swift` - main popover view
- `ModelProxy/Views/SettingsView.swift` - settings window

## Tech Stack

macOS 15.7+ (Sequoia) minimum, Swift 6, SwiftUI, SwiftNIO (proxy server),
AsyncHTTPClient (upstream), JSON file persistence in
`~/Library/Application Support/ZGate/` (API keys in config.json, not
Keychain; no SwiftData / Core Data).

## Key Paths

| Feature | Entry File |
|---------|-----------|
| App entry | `ModelProxy/App/ModelProxyApp.swift` |
| Proxy server | `ModelProxy/Proxy/ProxyServer.swift` |
| Relay target + signing | `ModelProxy/Proxy/RelayTarget.swift`, `ModelProxy/Signing/` |
| Config models | `ModelProxy/Models/` |
| Views | `ModelProxy/Views/` |

## Document Index

- Architecture: `docs/02-architecture/`
- Decisions (ADRs): `docs/03-decisions/` — start with `2026-11-15-direct-endpoint-relay-connection.md`
- Features: `docs/05-features/`; dev plans: `docs/06-plans/`; changelog: `docs/07-changelog/`
- Lessons learned: `docs/09-lessons-learned/`
- Signing deep-dive: `docs/signing-notes.md`; build log: `docs/zgate-notes.md`
- E2E verification + metering doctrine: `docs/e2e-checklist.md` (AC4 addenda)
- App Store / compliance: `docs/10-app-store-connect/`; crystals: `docs/11-crystals/`

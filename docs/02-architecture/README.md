# Architecture

## Overview

```
Claude Code / Codex
  |
  | HTTP POST /v1/messages   (ANTHROPIC_BASE_URL = localhost:PORT)
  v
+------------------+
|  ProxyServer     |  SwiftNIO HTTP server (localhost)
+------------------+
  |
  | RequestRouter / RoutingSnapshot: exact-match mappings → class rules in
  | config order (time/quota/health conditions) → terminal catch-all
  |
  +---> .relay vendor ("zcode relay") ---> SigningClient chain ---> https://zcode.z.ai/api/v1/ultra-zai/anthropic/v1/messages
  |        (GLM models)                  (~/.zcode store → z/login →     DIRECT endpoint — the local ZCode CLI/GUI
  |                                        project token → handshake →   is never a hop; every request V4-signed,
  |                                        Ed25519 unseal)               unsigned is never sent)
  |
  +---> local vendor (Splash) ---------> http://127.0.0.1:8123
                                          (health-gated; 5xx walks the rule's backups)
```

## Layers

| Layer | Responsibility | Key Types |
|-------|---------------|-----------|
| App | Menu bar lifecycle, SwiftUI scenes | `ModelProxyApp` |
| Views | Popover, settings, quota, stats | `StatusPopover`, `SettingsView` |
| Proxy | HTTP server, routing, targets, relay | `ProxyServer`, `RequestRouter`, `RoutingSnapshot`, `RelayTarget`, `LocalTarget`, `ResponseRelay` |
| Signing | zcode relay auth chain (direct endpoint) | `SigningClient`, `CryptoCore`, `ZaiLoginClient`, `CredentialKeeper`, `BizSessionCache` |
| Services | Config, credentials, quota, stats, splash, web search | `ConfigStore`, `CredentialStore`, `QuotaService`, `TokenStatsStore`, `SplashManager`, `WebSearchBridge` |
| Models | Config, vendor, statistics | `AppConfig`, `Vendor`, `TokenStats` |

## Data Flow

1. **Request in**: NIO channel reads HTTP request → parse JSON body → extract `model` field
2. **Route**: exact-match mappings first, then class rules in config order, terminal catch-all last (first eligible wins; no request is dropped)
3. **Relay target**: SigningClient mints the project token and unseals the handshake key; RelayTarget builds the header set from scratch (client headers never leak upstream), rewrites `model` with a byte-preserving splice, and adds the per-request V4 signing quartet
4. **Local target**: byte-preserving `model` splice only; replay-policy handling per rule
5. **Relay**: stream response bytes back to the client channel (SSE streaming)
6. **Stats**: extract `usage` from response JSON (non-streaming) or final SSE event (streaming), update `TokenStats` (folded input = fresh + cache reads)

## Persistence

- **Config**: `~/Library/Application Support/ZGate/config.json` (renamed from ModelProxy 2026-11-18)
- **Credentials**: shared zcode credential store (`~/.zcode` by default), plus `biz-session.cache` alongside the config
- **Stats**: `token-stats-YYYY-MM-DD.json` (daily relayed-token totals) and `quota-history-YYYY-MM-DD.json` (weekly-window remaining-fraction polls)

# ZGate

macOS menu bar app - transparent local API proxy for multi-vendor model routing.

> **App identity（2026-11-18 改名 ModelProxy → ZGate）：** bundle `local.zgate.mac`，
> 项目 `ZGate.xcodeproj`。源码目录 `ModelProxy/`、os_log subsystem `com.modelproxy.app`、
> 日志文件名仍是旧名 —— 同一个 app，不是两个。
>
> **App Store 2.5 已过审并发布**（2026-08-29T01:13:31Z，中国区仍在架）。合规约束与发布清单在
> `docs/10-app-store-connect/README.md`。⛔ 下次发布前必做：三个 ASC URL 切 norvyn.com
> （清单在同一份 README；ASC store metadata 属上游 model-proxy 开发流程，不在本仓库）。

## Document Truth Source

All project documents use `docs/00-AI-CONTEXT.md` as the single source of truth. This file only provides navigation.

### Quick Reference

| Need... | Look at |
|--------|------|
| Project overview | `docs/00-AI-CONTEXT.md` |
| Project research | `docs/01-discovery/` |
| Architecture | `docs/02-architecture/` |
| Decision rationale | `docs/03-decisions/` |
| Feature behavior | `docs/05-features/` |
| Dev guide / plans | `docs/06-plans/` |
| Change history | `docs/07-changelog/` |
| Lessons learned | `docs/09-lessons-learned/` |
| App Store published pages + compliance | `docs/10-app-store-connect/` |
| Crystallized decisions | `docs/11-crystals/` |

## Document After Completing Features

**Trigger:**
- Completed multi-file feature implementation
- Fixed bugs requiring context understanding
- Made design decisions with trade-offs

**Location:** `docs/05-features/<feature-name>.md`

**Trigger method:** After completion, ask the user; for a full session handoff, prompt the user to run `/handoff` (that skill is `disable-model-invocation`, so the model cannot invoke it itself)

## Project-Specific Constraints

```
Prohibited:
- Modifying API request/response content outside documented routing compatibility transforms
- Storing or logging API request/response bodies
- Listening on non-localhost interfaces

Required:
- All network I/O through SwiftNIO (not URLSession for the proxy server side)
- Streaming (SSE) response relay must forward chunks immediately, no buffering
- SSE response transforms must commit the same guarded/repaired content that is relayed to the client; add regression tests for both relay output and stored lineage data
- API keys stored in ~/Library/Application Support/ZGate/config.json, not Keychain (simplicity for personal tool)
- macOS 15.7+ (Sequoia) minimum deployment target (`MACOSX_DEPLOYMENT_TARGET = 15.7`)
```

## Tech Stack

- macOS 15.7+, Swift 6, SwiftUI
- SwiftNIO + NIOHTTP1 for HTTP proxy server
- AsyncHTTPClient or URLSession for upstream requests
- UserDefaults + JSON for config persistence
- No SwiftData, no Core Data

## Coding Conventions

See `~/.claude/CLAUDE.md` for general rules.

**Project-specific:**
- Menu bar app: use `MenuBarExtra`, no `WindowGroup` for main UI
- Settings: use SwiftUI `Settings` scene
- Config model: `@Observable` classes, JSON Codable
- Proxy layer: pure NIO, no SwiftUI dependencies

## When Confused

1. Check `docs/00-AI-CONTEXT.md` - project overview
2. Check `docs/03-decisions/` - may already have a decision
3. Check `docs/05-features/` - expected behavior and key code locations
4. Check `docs/09-lessons-learned/` - may be a known issue

## Runtime Inspection

The app is **NOT sandboxed** (`ENABLE_APP_SANDBOX = NO`, bundle `local.zgate.mac`).
`AppPaths.appSupport` is plain `~/Library/Application Support/ZGate/` — the shell can
read it directly with `ls`/`head` (verified 2026-11-19):

```
~/Library/Application Support/ZGate/
  ├── config.json                      (vendors, keys)
  ├── token-stats-YYYY-MM-DD.json      (daily relayed-token totals; inputTokens is FOLDED = fresh + cache reads)
  ├── quota-history-YYYY-MM-DD.json    (weekly-window remaining-fraction polls; {timestampMs, fraction} only)
  ├── biz-session.cache                (signing biz JWT; credential material, never log it)
  └── bin/
```

- **No `logs/` directory exists on the current install** (verified 2026-11-19;
  AppLogger/AppLogManager file logging is not active here) and `lineages.json`
  is created lazily only when lineages are recorded — do not expect either on
  disk. The traffic log is an in-memory 500-entry ring (TrafficLog), so
  per-call timestamps/call counts are NOT recoverable from disk.

- **2026-11-18 rename migration:** one-time move of the legacy
  `.../Application Support/ModelProxy/` dir happens in `ModelProxy/App/AppPaths.swift`
  (legacy dir is only touched for that move; if both exist the new one wins).
- **os_log is empty.** Subsystem `com.modelproxy.app` persists nothing
  (`log show --predicate 'subsystem == "com.modelproxy.app"'`). Not a debugging source.
- **Determine a model's route by probing the live proxy, not by guessing:**
  `curl localhost:9090/v1/messages -H 'x-api-key: probe' -H 'anthropic-version: 2023-06-01' -d '{"model":"<m>","max_tokens":8,"messages":[{"role":"user","content":"x"}]}'`
  — an Anthropic-format error (`request_id: req_011C...`) means that model is **passthrough
  to Anthropic**; a different vendor/error means it's mapped. See
  `docs/09-lessons-learned/2026-06-11-proxy-transform-diagnosis.md` for the tool-call transform gating table.
- **Verify proxy behavior end to end with `scripts/e2e/`** (real Claude Code → isolated,
  non-sandboxed E2E build on 19090/19092 → DeepSeek): `build.sh`, `up.sh`, `scenarios.sh`, `down.sh`.
  It never touches the installed app or your own Claude Code config. Rules and scenario list:
  `scripts/e2e/README.md`.

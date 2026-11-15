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
- Entitlements still `ModelProxy/ModelProxy.entitlements` (sandbox + network client/server); `Info.plist` is an empty stub — identity keys come from `GENERATE_INFOPLIST_FILE` build settings (e.g. `INFOPLIST_KEY_CFBundleDisplayName`)

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

# Off-Peak Wave 2 — Settings Toggle, Automatic Status & Rule-Target Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the off-peak surface a first-class citizen: a Settings toggle that applies without restart, automatic window-availability status (polled + surfaced), automatic use of the ticket plane via an explicit per-rule target with fallback, and colored enabled-states for every toggle in the app.

**Architecture:** A new `OffPeakAvailabilityMonitor` service polls the ticket plane's availability endpoint at a bounded 300 s cadence while the surface is enabled (the first poll lazily mints the coding-plan key through the existing `RelayHealth.fallbackKey()` chain). A new `VendorKind.offPeak` makes "off-peak" a rule target like any vendor: `ProxyForwarder` gates requests onto the ticket plane (enabled ∧ window-open ∧ streaming) and falls back to the rule's backup target when any gate fails — interactive traffic never silently queues. The `/async` orchestration core is extracted into a shared `OffPeakTarget.serve` so both surfaces record token stats. All toggles get colored by defining the app's empty `AccentColor` asset.

**Tech Stack:** Swift 6, SwiftUI (`@Observable`), SwiftNIO + AsyncHTTPClient, XCTest-style Testing suites in `ModelProxyTests/` (test target `ZGateTests`).

**Spec:** `docs/06-plans/2026-11-20-offpeak-ui-visibility-brief.md` — the brief this plan argues from. Read it first.

## Global Constraints

- **Never log or print credential material.** API keys/JWTs are redacted (first 8 chars + length) in any log or test output.
- **Plane separation is absolute (wave-1 invariant):** the off-peak plane (`/api/v1/off-peak/*`) is NEVER V4-signed; the relay plane is NEVER unsigned. This wave adds no new signing paths.
- **Content transforms stay within the documented routing-compatibility set** (model substitution, `RelayTarget.canonicalModel`, `max_tokens` clamp, session derivation, endpoint routing). Nothing else touches bodies.
- **Loopback-only proxy; no request/response body storage or logging.** The availability monitor stores `{open|closedUntil|unavailable}` + timestamp only — never response bodies.
- **Interactive traffic must NEVER silently land in the ticket queue.** A request rides the off-peak plane ONLY when all three gates hold (surface enabled, window open per cached status, request has `stream: true`). Any gate failure → the rule's backup target; no backup → a clear Anthropic-shaped 503 (`off_peak_unavailable`). A non-streaming request must NEVER receive `async_stream_required` through a routed rule (that error stays /async-surface-only). The user's compaction lockout (2026-11-20) is this failure mode.
- **Poll cadence:** availability is polled every **300 s** (`OffPeakAvailabilityMonitor.pollIntervalSeconds`), NOT `OffPeakConfig.pollIntervalSeconds` (5 s — that is the in-queue ticket status poll, unchanged).
- **Mint-on-enable is the only new credential action:** the first availability poll after enabling mints the coding-plan key via the existing `RelayHealth.fallbackKey()` lazy chain. No other new mint triggers.
- **Test suite must stay green** (baseline 772 tests). Two known flake classes: RouterTests port-race and OffPeakTargetTests under load — re-run solo before blaming a change (wave-1 history).
- **Verification never touches the user's Claude Code config or the installed app.** Live behavior checks use the E2E harness (`scripts/e2e/`) or a fresh build in DerivedData — never `~/.claude` and never the running ZGate.
- `ProxyServer.updateRouting` (ModelProxy/Proxy/ProxyServer.swift:541) already hot-pushes `config.offPeak` into the live context via `offPeakContext?.updateConfiguration` — enable/disable already applies without restart on the next request. Do NOT rebuild the context on config change; only the monitor start/stop is new.
- Conventions: os_log via `AppLog.proxy`, comments in the surrounding style (dense, why-first), commits follow the repo's `feat:/fix:/docs:` style. Test files live in `ModelProxyTests/`, suites run under the `ZGateTests` target — `-only-testing:ZGateTests/<Suite>`, NOT `ModelProxyTests/` (matches no target).

**User decisions (already made):**

- Auto-routing shape: **"Rule target"** — off-peak is a target kind attached to chosen routing rules; matching traffic rides the ticket plane when the window is open and falls back to the rule's normal target when closed. (AskUserQuestion 2026-11-20.)
- Key mint: **"Mint on enabling"** — turning the toggle ON mints the key if absent and starts the 5-min availability poll; the status line is real from the first minute. (AskUserQuestion 2026-11-20.)
- Wave-1 precedent carries: in-place on `main` (user declined worktree), Settings UI minimal (enabled + status only; advanced knobs stay config-file-only).
- User warning 2026-11-20: "be careful during async off peak work, not to lock yourself out" — nothing this wave does may reconfigure the user's Claude Code or route their interactive traffic unattended.

## Review Focus

1. **Non-streaming request routed to an off-peak rule** (compaction-class call) → must be served by the rule's backup target, never `async_stream_required`, never queued. Test: Task 4 (`routeOffPeakNonStreamRequestFallsBackToBackup`).
2. **Off-peak vendor row deleted by hand while a rule still references it** → rule goes inert (existing vendor-lookup guard), no crash, other rules unaffected. Test: Task 2 (`snapshotSkipsRuleWhoseOffPeakVendorWasDeleted`).
3. **Toggle flipped OFF while a poll is in flight / orchestration running** → poll loop stops, in-flight orchestration completes on its captured config; re-enabling restarts polling. Test: Task 5 (`updateRoutingStopsAndRestartsMonitorWithToggle`).
4. **Seeding must not duplicate or resurrect** — second launch with marker set seeds nothing; user-deleted off-peak vendor stays deleted. Test: Task 2 (once/twice marker pattern from `ConfigMigrationTests.swift:456-533`).
5. **Window closes between polls (stale open cache)** → the request enters orchestration, whose existing tolerance ladder (`maxWaitExceeded`/`controlFailuresExceeded`) bounds it and answers a client-visible error; no infinite hang. Pinned by existing `OffPeakTargetTests` ladder tests — Task 4 must NOT bypass orchestration's own bounds (AC: gates consult only the cached monitor status; no request-time availability call is added to the hot path).

---

### Task 1: OffPeakAvailabilityMonitor service

**Goal:** A polled, thread-safe availability-status service exposing a UI display string and a cached `isWindowOpen` for the forwarder.

**Files:**
- Create: `ModelProxy/Services/OffPeakAvailabilityMonitor.swift`
- Test: `ModelProxyTests/OffPeakAvailabilityMonitorTests.swift`

**Acceptance Criteria:**
- [ ] `OffPeakAvailabilityMonitor` is `@Observable final class … @unchecked Sendable` with NSLock-guarded status; status enum: `idle`, `open`, `closedUntil(Date)`, `unavailable(String)`.
- [ ] `start()` is idempotent (second call while running is a no-op), probes immediately, then every `pollIntervalSeconds` (300).
- [ ] Probe success `can_take_number == true` → `.open`; false → `.closedUntil(Date(timeIntervalSince1970: Double(nextTakeAtSeconds)))`.
- [ ] Probe throw → `.unavailable(String(describing:))` and the loop CONTINUES polling (fail-open status, no crash, no stop).
- [ ] `stop()` cancels the loop and resets status to `.idle`.
- [ ] `isWindowOpen` is `true` only for `.open`; readable from any thread (lock, no await).
- [ ] `displayString`: idle → "Off", open → "Window open", closedUntil → "Closed until HH:mm" (via `date.formatted(date: .omitted, time: .shortened)` — Sendable, no DateFormatter cache), unavailable → "Unavailable (…)".
- [ ] Cancellation (`stop()` during injected sleep) exits the loop cleanly — no status overwrite after stop.

**Verify:** `xcodebuild test -project ZGate.xcodeproj -scheme ZGate -destination 'platform=macOS' -only-testing:ZGateTests/OffPeakAvailabilityMonitorTests` → all pass.

**Steps:**

- [ ] **Step 1: Write the failing tests** — inject the probe as `@Sendable () async throws -> OffPeakAvailability` and sleep as `@Sendable (TimeInterval) async throws -> Void` (mirror `OffPeakTarget.defaultSleep` injection). Tests drive sequences (open → closed → error → open) by stepping a shared queue inside the fake sleep:

```swift
import Testing
@testable import ModelProxy

@Suite("OffPeakAvailabilityMonitor")
struct OffPeakAvailabilityMonitorTests {

    /// Sleep that never ticks the clock: records the requested delay and
    /// returns immediately. Tests sequence probe results between sleeps.
    private final class SleepGate: @unchecked Sendable {
        private let lock = NSLock(); private var delays: [TimeInterval] = []
        func sleep(_ d: TimeInterval) throws { lock.lock(); defer { lock.unlock() }; delays.append(d) }
        var delayCount: Int { lock.lock(); defer { lock.unlock() }; return delays.count }
    }

    @Test("open then closedUntil statuses surface and poll cadence is 300s")
    func statusesAndCadence() async {
        let gate = SleepGate()
        let results: Nonisolated(unsafe) var queue: [Result<OffPeakAvailability, Error>] = [
            .success(OffPeakAvailability(canTakeNumber: true, nextTakeAtSeconds: nil)),
            .success(OffPeakAvailability(canTakeNumber: false, nextTakeAtSeconds: 1_764_000_000)),
        ]
        let monitor = OffPeakAvailabilityMonitor(
            probe: { try queue.removeFirst().get() },
            sleep: { try gate.sleep($0) })
        monitor.start()
        // Polling loop runs on a child task; give it the two probes + one sleep.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(monitor.isWindowOpen == true)
        #expect(monitor.displayString == "Window open")
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(monitor.isWindowOpen == false)
        #expect(monitor.displayString.hasPrefix("Closed until "))
        monitor.stop()
        #expect(monitor.displayString == "Off")
    }

    @Test("probe error becomes unavailable and polling continues")
    func failOpenStatus() async { /* same harness; queue = [.failure(URLError(.timedOut)), .success(open)]; expect "Unavailable (" then "Window open" */ }

    @Test("start is idempotent and stop during sleep exits cleanly")
    func startStopLifecycle() async { /* monitor.start(); monitor.start(); one sleep; monitor.stop() mid-sleep; expect idle, no later mutation */ }
}
```

(Write the two comment-bodied tests out fully in the real file — same harness, stated expectations.)

- [ ] **Step 2: Run** → FAIL (type does not exist).
- [ ] **Step 3: Implement** — note `OffPeakAvailability` field names from `ModelProxy/Services/OffPeakTicketClient.swift:32` (`canTakeNumber`, `nextTakeAtSeconds`) — verify before compiling:

```swift
import Foundation
import Observation

/// Server-driven off-peak window status, polled at a bounded cadence while
/// the surface is enabled (wave 2). Two consumers: the UI (displayString,
/// @Observable) and ProxyForwarder's off-peak gate (isWindowOpen, cached —
/// NEVER a request-time availability call on the hot path).
@Observable
final class OffPeakAvailabilityMonitor: @unchecked Sendable {

    enum Status: Equatable, Sendable {
        case idle
        case open
        case closedUntil(Date)
        case unavailable(String)
    }

    /// Availability poll cadence. NOT OffPeakConfig.pollIntervalSeconds
    /// (5 s — the in-queue ticket status poll); this is the idle-window
    /// health poll. Bounded: no exponential growth, no polling when stopped.
    static let pollIntervalSeconds: TimeInterval = 300

    private let lock = NSLock()
    private var statusValue: Status = .idle
    private var pollTask: Task<Void, Never>?
    private let probe: @Sendable () async throws -> OffPeakAvailability
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    init(probe: @escaping @Sendable () async throws -> OffPeakAvailability,
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = OffPeakTarget.defaultSleep) {
        self.probe = probe
        self.sleep = sleep
    }

    var status: Status { lock.lock(); defer { lock.unlock() }; return statusValue }
    var isWindowOpen: Bool { if case .open = status { return true }; return false }

    var displayString: String {
        switch status {
        case .idle: return "Off"
        case .open: return "Window open"
        case .closedUntil(let date): return "Closed until \(date.formatted(date: .omitted, time: .shortened))"
        case .unavailable(let reason): return "Unavailable (\(reason))"
        }
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard pollTask == nil else { return }   // idempotent
        pollTask = Task { [probe, sleep] in
            await self.runLoop(probe: probe, sleep: sleep)
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        pollTask?.cancel()
        pollTask = nil
        statusValue = .idle
    }

    private func runLoop(probe: @Sendable () async throws -> OffPeakAvailability,
                         sleep: @Sendable (TimeInterval) async throws -> Void) async {
        while !Task.isCancelled {
            do {
                let availability = try await probe()
                if Task.isCancelled { return }
                if availability.canTakeNumber {
                    setStatus(.open)
                } else if let next = availability.nextTakeAtSeconds {
                    setStatus(.closedUntil(Date(timeIntervalSince1970: Double(next))))
                } else {
                    setStatus(.unavailable("availability false without next_take_at"))
                }
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                setStatus(.unavailable(String(describing: error)))
                // fail-open status: keep polling on the fixed cadence
            }
            do { try await sleep(Self.pollIntervalSeconds) } catch { return }
        }
    }

    private func setStatus(_ new: Status) {
        lock.lock(); defer { lock.unlock() }
        guard pollTask != nil else { return }   // stopped mid-flight: no zombie writes
        statusValue = new
    }
}
```

(If `@Observable` + `@unchecked Sendable` fights the macro's isolation under the project's Swift 6 settings, mirror exactly how `QuotaService` is declared — read `ModelProxy/Services/QuotaService.swift` first and match it. The observable surface is for the two views in Task 6.)

- [ ] **Step 4: Run** → PASS. **Step 5:** `git add ModelProxy/Services/OffPeakAvailabilityMonitor.swift ModelProxyTests/OffPeakAvailabilityMonitorTests.swift && git commit -m "feat(offpeak): availability monitor service — polled window status with fail-open cache"`

---

### Task 2: VendorKind.offPeak + run-once seeded vendor

**Goal:** Off-peak becomes a vendor-kind target: enum case, a seeded "ZCode Off-Peak" vendor row (migration-11, run-once marker mirroring `fallbackEdgeSeeded`), and RoutingSnapshot flow proof.

**Files:**
- Modify: `ModelProxy/Models/Vendor.swift:4-10` (enum), `ModelProxy/Models/AppConfig.swift` (`offPeakVendorSeeded` marker + CodingKeys, mirroring `fallbackEdgeSeeded` at :134/:155/:168/:185/:218), `ModelProxy/Services/ConfigStore.swift:247-282` (seeding block after migration 10)
- Test: `ModelProxyTests/ConfigMigrationTests.swift` (append), new small suite section in `ModelProxyTests/RouterTests.swift` (or a focused `OffPeakRoutingSnapshotTests.swift`)

**Acceptance Criteria:**
- [ ] `enum VendorKind` gains `case offPeak` (rawValue `"offPeak"`) with a why-first doc comment: ticket-plane target, configured API key unused, origin comes from `OffPeakConfig`.
- [ ] Migration 11 in `ConfigStore`'s migration chain: FIRST application only (gated by `offPeakVendorSeeded`): if no vendor with `vendorKind == .offPeak` exists, append one; set the marker. Second application with the marker set does nothing — including NOT resurrecting a user-deleted row.
- [ ] Seeded row: `Vendor(name: "ZCode Off-Peak", baseURL: OffPeakConfig.defaultOrigin, apiKey: "", connectTimeoutSeconds: 15, readTimeoutSeconds: 4500, supportsThinkingBlocks: true, stripsClaudeOnlyRequestFields: true, applyGLMCanonicalization: true, vendorKind: .offPeak)` (read timeout = `maxWaitMinutes` 60 × 60 + 30 min headroom, matching the async plane's bound in `OffPeakTarget.swift:72`).
- [ ] `RoutingSnapshot(from:for:)` resolves a rule whose `targetVendorID` is the off-peak vendor to a `RouteTarget` with `vendorKind == .offPeak` and the rule's `targetModel` — no snapshot code change expected (it copies `vendor.vendorKind` at :169); the test pins the flow.
- [ ] A rule whose off-peak vendor row was deleted is skipped by the snapshot (existing guard at RoutingSnapshot.swift:150) — pinned by test.
- [ ] Decoding a legacy config without `offPeakVendorSeeded` defaults the marker false; encoding omits it when false (mirror the `fallbackEdgeSeeded` wire shape).

**Verify:** `xcodebuild test -project ZGate.xcodeproj -scheme ZGate -destination 'platform=macOS' -only-testing:ZGateTests/ConfigMigrationTests` → all pass, including the two new tests.

**Steps:**

- [ ] **Step 1: Failing tests** (append to `ConfigMigrationTests.swift`, copying the once/twice harness at :456-533):

```swift
@Test("migration 11 seeds the off-peak vendor once and never resurrects")
func migration11SeedsOffPeakVendorOnce() async throws {
    var c = AppConfig.loadOrDefaultFixture()          // same fixture style as :456
    c.offPeakVendorSeeded = false
    c.vendors.removeAll { $0.vendorKind == .offPeak }
    let once = applyMigrations(c)
    #expect(once.vendors.contains { $0.vendorKind == .offPeak })
    #expect(once.offPeakVendorSeeded == true)
    let deleted = once
    var d = deleted
    d.vendors.removeAll { $0.vendorKind == .offPeak } // user deletes the row
    let twice = applyMigrations(d)
    #expect(!twice.vendors.contains { $0.vendorKind == .offPeak })  // stays deleted
}

@Test("snapshot routes an off-peak rule target with the rule's model")
func snapshotRoutesOffPeakVendor() {
    // Build AppConfig with one client, one offPeak vendor, one mapping
    // sourceModel "batch-model" → offPeak vendor, targetModel "glm-5.3-flash".
    // resolve(model: "batch-model") → .routed(target) with
    // target.vendorKind == .offPeak && target.targetModel == "glm-5.3-flash".
    // Then delete the vendor row → resolve falls through to unmapped policy
    // (rule inert), and no crash.
}
```

(Use the existing migration-test entry point — check how :456-533 invokes the migration chain and call the same function; write both tests fully.)

- [ ] **Step 2: Run** → FAIL (no `offPeak` case, no marker).
- [ ] **Step 3: Implement** — enum case; marker field + CodingKeys + decodeIfPresent-default-false + encode-only-when-true (copy the `fallbackEdgeSeeded` treatment verbatim); seeding block appended after migration 10 in `ConfigStore.swift`:

```swift
// Migration 11 (off-peak wave 2, 2026-11-20): seed the off-peak rule
// target vendor. FIRST application only (gated by `offPeakVendorSeeded`,
// same contract as migration 10): a user-deleted row stays deleted. The
// row is inert until the user attaches it to a routing rule — seeding it
// changes no routing by itself.
if !config.offPeakVendorSeeded {
    if !config.vendors.contains(where: { $0.vendorKind == .offPeak }) {
        config.vendors.append(Vendor(
            name: "ZCode Off-Peak",
            baseURL: OffPeakConfig.defaultOrigin,
            apiKey: "",
            connectTimeoutSeconds: 15,
            readTimeoutSeconds: 4500,
            supportsThinkingBlocks: true,
            stripsClaudeOnlyRequestFields: true,
            applyGLMCanonicalization: true,
            vendorKind: .offPeak))
    }
    config.offPeakVendorSeeded = true
}
```

- [ ] **Step 4: Run** → PASS (new + existing ConfigMigrationTests). Also run `-only-testing:ZGateTests/RouterTests` solo (port-race flake class). **Step 5:** commit `feat(offpeak): VendorKind.offPeak + run-once seeded target vendor (migration 11)`.

---

### Task 3: Extract shared OffPeakTarget.serve + token stats on /async

**Goal:** Split `handle`'s POST core into `serve(...)` reusable by the forwarder, and wire `TokenStatsStore` so both surfaces record usage (today /async usage is traffic-row-only).

**Files:**
- Modify: `ModelProxy/Proxy/OffPeakTarget.swift:687-810` (`handle` → thin route gate + delegate), `ModelProxy/Proxy/ProxyChannelHandler.swift:110-123` (pass `tokenStatsStore`)
- Test: `ModelProxyTests/OffPeakTargetTests.swift` (append)

**Acceptance Criteria:**
- [ ] `handle` keeps ONLY: health endpoint, enabled/method/path gate, then delegates to the new `serve`.
- [ ] New `static func serve(head: HTTPRequestHead, body: ByteBuffer, channel: any Channel, context: Context, targetModel: String?, trafficLog: TrafficLog?, tokenStatsStore: TokenStatsStore?, vendorID: UUID?, requestID: String) async -> State?` — body size cap, JSON object check, `stream == true` check, model splice (`targetModel ?? raw` then `RelayTarget.canonicalModel`), orchestration, cancellation bridge, traffic row — all moved verbatim from today's `handle` body (`OffPeakTarget.swift:698-810`).
- [ ] On `/async`, `targetModel` is nil (behavior byte-identical to today — existing tests must pass unchanged).
- [ ] `tokenStatsStore` non-nil → the `onUsage` callback records `tokenStatsStore.add(vendorID: vendorID ?? UUID.zeroOrNilKeying, model: canonicalModel, input: …, output: …, cacheRead: …, sourceModel: rawModel)`; nil vendorID (the /async face) keys stats the same way the passthrough path does — read `ProxyForwarder.swift:536-541` for the exact convention and mirror it (an all-zero UUID or the vendor-name string — whichever the store already uses for vendorless rows; do not invent a new keying).
- [ ] `ProxyChannelHandler` passes its captured `tokenStatsStore` (:95) into `handle`.
- [ ] Existing `OffPeakTargetTests` all pass unchanged.

**Verify:** `xcodebuild test -project ZGate.xcodeproj -scheme ZGate -destination 'platform=macOS' -only-testing:ZGateTests/OffPeakTargetTests` → all pass (existing + 1 new stats test).

**Steps:**

- [ ] **Step 1: Failing test** — served /async request (existing local test-server harness from `OffPeakTargetTests`) with a `TokenStatsStore` pointed at a temp dir (mirror how `ProxyForwarderTests` builds one, `ProxyForwarderTests.swift:359` region) → after the response, the day's stats file contains an entry with the request's model and non-zero output tokens.

```swift
@Test("served async request records token usage")
func asyncServeRecordsTokenStats() async throws {
    // Local ticket+data plane stub server (reuse the existing OffPeakTargetTests
    // stub classes), TokenStatsStore in a temporary directory, one streaming
    // request with a usage-bearing final SSE event. After serve completes:
    // read the store's JSON for today; expect one row for the canonical model
    // with outputTokens > 0 and inputTokens > 0.
}
```

- [ ] **Step 2: Run** → FAIL (no stats recorded). **Step 3: Implement** the split + wiring described above; behavior moved verbatim (this is a refactor — the diff should read as motion plus the two splices: `targetModel` in the model substitution, `tokenStatsStore` in onUsage). **Step 4: Run** → PASS. **Step 5:** commit `refactor(offpeak): extract serve() core; wire token stats for the async surface`.

---

### Task 4: ProxyForwarder off-peak dispatch with gated fallback

**Goal:** Route requests whose matched target is the off-peak vendor: all gates pass → `OffPeakTarget.serve`; any gate fails → the rule's backup target; no backup → clear 503.

**Files:**
- Modify: `ModelProxy/Proxy/ProxyForwarder.swift:433-470` (dispatch; new branch before the relay branch), `ModelProxy/Proxy/ProxyChannelHandler.swift:125-143` (pass `offPeak` context + monitor into `forward`), `ModelProxy/Proxy/ProxyServer.swift:388` (pass monitor to handler — after Task 5 creates it; if executing before Task 5 lands, thread the param as optional and wire the non-nil value in Task 5)
- Test: `ModelProxyTests/ProxyForwarderTests.swift` (append)

**Acceptance Criteria:**
- [ ] `ProxyForwarder.forward` gains `offPeakContext: OffPeakTarget.Context?` and `offPeakMonitor: (any OffPeakAvailabilityMonitoring)?` params (introduce a tiny protocol `OffPeakAvailabilityMonitoring { var isWindowOpen: Bool { get } }` so tests stub the gate without a live monitor; the monitor conforms in Task 1's file).
- [ ] Dispatch branch (`else if target.vendorKind == .offPeak, let offPeakContext`): gates = `offPeakContext.configuration().enabled && (offPeakMonitor?.isWindowOpen ?? false) && Self.requestIsStream(forwardBodyData)`.
- [ ] All gates pass → `await OffPeakTarget.serve(head: head, body: body-ByteBuffer, channel: channel, context: offPeakContext, targetModel: target.targetModel, trafficLog: trafficLog, tokenStatsStore: tokenStatsStore, vendorID: target.vendorID, requestID: requestID)` then RETURN — same channel-writing contract as the LocalTarget branch (study `streamsViaLocalRelay` at :447-470 and follow it; the body ByteBuffer must be reconstituted from `forwardBodyData` via `ByteBuffer(data:)`).
- [ ] Any gate fails → resolve the backup via `router.targets(for: model)` (the existing pattern at :1005-1017) and re-dispatch into the normal non-off-peak path with the backup target (relay branch if `.relay`, else default upstream send). A short `AppLog.proxy.info` states which gate failed and the fallback target — no body content, model name only.
- [ ] No backup exists → `ProxyForwarder.sendAnthropicError(channel:, status: .serviceUnavailable, type: "off_peak_unavailable", message: "The off-peak window is closed and this rule has no backup target.")` and return.
- [ ] `static func requestIsStream(_ data: Data) -> Bool` helper (JSON-parse, `stream == true`; same tolerance as OffPeakTarget.swift:740) with unit coverage.
- [ ] Tests (local NIO stub servers, `ProxyForwarderTests` harness):
  - `routeOffPeakNonStreamRequestFallsBackToBackup` — non-stream body, window open, backup stub answers → client gets backup's 200, backup received the request.
  - `routeOffPeakWindowClosedFallsBackToBackup` — stream body, `isWindowOpen == false` → backup serves.
  - `routeOffPeakDisabledSurfaceFallsBackToBackup` — `enabled == false` in the context config → backup serves.
  - `routeOffPeakNoBackupAnswers503` — gates fail, single-target rule → 503 `off_peak_unavailable`.
  - `routeOffPeakGatesOpenServesViaTicketPlane` — gates pass, off-peak stub (reuse OffPeakTargetTests stub classes for the ticket/data plane) → client gets the SSE stream; token stats row recorded under the off-peak vendor ID.

**Verify:** `xcodebuild test -project ZGate.xcodeproj -scheme ZGate -destination 'platform=macOS' -only-testing:ZGateTests/ProxyForwarderTests` → all pass.

**Steps:**

- [ ] **Step 1: Write the five failing tests** using the suite's existing stub-server builders; the off-peak gate stub conforms to `OffPeakAvailabilityMonitoring`. **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** the protocol (place it in `OffPeakAvailabilityMonitor.swift`, Task 1's file: `protocol OffPeakAvailabilityMonitoring: Sendable { var isWindowOpen: Bool { get } }`; monitor conforms), the helper, the dispatch branch, the `ProxyChannelHandler` param threading (`offPeak: offPeakContext, offPeakMonitor: offPeakMonitor` captured and passed like `relayContext`), matching `forward`'s signature growth.
- [ ] **Step 4: Run** → PASS; also run `ModelProxyTests/ProxySessionIntegrationTests` (integration seams touched). **Step 5:** commit `feat(offpeak): forwarder rule-target dispatch — gated ticket-plane use with backup fallback`.

---

### Task 5: ProxyServer monitor wiring + no-restart toggle

**Goal:** Build/start/stop the availability monitor with the live toggle — proving Settings flips apply without restart; mint-on-enable falls out of the first poll.

**Files:**
- Modify: `ModelProxy/Proxy/ProxyServer.swift:303-326` (build monitor beside the context in `start`), `:541-571` (`updateRouting` start/stop), expose `private(set) var offPeakMonitor: OffPeakAvailabilityMonitor?`
- Test: `ModelProxyTests/OffPeakMonitorWiringTests.swift` (new, or append to `ProxySessionIntegrationTests`)

**Acceptance Criteria:**
- [ ] In `start`, right after the `offPeakContext` build block (:311-325): if `config.offPeak.enabled`, build the monitor with `probe: { [weak offPeakContext] … try await ctx.makeTicketClient().availability() }` and `start()` it.
- [ ] In `updateRouting` after `offPeakContext?.updateConfiguration(config.offPeak)`: enabled && monitor exists → `start()`; enabled && monitor nil && context exists → build + start; disabled → `stop()`. (Idempotent by Task 1.)
- [ ] The probe chain gives mint-on-enable for free: `makeTicketClient().availability()` → `authMaterial()` → `credentialProvider` → `RelayHealth.fallbackKey()` — verify by reading, no new mint code; note the reading in the commit body.
- [ ] Test: server started with `offPeak.enabled = false` → `updateRouting(config with enabled = true)` → within a stubbed window the monitor status leaves `.idle` (inject the probe via a test seam: `ProxyServer` gains an internal `offPeakProbeOverride` used only when non-nil — mirrors how tests inject `quotaProvider` at :356); `updateRouting(enabled = false)` → status back to `.idle` and no further polls (probe call count freezes).
- [ ] When the server restarts (`stop()` then `start`), the monitor is rebuilt (its task died with stop) — `stop()` also nils `offPeakMonitor`.

**Verify:** `xcodebuild test -project ZGate.xcodeproj -scheme ZGate -destination 'platform=macOS' -only-testing:ZGateTests/OffPeakMonitorWiringTests` → pass, and `-only-testing:ZGateTests/ProxySessionIntegrationTests` stays green.

**Steps:**

- [ ] **Step 1: Failing test** (call-counting probe override; count 0 → enable via `updateRouting` → count ≥ 1 → disable → wait one poll interval → count unchanged).
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement** the wiring exactly as the AC describes (the `quotaProvider` injection at ProxyServer.swift:350-358 is the seam pattern to copy). **Step 4: Run** → PASS. **Step 5:** commit `feat(offpeak): monitor lifecycle rides the live toggle — enable/disable without restart`.

---

### Task 6: Settings Off-Peak section + StatusPopover status row

**Goal:** The toggle the user asked for, with the automatic status line, in Settings and the popover; rule editor guards off-peak-primary-without-backup.

**Files:**
- Modify: `ModelProxy/Views/GeneralTabView.swift` (new Section after `credentialsSection`), `ModelProxy/Views/StatusPopover.swift:367-395` (new section after `credentialSection`), `ModelProxy/Views/SettingsView.swift` (`RuleEditorSheet` save validation)
- Test: covered by Task 1 (displayString) + build; UI is visually verified at swap time

**Acceptance Criteria:**
- [ ] `GeneralTabView` gains `Section("Off-Peak")`: the enabled `Toggle` bound `get: configStore.config.offPeak.enabled / set: { configStore.config.offPeak.enabled = $0; configStore.saveAndReload(proxyServer: proxyServer) }` (the pattern at GeneralTabView.swift:18-28 and SettingsView.swift:387-397) with a two-line label: "Use ZCode off-peak compute" + the live status (`proxyServer.offPeakMonitor?.displayString ?? "Off"`, `.callout`, `.secondary`).
- [ ] A caption under the toggle: "Rules targeting the “ZCode Off-Peak” vendor ride the ticket plane while the window is open, and use their backup target otherwise. Enabling mints the coding-plan key on the first availability check." (`.caption`, `.secondary`).
- [ ] No advanced knobs in the UI (origin/maxWait/poll/keepalive stay config-file-only — user decision).
- [ ] `StatusPopover` gains `offPeakSection` (between `credentialSection` and the next section): rendered only when `configStore.config.offPeak.enabled`; a one-line status chip mirroring `credentialSection`'s weight — "Off-Peak: Window open" in `.green`, "Off-Peak: Closed until HH:mm" / "Off-Peak: Unavailable (…)" in `.secondary`.
- [ ] `RuleEditorSheet` save validation: when the primary vendor's `vendorKind == .offPeak` and no backup vendor is selected, block save with the sheet's existing error presentation and message "An off-peak primary target needs a backup target for the closed-window fallback."
- [ ] Vendors tab renders the off-peak row read-only-friendly: hide the API-key field for `.offPeak` (mirror however `.relay` hides it — check `VendorsTabView`/`VendorEditSheet` for the relay treatment and match).

**Verify:** `xcodebuild build -project ZGate.xcodeproj -scheme ZGate -destination 'platform=macOS'` → BUILD SUCCEEDED; full suite still green.

**Steps:**

- [ ] **Step 1: Implement the three view changes** (code above; read `credentialSection` at StatusPopover.swift:367-395 first and copy its chip styling; read `RuleEditorSheet`'s existing save-validation path and reuse its error presentation).
- [ ] **Step 2: Build + full test suite** (`xcodebuild test -project ZGate.xcodeproj -scheme ZGate -destination 'platform=macOS'`) → green.
- [ ] **Step 3:** commit `feat(ui): off-peak Settings section, popover status row, rule-editor backup guard`.

---

### Task 7: Define the AccentColor asset — colored enabled-states

**Goal:** Every toggle in the app shows a colored ON state by defining the app accent (today the asset is empty, so switches inherit the system accent — grey under Graphite).

**Files:**
- Modify: `ModelProxy/Assets.xcassets/AccentColor.colorset/Contents.json`

**Acceptance Criteria:**
- [ ] Universal light color `#087AFF` (sRGB 0.031, 0.479, 1.000) + dark-appearance color `#0A84FF` (sRGB 0.039, 0.522, 1.000) — macOS system blue values, so the app reads native; a user on Multicolor sees the same blue they expect, and a Graphite user finally sees ON states colored.
- [ ] `plutil -lint ModelProxy/Assets.xcassets/AccentColor.colorset/Contents.json` → OK.
- [ ] Build succeeds; no per-view `.tint` churn (the asset colors ALL switches, checkboxes, links, and focused rings app-wide — that single point is the fix; the 15 `Toggle(` sites in `ModelProxy/Views/` need no edits).
- [ ] `LogViewerView.swift:88` keeps `.toggleStyle(.checkbox)` (its checkmark inherits the accent) — no style conversions in this task.

**Verify:** `plutil -lint ModelProxy/Assets.xcassets/AccentColor.colorset/Contents.json && xcodebuild build -project ZGate.xcodeproj -scheme ZGate -destination 'platform=macOS'` → OK + BUILD SUCCEEDED.

**Steps:**

- [ ] **Step 1: Write** the Contents.json:

```json
{
  "colors" : [
    {
      "color" : {
        "color-space" : "srgb",
        "components" : { "alpha" : "1.000", "blue" : "1.000", "green" : "0.479", "red" : "0.031" }
      },
      "idiom" : "universal"
    },
    {
      "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ],
      "color" : {
        "color-space" : "srgb",
        "components" : { "alpha" : "1.000", "blue" : "1.000", "green" : "0.522", "red" : "0.039" }
      },
      "idiom" : "universal"
    }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
```

- [ ] **Step 2: Lint + build.** **Step 3:** commit `fix(ui): define app AccentColor — colored enabled-state for all toggles`.

---

### Task 8: Docs, README matrix, CHANGELOG draft

**Goal:** Document the new surface truth: automatic status, rule-target routing + fallback semantics, mint-on-enable, and the unverified-billing watch note.

**Files:**
- Modify: `docs/05-features/` off-peak feature doc (wave-1 file — locate by `grep -rl "off-peak" docs/05-features/`), `README.md` (routing matrix + v2.10 off-peak paragraph), `CHANGELOG.md` (Unreleased section)

**Acceptance Criteria:**
- [ ] Feature doc gains: monitor cadence (300 s) + status meanings; the three gates and the fallback table (gate failed → backup; no backup → 503 `off_peak_unavailable`); non-streaming requests NEVER queue (compaction lockout note, 2026-11-20); mint-on-enable; the seeded vendor + rule attachment workflow; advanced knobs remain config-only; "billing on the ticket plane is UNVERIFIED — watch the quota monitor (`quota-history-*.json`) across the first auto-routed window before treating it as free."
- [ ] README routing matrix: off-peak target row (window open → ticket plane; closed/non-stream/disabled → rule backup); the v2.10 off-peak paragraph updated to describe Settings + auto status (no longer "config-only, manual /async").
- [ ] CHANGELOG: Unreleased section listing toggle (no-restart), availability status + popover row, rule-target routing with fallback, colored toggles, token stats on /async.
- [ ] No credential material anywhere in the docs.

**Verify:** `grep -rn "off-peak\|offPeak" README.md CHANGELOG.md docs/05-features/ | wc -l` → non-zero and each named section present by reading.

**Steps:**

- [ ] **Step 1: Write the docs** per AC. **Step 2: Self-check** the four named sections exist. **Step 3:** commit `docs: off-peak wave 2 — settings toggle, auto status, rule-target routing`.

---

## Execution notes

- Execute **in place on `main`** (user decision, wave-1 precedent). Ledger in the SDD workspace per the skill.
- Task order is dependency-safe as listed (1 → 2 → 3 → 4 → 5 → 6; 7 independent; 8 last). Task 4's handler threading notes the Task-5 seam explicitly.
- Final review: whole-branch `git diff <wave-2-base>..HEAD` review per the SDD skill, plus a full-suite run.
- Release (version bump, notarize, swap) is a follow-on the user drives — not part of this plan.

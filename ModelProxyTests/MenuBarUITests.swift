import Foundation
import Testing
@testable import ZGate

/// Task 9 menu-bar UI — testable logic only (state selection, row
/// formatting, rule-editor validation/round-trip, alert + env-line
/// formation, cap behavior). Layout is covered by the seeded-debug-menu
/// smoke, not here.
@Suite
struct MenuBarUITests {

    // MARK: - Quota display state

    @Test("no-data state: nil snapshot wins over staleness — never 0%, never stale")
    func noDataSelection() {
        let state = QuotaDisplayState.make(snapshot: nil, stale: true)
        #expect(state == .noData)
        #expect(state.fraction == nil)
        #expect(state.percentText == nil)
        #expect(state.isStale == false)
        #expect(state.menuBarTitle == "ZΓ")
    }

    @Test("stale state keeps the last-known fraction and dims")
    func staleSelection() {
        let snapshot = QuotaSnapshot(fractionRemaining: 0.42, fetchedAt: Date())
        let state = QuotaDisplayState.make(snapshot: snapshot, stale: true)
        #expect(state == .available(fraction: 0.42, stale: true))
        #expect(state.fraction == 0.42)
        #expect(state.isStale == true)
        #expect(state.percentText == "42%")
    }

    @Test("fraction is clamped into 0...1 on display")
    func clamping() {
        let over = QuotaDisplayState.make(
            snapshot: QuotaSnapshot(fractionRemaining: 1.7, fetchedAt: Date()), stale: false)
        #expect(over.fraction == 1)
        let under = QuotaDisplayState.make(
            snapshot: QuotaSnapshot(fractionRemaining: -0.2, fetchedAt: Date()), stale: false)
        #expect(under.fraction == 0)
    }

    @Test("percent text rounds to whole percent")
    func percentText() {
        let state = QuotaDisplayState.make(
            snapshot: QuotaSnapshot(fractionRemaining: 0.6324, fetchedAt: Date()), stale: false)
        #expect(state.percentText == "63%")
        #expect(state.menuBarTitle == "ZΓ 63%")
    }

    // MARK: - Per-window rows + countdown (Package A)

    @Test("display state carries the snapshot's per-window rows")
    func windowsCarriedThroughDisplayState() {
        let snapshot = QuotaSnapshot(fractionRemaining: 0.42, fetchedAt: Date(), windows: [
            QuotaWindow(kind: .weeklyTokens, fractionRemaining: 0.42, resetsAt: nil),
            QuotaWindow(kind: .fiveHourTokens, fractionRemaining: 0.6, resetsAt: nil),
        ])
        guard case let .available(_, _, windows) = QuotaDisplayState.make(snapshot: snapshot, stale: false)
        else {
            Issue.record("expected available")
            return
        }
        #expect(windows.map(\.kind) == [.weeklyTokens, .fiveHourTokens])
    }

    @Test("countdown text is compact, floors units, and refuses past moments")
    func countdownText() {
        let now = Date(timeIntervalSince1970: 1_763_000_000)
        #expect(QuotaCountdown.text(until: now.addingTimeInterval(2 * 86400 + 4 * 3600), now: now) == "2d 4h")
        #expect(QuotaCountdown.text(until: now.addingTimeInterval(3 * 3600 + 5 * 60), now: now) == "3h 5m")
        #expect(QuotaCountdown.text(until: now.addingTimeInterval(12 * 60), now: now) == "12m")
        #expect(QuotaCountdown.text(until: now.addingTimeInterval(45), now: now) == "<1m")
        #expect(QuotaCountdown.text(until: now.addingTimeInterval(-1), now: now) == nil)
        #expect(QuotaCountdown.text(until: nil, now: now) == nil)
    }

    // MARK: - Level → tint mapping (gold ≤ 25%, red ≤ 10%)

    @Test("tint bands mirror the QuotaLevel thresholds, boundaries inclusive")
    func tintBands() {
        #expect(QuotaBarTint.tint(forFraction: 0.0) == .critical)
        #expect(QuotaBarTint.tint(forFraction: 0.10) == .critical)  // boundary is red
        #expect(QuotaBarTint.tint(forFraction: 0.100001) == .warning)
        #expect(QuotaBarTint.tint(forFraction: 0.25) == .warning)  // boundary is gold
        #expect(QuotaBarTint.tint(forFraction: 0.250001) == .normal)
        #expect(QuotaBarTint.tint(forFraction: 0.63) == .normal)
        #expect(QuotaBarTint.tint(forFraction: 1.0) == .normal)
    }

    // MARK: - QuotaStatusModel (demo seeding + seam reads)

    @Test("model reads the seams and honors the demo override")
    @MainActor
    func quotaModelDemoSeed() {
        let model = QuotaStatusModel(
            snapshot: { QuotaSnapshot(fractionRemaining: 0.30, fetchedAt: Date()) },
            stale: { false })
        model.recompute()
        #expect(model.state == .available(fraction: 0.30, stale: false))

        model.seedDemo(fraction: 0.63)
        #expect(model.state == .available(fraction: 0.63, stale: false))
        #expect(model.isDemoSeeded)

        // While demo-seeded, recompute keeps the override.
        model.recompute()
        #expect(model.state == .available(fraction: 0.63, stale: false))

        model.clearDemo()
        #expect(!model.isDemoSeeded)
        #expect(model.state == .available(fraction: 0.30, stale: false))
    }

    @Test("model surfaces staleness from the seam")
    @MainActor
    func quotaModelStale() {
        let model = QuotaStatusModel(
            snapshot: { QuotaSnapshot(fractionRemaining: 0.55, fetchedAt: Date()) },
            stale: { true })
        model.recompute()
        #expect(model.state == .available(fraction: 0.55, stale: true))
    }

    @Test("model publishes the snapshot's windows for the row list")
    @MainActor
    func quotaModelPublishesWindows() {
        let windows = [
            QuotaWindow(kind: .weeklyTokens, fractionRemaining: 0.42, resetsAt: nil),
            QuotaWindow(kind: .monthlyMCP, fractionRemaining: 0.99, resetsAt: nil),
        ]
        let model = QuotaStatusModel(
            snapshot: { QuotaSnapshot(fractionRemaining: 0.42, fetchedAt: Date(), windows: windows) },
            stale: { false })
        model.recompute()
        #expect(model.windows == windows)
    }

    // MARK: - Request log cap + row formatting

    @Test("traffic log caps at 500 entries, oldest evicted")
    @MainActor
    func trafficLogCap() {
        let log = TrafficLog()
        for index in 0..<600 {
            log.append(TrafficEntry(
                model: "m\(index)", routeType: .passthrough, requestKind: .generation,
                httpStatus: 200, timestamp: Date(timeIntervalSince1970: Double(index))))
        }
        #expect(TrafficLog.maxEntries == 500)
        #expect(log.entries.count == 500)
        // Oldest 100 evicted; the newest entry is last.
        #expect(log.entries.first?.model == "m100")
        #expect(log.entries.last?.model == "m599")
    }

    @Test("log row columns: class → target, ms, tokens")
    func logRowFormatting() {
        let entry = TrafficEntry(
            model: "glm-5.3-flash", routeType: .mapped(targetModel: "Qwen3.8-27B-4bit"),
            requestKind: .generation, httpStatus: 200, duration: 2.4, outputTokens: 1870)
            .with(requestClass: .subagent)
        #expect(entry.classTargetDisplayLabel == "subagent → Qwen3.8-27B-4bit")
        #expect(entry.msDisplayText == "2400ms")
        #expect(entry.tokensDisplayText == "1.9K")

        // Class falls back to model classification without a gateway hint.
        let unhinted = TrafficEntry(
            model: "claude-opus-4-6", routeType: .mapped(targetModel: "GLM-5.3"),
            requestKind: .generation, httpStatus: 200, duration: 0.04, outputTokens: nil)
        #expect(unhinted.classTargetDisplayLabel == "opus → GLM-5.3")
        #expect(unhinted.msDisplayText == "40ms")
        #expect(unhinted.tokensDisplayText == "—")

        // Blocked: no duration → em dash, blocked target label.
        let blocked = TrafficEntry(
            model: "claude-haiku-4-5", routeType: .blocked, requestKind: .blocked,
            httpStatus: 403)
        #expect(blocked.classTargetDisplayLabel == "haiku → blocked")
        #expect(blocked.msDisplayText == "—")

        // Time column shape HH:mm:ss.
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        #expect(formatter.date(from: entry.timeDisplayText) != nil)
    }

    // MARK: - Rules summary

    @Test("summary lists enabled rules in order, counts disabled, labels catch-all")
    func rulesSummary() {
        let relay = Vendor(name: "zcode relay", baseURL: "https://zcode.z.ai", apiKey: "")
        let splash = Vendor(name: "splash (local)", baseURL: "http://127.0.0.1:8000", apiKey: "")
        let summary = RulesSummary.text(
            mappings: [
                ModelMapping(
                    sourceModel: "auto", targetModel: "GLM-5.3", targetVendorID: relay.id,
                    matchClass: .auto),
                ModelMapping(
                    sourceModel: "opus (peak hours)", targetModel: "GLM-5.3-Flash",
                    targetVendorID: relay.id, isEnabled: false, matchClass: .opus),
                ModelMapping(
                    sourceModel: "haiku", targetModel: "Qwen3.8-27B-4bit",
                    targetVendorID: splash.id, backupTargetModel: "GLM-5.3-Flash",
                    backupTargetVendorID: relay.id, matchClass: .haiku),
                ModelMapping(
                    sourceModel: "fallback", targetModel: "GLM-5.3-Flash",
                    targetVendorID: relay.id, catchAll: true),
            ],
            vendors: [relay, splash])
        #expect(summary != nil)
        let text = summary!
        #expect(text.contains("auto → GLM-5.3 @ zcode relay"))
        #expect(text.contains("haiku → Qwen3.8-27B-4bit @ splash (local) ⇄ GLM-5.3-Flash @ zcode relay"))
        #expect(text.contains("other → GLM-5.3-Flash @ zcode relay"))
        #expect(!text.contains("opus (peak hours)"))
        #expect(text.contains("+1 off"))
    }

    @Test("summary is nil with no enabled rules")
    func rulesSummaryEmpty() {
        let relay = Vendor(name: "zcode relay", baseURL: "https://zcode.z.ai", apiKey: "")
        let summary = RulesSummary.text(
            mappings: [
                ModelMapping(
                    sourceModel: "opus", targetModel: "GLM-5.3", targetVendorID: relay.id,
                    isEnabled: false, matchClass: .opus)
            ],
            vendors: [relay])
        #expect(summary == nil)
    }

    // MARK: - Splash health chip

    @Test("splash health: up inside the window, down when aged, unknown never probed, nil without splash")
    func splashHealth() {
        let splash = Vendor(name: "splash (local)", baseURL: "http://127.0.0.1:8000", apiKey: "")
        let relay = Vendor(name: "zcode relay", baseURL: "https://zcode.z.ai", apiKey: "")
        let now = Date(timeIntervalSince1970: 1_000_000)
        let successes: [UUID: Date] = [
            splash.id: now.addingTimeInterval(-30)  // inside the 60 s window
        ]
        let read: (UUID) -> Date? = { successes[$0] }

        #expect(SplashHealth.evaluate(vendors: [splash], lastSuccess: read, now: now) == .up)
        #expect(
            SplashHealth.evaluate(vendors: [splash], lastSuccess: read, now: now.addingTimeInterval(61))
                == .down(lastSeen: successes[splash.id]!))
        #expect(
            SplashHealth.evaluate(vendors: [splash], lastSuccess: { _ in nil }, now: now) == .unknown)
        #expect(SplashHealth.evaluate(vendors: [relay], lastSuccess: read, now: now) == nil)
    }

    // MARK: - Env line

    @Test("env line is the exact spec form with the given port")
    func envLineFormation() {
        #expect(
            EnvExportLine.baseURLLine(port: 8080)
                == "export ANTHROPIC_BASE_URL=http://127.0.0.1:8080")
        #expect(
            EnvExportLine.baseURLLine(port: 8093)
                == "export ANTHROPIC_BASE_URL=http://127.0.0.1:8093")
    }

    @Test("env line reflects the ACTUAL bound port, falling back to configured")
    func envLineBoundPort() {
        let claude = ClientConfig(clientName: "Claude Code", port: 8080, defaultUpstream: "https://api.anthropic.com")
        let codex = ClientConfig(clientName: "Codex", port: 8081, defaultUpstream: "https://api.openai.com")
        // Bound (auto-advanced) port wins over the configured one.
        #expect(
            EnvExportLine.claudePort(boundPorts: ["Claude Code": 8093], clients: [claude, codex])
                == 8093)
        #expect(
            EnvExportLine.claudeLine(boundPorts: ["Claude Code": 8093], clients: [claude, codex])
                == "export ANTHROPIC_BASE_URL=http://127.0.0.1:8093")
        // Not running → configured port.
        #expect(
            EnvExportLine.claudeLine(boundPorts: [:], clients: [claude, codex])
                == "export ANTHROPIC_BASE_URL=http://127.0.0.1:8080")
        #expect(EnvExportLine.claudeLine(boundPorts: [:], clients: []) == nil)
    }

    // MARK: - Credential re-login alert

    @Test("re-login command is the exact Task 5 surface line")
    func reloginCommandExact() {
        #expect(
            ReloginAlertContent.command
                == "ZCODE_DATA_BASE_DIR=$HOME/.zcode-scratch-v3 ZCODE_CREDENTIAL_SECRET_FILE=$HOME/.zcode-scratch-v3/secret.txt node /Applications/ZCode.app/Contents/Resources/glm/zcode.cjs login zai")
    }

    @Test("alert message carries reason, command, and the browser note — no secret material")
    func reloginMessage() {
        let message = ReloginAlertContent.message(for: "token expired")
        #expect(message.contains("token expired"))
        #expect(message.contains(ReloginAlertContent.command))
        #expect(message.lowercased().contains("browser"))
        #expect(ReloginAlertContent.title == "ZCode login required")
    }

    @Test("credential alert content: the expired event maps to the alert, others do not")
    @MainActor
    func credentialEventDrivesAlert() {
        let channel = CredentialEventChannel()
        channel.emit(.expired(reason: "token expired"))
        guard case let .expired(reason)? = channel.events.last else {
            Issue.record("expected an expired event")
            return
        }
        #expect(reason == "token expired")
        #expect(ReloginAlertContent.message(for: reason).contains(reason))
    }

    // MARK: - Rule editor state

    /// Stored (not computed): a computed property would mint fresh vendor
    /// UUIDs per access, and validation would never match a set vendor id.
    private let vendors: [Vendor] = [
        Vendor(name: "zcode relay", baseURL: "https://zcode.z.ai", apiKey: ""),
        Vendor(name: "splash (local)", baseURL: "http://127.0.0.1:8000", apiKey: ""),
    ]

    @Test("valid editor state produces a well-formed mapping")
    func ruleEditRoundTrip() {
        let relay = vendors[0]
        let mapping = ModelMapping(
            sourceModel: "haiku", targetModel: "Qwen3.8-27B-4bit", targetVendorID: relay.id,
            backupTargetModel: "GLM-5.3-Flash", backupTargetVendorID: relay.id,
            matchClass: .haiku,
            conditions: [RuleCondition(type: .timeWindow, days: .weekdays, from: "07:00", to: "11:00", tz: "Europe/Paris")])

        let state = RuleEditState(mapping: mapping)
        #expect(state.validationError(vendors: vendors) == nil)
        let rebuilt = state.toMapping(existing: mapping)
        #expect(rebuilt.id == mapping.id)
        #expect(rebuilt.sourceModel == "haiku")
        #expect(rebuilt.targetModel == "Qwen3.8-27B-4bit")
        #expect(rebuilt.targetVendorID == relay.id)
        #expect(rebuilt.backupTargetModel == "GLM-5.3-Flash")
        #expect(rebuilt.backupTargetVendorID == relay.id)
        #expect(rebuilt.matchClass == .haiku)
        #expect(rebuilt.catchAll == false)
        #expect(rebuilt.conditions == mapping.conditions)
    }

    @Test("invalid rules are blocked with a message: no target, no model")
    func ruleValidationBlocking() {
        // No vendor at all.
        var state = RuleEditState()
        #expect(state.validationError(vendors: vendors) != nil)

        // Vendor that is not in the list anymore (deleted).
        state = RuleEditState()
        state.primaryVendorID = UUID()
        state.primaryModel = "GLM-5.3"
        #expect(state.validationError(vendors: vendors) != nil)

        // Vendor but no model.
        state = RuleEditState()
        state.primaryVendorID = vendors[0].id
        #expect(state.validationError(vendors: vendors) != nil)

        // Exact-model match without a model ID.
        state = RuleEditState()
        state.matchMode = .exactModel
        state.primaryVendorID = vendors[0].id
        state.primaryModel = "GLM-5.3"
        #expect(state.validationError(vendors: vendors) != nil)

        // Half-configured backup.
        state = RuleEditState()
        state.primaryVendorID = vendors[0].id
        state.primaryModel = "GLM-5.3"
        state.backupModel = "GLM-5.3-Flash"
        #expect(state.validationError(vendors: vendors) != nil)
    }

    @Test("condition validation: bad time window and bad percent are blocked")
    func ruleValidationConditions() {
        var state = RuleEditState()
        state.primaryVendorID = vendors[0].id
        state.primaryModel = "GLM-5.3"

        state.conditions = [RuleCondition(type: .timeWindow, days: .daily, from: "7am", to: "11:00")]
        #expect(state.validationError(vendors: vendors) != nil)

        state.conditions = [RuleCondition(type: .timeWindow, days: .daily, from: nil, to: nil)]
        #expect(state.validationError(vendors: vendors) != nil)

        state.conditions = [RuleCondition(type: .quotaBelow, percent: 140)]
        #expect(state.validationError(vendors: vendors) != nil)

        state.conditions = [RuleCondition(type: .quotaBelow, percent: nil)]
        #expect(state.validationError(vendors: vendors) != nil)

        state.conditions = [
            RuleCondition(type: .timeWindow, days: .weekdays, from: "07:00", to: "11:00"),
            RuleCondition(type: .quotaBelow, percent: 50),
        ]
        #expect(state.validationError(vendors: vendors) == nil)
    }

    @Test("catch-all and class modes map onto the Task 6 schema fields")
    func ruleMatchModes() {
        var state = RuleEditState()
        state.matchMode = .catchAll
        state.primaryVendorID = vendors[0].id
        state.primaryModel = "GLM-5.3-Flash"
        #expect(state.validationError(vendors: vendors) == nil)
        let catchAll = state.toMapping()
        #expect(catchAll.catchAll == true)
        #expect(catchAll.matchClass == nil)
        #expect(catchAll.sourceModel == "fallback")

        state.matchMode = .modelClass(.opus)
        let classRule = state.toMapping()
        #expect(classRule.catchAll == false)
        #expect(classRule.matchClass == .opus)
        #expect(classRule.sourceModel == "opus")

        state.matchMode = .exactModel
        state.exactModel = "glm-5.3"
        let exact = state.toMapping()
        #expect(exact.matchClass == nil)
        #expect(exact.sourceModel == "glm-5.3")
    }

    @Test("condition badge text")
    func conditionBadges() {
        let window = RuleCondition(type: .timeWindow, days: .weekdays, from: "07:00", to: "11:00", tz: "Europe/Paris")
        #expect(window.badgeText == "07:00–11:00 weekdays Europe/Paris")
        let quota = RuleCondition(type: .quotaBelow, percent: 50)
        #expect(quota.badgeText == "quota < 50%")
    }

    // MARK: - Fix round 1

    @Test("credential alert presents only UNSEEN events (no re-present after re-login)")
    @MainActor
    func credentialAlertPresentsOnlyUnseenEvents() {
        let first = CredentialEvent.expired(reason: "token expired")
        let second = CredentialEvent.expired(reason: "session rejected")

        // Pure decision: nil when the high-water mark caught up, the last
        // event when there is anything new.
        #expect(CredentialAlertPresenter.pendingAlert(events: [], seenCount: 0) == nil)
        #expect(CredentialAlertPresenter.pendingAlert(events: [first], seenCount: 0) == first)
        #expect(CredentialAlertPresenter.pendingAlert(events: [first], seenCount: 1) == nil)
        #expect(CredentialAlertPresenter.pendingAlert(events: [first, second], seenCount: 1) == second)

        // Lifecycle: present once, then the same channel is silent on every
        // subsequent popover open (the round-1 bug: one expiry used to
        // re-present forever, even after a successful re-login).
        let presenter = CredentialAlertPresenter()
        #expect(presenter.consume(events: [first]) == first)
        #expect(presenter.seenCount == 1)
        #expect(presenter.consume(events: [first]) == nil)  // reopen: silent
        #expect(presenter.consume(events: [first]) == nil)  // reopen again: silent

        // An event that fired while the popover was closed is unseen and
        // alerts on the next open — exactly once.
        #expect(presenter.consume(events: [first, second]) == second)
        #expect(presenter.seenCount == 2)
        #expect(presenter.consume(events: [first, second]) == nil)
    }

    @Test("canRefresh tracks real quota-service availability (button never a silent no-op)")
    @MainActor
    func quotaModelCanRefreshGatesOnServiceAvailability() {
        // Explicit false gate.
        let gated = QuotaStatusModel(snapshot: { nil }, serviceAvailable: { false })
        #expect(gated.canRefresh == false)

        // Default (tests, direct construction) stays refreshable.
        #expect(QuotaStatusModel(snapshot: { nil }).canRefresh == true)

        // The live binding: false before any quota service exists, true
        // once the provider is a QuotaService (what ProxyServer assigns on
        // the first relay-configured start).
        let server = ProxyServer(tokenStatsStore: TokenStatsStore())
        let live = QuotaStatusModel.live(server)
        #expect(live.canRefresh == false)
        server.quotaProvider = QuotaService(apiKeyProvider: { "" })
        #expect(live.canRefresh == true)
    }
}

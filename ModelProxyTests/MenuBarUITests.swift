import AppKit
import Foundation
import SwiftUI
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
        // No data → nil weekly fraction → the dashed no-data ring.
        #expect(state.weeklyFraction == nil)
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
    }

    // MARK: - Menu-bar ring (weekly fraction + sweep geometry)

    @Test("weekly fraction prefers the weekly window row, clamped; nil only for no-data")
    func weeklyFractionForMenuBarRing() {
        // No data → nil (the dashed ring).
        #expect(QuotaDisplayState.make(snapshot: nil, stale: false).weeklyFraction == nil)

        // Weekly window row wins over the legacy top-level fraction.
        let snapshot = QuotaSnapshot(fractionRemaining: 0.42, fetchedAt: Date(), windows: [
            QuotaWindow(kind: .weeklyTokens, fractionRemaining: 0.30, resetsAt: nil),
            QuotaWindow(kind: .fiveHourTokens, fractionRemaining: 0.9, resetsAt: nil),
        ])
        #expect(QuotaDisplayState.make(snapshot: snapshot, stale: false).weeklyFraction == 0.30)

        // No rows → legacy fraction.
        let legacy = QuotaDisplayState.make(
            snapshot: QuotaSnapshot(fractionRemaining: 0.63, fetchedAt: Date()), stale: false)
        #expect(legacy.weeklyFraction == 0.63)

        // Out-of-range window values clamp into 0...1.
        let over = QuotaSnapshot(fractionRemaining: 0.5, fetchedAt: Date(), windows: [
            QuotaWindow(kind: .weeklyTokens, fractionRemaining: 1.7, resetsAt: nil),
        ])
        #expect(QuotaDisplayState.make(snapshot: over, stale: false).weeklyFraction == 1)
    }

    @Test("ring sweep clamps, inks a minimum dot at 0, draws a full circle at 1")
    func ringSweepClamping() {
        #expect(QuotaRingSpec.sweepDegrees(forFraction: 0) == QuotaRingSpec.minimumSweepDegrees)
        #expect(QuotaRingSpec.sweepDegrees(forFraction: -0.2) == QuotaRingSpec.minimumSweepDegrees)
        #expect(QuotaRingSpec.sweepDegrees(forFraction: 1) == 360)
        #expect(QuotaRingSpec.sweepDegrees(forFraction: 1.7) == 360)
        // ≥ 0.999 counts as full so the round caps never overlap a hairline gap.
        #expect(QuotaRingSpec.sweepDegrees(forFraction: 0.999) == 360)
        #expect(QuotaRingSpec.sweepDegrees(forFraction: 0.99) < 360)
        #expect(abs(QuotaRingSpec.sweepDegrees(forFraction: 0.5) - 180) < 0.001)
        #expect(abs(QuotaRingSpec.sweepDegrees(forFraction: 0.63) - 226.8) < 0.01)
    }

    @Test("ZΓ mark auto-fit clamps oversized measurements, keeps fitting ones at base size")
    func markAutoFit() {
        let clearSpan = QuotaRingSpec.diameter - QuotaRingSpec.lineWidth
        // Oversized width at base size → scaled down into the fit box.
        let wide = QuotaRingSpec.fittedMarkFontSize(measuredWidth: clearSpan, measuredCapHeight: 0.01)
        #expect(wide < QuotaRingSpec.markBaseFontSize)
        // Cap height clamps independently of width.
        let tall = QuotaRingSpec.fittedMarkFontSize(measuredWidth: 0.01, measuredCapHeight: clearSpan)
        #expect(tall < QuotaRingSpec.markBaseFontSize)
        // Fits within the box → stays at the base size (never scaled up).
        let fitting = QuotaRingSpec.fittedMarkFontSize(measuredWidth: 1, measuredCapHeight: 1)
        #expect(fitting == QuotaRingSpec.markBaseFontSize)
    }

    @Test("menu-bar icon renders as a template image at canvas size in every state")
    func iconRenderSmoke() {
        for image in [
            QuotaMenuBarIcon.image(weeklyFraction: 0.63, stale: false),
            QuotaMenuBarIcon.image(weeklyFraction: 0.63, stale: true),
            QuotaMenuBarIcon.image(weeklyFraction: nil, stale: false),
        ] {
            #expect(image.isTemplate)
            #expect(image.size == NSSize(width: QuotaRingSpec.canvas, height: QuotaRingSpec.canvas))
        }
    }

    @Test("ring geometry constants are pinned (the composed-mark sizing)")
    func ringGeometryPinned() {
        #expect(QuotaRingSpec.canvas == 18)
        #expect(QuotaRingSpec.diameter == 15)
        #expect(QuotaRingSpec.lineWidth == 1.75)
        // The clear interior must fit the auto-fit box the mark targets.
        #expect(QuotaRingSpec.diameter - QuotaRingSpec.lineWidth == 13.25)
    }

    @Test("rasterized icon carries mark ink in the interior and clear margins outside the stroke")
    func iconInkRasterizes() throws {
        for image in [
            QuotaMenuBarIcon.image(weeklyFraction: 0.63, stale: false),
            QuotaMenuBarIcon.image(weeklyFraction: nil, stale: false),
        ] {
            let rep = try #require(image.representations.first as? NSBitmapImageRep)
            let p = rep.pixelsWide
            let scale = Double(p) / Double(QuotaRingSpec.canvas)
            let center = p / 2
            // Nothing inks outside the stroke's outer extent (+ AA slack).
            let outer = Int(scale * (QuotaRingSpec.diameter + QuotaRingSpec.lineWidth) / 2) + 2
            var stray = 0
            for y in 0..<p {
                for x in 0..<p {
                    let dx = x - center, dy = y - center
                    if dx * dx + dy * dy > outer * outer,
                        rep.colorAt(x: x, y: y)!.alphaComponent > 0.05
                    {
                        stray += 1
                    }
                }
            }
            #expect(stray == 0)
            // The ZΓ mark inks strictly inside the interior (the only
            // full-interior content in both states).
            let inner = Int(scale * (QuotaRingSpec.diameter - QuotaRingSpec.lineWidth) / 2 * 0.55)
            var markPixels = 0
            for y in 0..<p {
                for x in 0..<p {
                    let dx = x - center, dy = y - center
                    if dx * dx + dy * dy < inner * inner,
                        rep.colorAt(x: x, y: y)!.alphaComponent > 0.05
                    {
                        markPixels += 1
                    }
                }
            }
            #expect(markPixels > 10)
        }
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

    @Test("log row columns: class → target, ttft, tok/s")
    func logRowFormatting() {
        let entry = TrafficEntry(
            model: "glm-5.3-flash", routeType: .mapped(targetModel: "Qwen3.8-27B-4bit"),
            requestKind: .generation, httpStatus: 200, duration: 2.4, ttft: 0.4, outputTokens: 1870)
            .with(requestClass: .subagent)
        #expect(entry.classTargetDisplayLabel == "subagent → Qwen3.8-27B-4bit")
        #expect(entry.ttftDisplayText == "0.4s")
        // Decode window: (2.4 - 0.4) s → 1870 / 2.0 ≈ 935 tok/s; the unit
        // lives in the column header, so the cell shows the bare number.
        #expect(entry.tokensPerSecondDisplayText == "935")
        #expect(entry.tokensDisplayText == "1.9K")

        // Non-streamed: first body byte ~ whole duration → tok/s suppressed
        // (a "speed" over a zero-width window would be fiction).
        let buffered = TrafficEntry(
            model: "glm-5.3", routeType: .mapped(targetModel: "GLM-5.3"),
            requestKind: .generation, httpStatus: 200, duration: 6.0, ttft: 5.9, outputTokens: 500)
        #expect(buffered.tokensPerSecondDisplayText == "—")

        // Rounded-to-seconds TTFT above 1 s; tok/s over the stream window.
        let slow = TrafficEntry(
            model: "glm-5.3", routeType: .mapped(targetModel: "GLM-5.3"),
            requestKind: .generation, httpStatus: 200, duration: 12.6, ttft: 3.4, outputTokens: 1000)
        #expect(slow.ttftDisplayText == "3s")
        #expect(slow.tokensPerSecondDisplayText == "109")  // 1000 / (12.6 - 3.4) = 108.7 → 109

        // Class falls back to model classification without a gateway hint.
        let unhinted = TrafficEntry(
            model: "claude-opus-4-6", routeType: .mapped(targetModel: "GLM-5.3"),
            requestKind: .generation, httpStatus: 200, duration: 0.04, outputTokens: nil)
        #expect(unhinted.classTargetDisplayLabel == "opus → GLM-5.3")
        #expect(unhinted.ttftDisplayText == "—")
        #expect(unhinted.tokensPerSecondDisplayText == "—")

        // Blocked: no duration → em dash, blocked target label.
        let blocked = TrafficEntry(
            model: "claude-haiku-4-5", routeType: .blocked, requestKind: .blocked,
            httpStatus: 403)
        #expect(blocked.classTargetDisplayLabel == "haiku → blocked")
        #expect(blocked.ttftDisplayText == "—")

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

    // MARK: - Splash lifecycle chip (Package C)

    @Test("lifecycle chip faces: symbol + text, distinct shapes per state")
    func lifecycleChipFaces() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(SplashLifecycleChip.face(
            for: .running(profile: "p", since: t0, adopted: false), now: t0)
            == .init(symbolName: "circle.fill", text: "splash · p", color: .green))
        #expect(SplashLifecycleChip.face(
            for: .running(profile: "p", since: t0, adopted: true), now: t0)
            == .init(symbolName: "circle.fill", text: "splash · p · external", color: .green))
        #expect(SplashLifecycleChip.face(
            for: .starting(profile: "p"), now: t0)
            == .init(symbolName: "circle.lefthalf.filled", text: "splash · starting", color: .secondary))
        #expect(SplashLifecycleChip.face(
            for: .stopping, now: t0)
            == .init(symbolName: "circle.lefthalf.filled", text: "splash · stopping", color: .secondary))
        #expect(SplashLifecycleChip.face(
            for: .crashed(profile: "p", lastExit: 1, nextRetry: t0.addingTimeInterval(12)), now: t0)
            == .init(symbolName: "exclamationmark.circle.fill", text: "splash · retry in 12 s", color: .orange))
        // nil nextRetry = NO retry scheduled (spawn failure / readiness
        // timeout) — truthful text, never "retry pending".
        #expect(SplashLifecycleChip.face(
            for: .crashed(profile: "p", lastExit: 1, nextRetry: nil), now: t0)
            == .init(symbolName: "exclamationmark.circle.fill", text: "splash · crashed", color: .orange))
        // Pre-flip render must clamp, not count up backwards.
        #expect(SplashLifecycleChip.face(
            for: .crashed(profile: "p", lastExit: 1, nextRetry: t0.addingTimeInterval(-5)), now: t0)
            == .init(symbolName: "exclamationmark.circle.fill", text: "splash · retry in 0 s", color: .orange))
        #expect(SplashLifecycleChip.face(
            for: .stopped, now: t0)
            == .init(symbolName: "circle.dashed", text: "splash · off", color: .secondary))
    }

    // MARK: - Off-peak window chip (off-peak wave 2 Task 6)

    @Test("off-peak chip: green only for an open window, text carries the state")
    func offPeakChipFaces() {
        #expect(
            OffPeakStatusChip.face(for: .open)
                == .init(text: "Off-Peak: Window open", color: .green))
        // Closed/unavailable dim to secondary; the localized date text is
        // NOT pinned (locale-dependent) — prefix + color only.
        let closed = OffPeakStatusChip.face(
            for: .closedUntil(Date(timeIntervalSince1970: 1_763_000_000)))
        #expect(closed.text.hasPrefix("Off-Peak: Closed until "))
        #expect(closed.color == .secondary)
        #expect(
            OffPeakStatusChip.face(for: .unavailable("probe failed"))
                == .init(text: "Off-Peak: Unavailable (probe failed)", color: .secondary))
        // Enabled-but-not-yet-polled: "Checking…", never "Off" (the row is
        // only rendered while the surface is enabled — "Off" would read as
        // the toggle state).
        #expect(
            OffPeakStatusChip.face(for: .idle)
                == .init(text: "Off-Peak: Checking…", color: .secondary))
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

    @Test("quick start command shares the env line's host and bound-port semantics")
    func quickStartCommandFormation() {
        let claude = ClientConfig(clientName: "Claude Code", port: 8080, defaultUpstream: "https://api.anthropic.com")
        // Bound (auto-advanced) port wins over the configured one.
        #expect(
            EnvExportLine.quickStartCommand(client: claude, boundPort: 8093)
                == "export ANTHROPIC_BASE_URL=http://127.0.0.1:8093 CLAUDE_CODE_GATEWAY_HINT_HEADERS=1 && claude")
        // Not running → configured port.
        #expect(
            EnvExportLine.quickStartCommand(client: claude, boundPort: nil)
                == "export ANTHROPIC_BASE_URL=http://127.0.0.1:8080 CLAUDE_CODE_GATEWAY_HINT_HEADERS=1 && claude")
        // Non-claude tools: no hint headers, tool name from the client.
        let codex = ClientConfig(clientName: "Codex", port: 8081, defaultUpstream: "https://api.openai.com")
        #expect(
            EnvExportLine.quickStartCommand(client: codex, boundPort: nil)
                == "export ANTHROPIC_BASE_URL=http://127.0.0.1:8081 && codex")
    }

    // MARK: - Credential re-login alert

    @Test("re-login command is the shared-default remedy — no dev-machine env vars")
    func reloginCommandExact() {
        #expect(ReloginAlertContent.command == CredentialStore.loginRemedy)
        #expect(
            ReloginAlertContent.command
                == "node /Applications/ZCode.app/Contents/Resources/glm/zcode.cjs login zai")
    }

    @Test("alert message carries reason and the browser path — short, nothing to transcribe")
    func reloginMessage() {
        let message = ReloginAlertContent.message(for: "token expired")
        #expect(message.contains("token expired"))
        // HIG alerts.md: keep the message short. The command is one click
        // away via Copy Command (and in Settings → Advanced); alert text is
        // not selectable, so it must never carry material to transcribe.
        #expect(!message.contains(ReloginAlertContent.command))
        #expect(message.contains("Sign In"))
        #expect(message.lowercased().contains("browser"))
        #expect(ReloginAlertContent.title == "ZCode Login Required")
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

    @Test("off-peak primary requires a non-off-peak backup (closed-window fallback)")
    func ruleValidationOffPeakPrimary() {
        // Local list (same stored-UUID rationale as `vendors`): the seeded
        // off-peak vendor plus a normal relay vendor as the usable backup.
        let offPeak = Vendor(
            name: "ZCode Off-Peak", baseURL: "https://zcode.z.ai", apiKey: "",
            vendorKind: .offPeak)
        let relay = Vendor(name: "zcode relay", baseURL: "https://zcode.z.ai", apiKey: "")
        let vendors = [offPeak, relay]
        let blockMessage = "An off-peak primary target needs a backup target for the closed-window fallback."

        // No backup at all → blocked with the exact message.
        var state = RuleEditState()
        state.primaryVendorID = offPeak.id
        state.primaryModel = "GLM-5.3"
        #expect(state.validationError(vendors: vendors) == blockMessage)

        // An off-peak backup is no usable backup either (the forwarder's
        // Task-4 guard treats it as none — same single message).
        state.backupVendorID = offPeak.id
        state.backupModel = "GLM-5.3"
        #expect(state.validationError(vendors: vendors) == blockMessage)

        // A non-off-peak backup satisfies the guard.
        state.backupVendorID = relay.id
        #expect(state.validationError(vendors: vendors) == nil)

        // A non-off-peak primary keeps needing no backup at all.
        var plain = RuleEditState()
        plain.primaryVendorID = relay.id
        plain.primaryModel = "GLM-5.3"
        #expect(plain.validationError(vendors: vendors) == nil)
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

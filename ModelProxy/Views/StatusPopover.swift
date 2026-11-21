import Combine
import SwiftUI

struct StatusPopover: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer
    @Environment(TrafficLog.self) private var trafficLog
    @Environment(QuotaStatusModel.self) private var quotaModel
    @Environment(SplashManager.self) private var splashManager
    @Environment(CredentialStatusModel.self) private var credentialModel
    @Environment(UpdateCenter.self) private var updateCenter
    @Environment(AppUpdateService.self) private var appUpdate
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showCorruptBanner: Bool = false
    @State private var showingReloginAlert: Bool = false
    @State private var reloginMessage: String = ""
    @State private var copiedEnvLine: Bool = false
    /// ZGate install flow (spec §3.5 via §5): the shared
    /// confirm-to-stage-swap helper — the About Updates row runs the
    /// same object type, so the two surfaces cannot drift.
    @State private var zGateInstall = ZGateInstallFlow()
    /// View-local mirror of the in-flight splash apply — enough to
    /// disable its button (UpdateCenter's applying flag is deliberately
    /// non-observable).
    @State private var splashApplying: Bool = false
    /// Slow tick so the splash chip and quota caption age without traffic.
    @State private var tick: Date = .now

    private let slowTick = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            updateBannerSection
                .padding(.horizontal, 12)
                .padding(.top, 12)

            bannerSection
                .padding(.horizontal, 12)
                .padding(.top, updateCenter.hasActiveAlert ? 4 : 12)

            clientHeader
                .padding(.horizontal, 12)
                .padding(.top, bannerIsVisible || updateCenter.hasActiveAlert ? 8 : 12)
                .padding(.bottom, 8)

            Divider()

            quotaSection
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            credentialSection
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            offPeakSection
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            rulesAndHealthSection
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            envLineSection
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            Divider()

            trafficSection
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)

            Divider()
                .padding(.top, 4)

            controlRow
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .frame(width: 440)
        .onAppear {
            if configStore.didResetFromCorrupt {
                showCorruptBanner = true
                configStore.clearCorruptFlag()
            }
            presentLatestCredentialEvent()
            quotaModel.recompute()
            Task { await credentialModel.recompute() }
        }
        .onReceive(slowTick) { _ in
            tick = .now
            Task { await credentialModel.recompute() }
        }
        .onChange(of: proxyServer.credentialEvents.events.count) { _, _ in
            presentLatestCredentialEvent()
            Task { await credentialModel.recompute() }
        }
        .onChange(of: proxyServer.quotaEvents.events.count) { _, _ in
            quotaModel.recompute()
        }
        .alert(ReloginAlertContent.title, isPresented: $showingReloginAlert) {
            Button(ReloginAlertContent.signInActionTitle) {
                credentialModel.startSignIn()
            }
            Button(ReloginAlertContent.copyCommandActionTitle) {
                copyToClipboard(ReloginAlertContent.command(
                    for: CredentialStore.resolveBase(configStore.config.credentialStoreBase)))
            }
            Button("Not Now", role: .cancel) { }
        } message: {
            Text(reloginMessage)
        }
        .confirmationDialog(
            "Install ZGate \(zGateInstall.confirmTag ?? "")?",
            isPresented: Binding(
                get: { zGateInstall.confirmTag != nil },
                set: { if !$0 { zGateInstall.cancel() } }),
            titleVisibility: .visible
        ) {
            Button("Install and Restart") {
                zGateInstall.confirmInstall(appUpdate: appUpdate)
            }
            Button("Cancel", role: .cancel) { zGateInstall.cancel() }
        } message: {
            // The swap script quits this app by design — the proxy is down
            // for the seconds the restart takes (spec §3.5).
            Text("ZGate will quit and restart — the proxy is down for a few seconds. Continue?")
        }
        .task {
            // Primary start happens at app launch (ModelProxyApp init). This
            // is the idempotent re-entry: a no-op while running (start()
            // guards on isRunning), never a resume after Pause (isStopped),
            // and a retry only if the launch start bound nothing at all.
            guard !proxyServer.isRunning, !proxyServer.isStopped else { return }
            await proxyServer.start(config: configStore.config)
        }
    }

    private var bannerIsVisible: Bool {
        proxyServer.lastError != nil || showCorruptBanner
    }

    // MARK: - Update banners (spec §5)

    /// Per-target update banners, one action each: ZGate Install… (a
    /// /Applications install; anywhere else View… → the Releases page,
    /// since the swap script only ever replaces the prod install) and
    /// splash Update → the managed apply. Each dismiss (×) persists the
    /// dismissed tag — a NEWER tag re-alerts (UpdateCenter's per-tag
    /// dismissal). Failures surface inline in the banner line.
    @ViewBuilder
    private var updateBannerSection: some View {
        if updateCenter.zgateAlert, case .available(let tag, _) = updateCenter.zgateState {
            let line = zGateInstall.error.map { "ZGate \(tag) available — \($0)" }
                ?? "ZGate \(tag) available"
            actionBanner(
                icon: "arrow.down.circle.fill", tint: .orange,
                text: line,
                primaryTitle: zGateInstall.busy ? "Restarting…" : (ZGateInstallFlow.prodInstall(appUpdate) ? "Install…" : "View…"),
                primaryDisabled: zGateInstall.busy,
                primary: {
                    if ZGateInstallFlow.prodInstall(appUpdate) {
                        zGateInstall.request(tag: tag)
                    } else {
                        ZGateInstallFlow.openReleases()
                    }
                },
                dismissLabel: "Dismiss ZGate update banner",
                dismiss: { updateCenter.dismissZGate(tag: tag) })
        }
        if updateCenter.splashAlert, case .available(let installed, let latest) = updateCenter.splashState {
            actionBanner(
                icon: "arrow.down.circle.fill", tint: .orange,
                text: "splash \(latest) available\(installed.map { " · \($0) installed" } ?? "")",
                primaryTitle: splashApplying ? "Updating…" : "Update",
                primaryDisabled: splashApplying,
                primary: {
                    splashApplying = true
                    Task {
                        await updateCenter.applySplashUpdate()
                        splashApplying = false
                    }
                },
                dismissLabel: "Dismiss splash update banner",
                dismiss: { updateCenter.dismissSplash(tag: latest) })
        }
        // Apply-time failure (spec §3.4): a NON-ALERTING status line —
        // the badge and alert layer stay silent for `.failed`; the
        // Update action retries manually, the × dismisses the tag.
        if let failure = StatusPopover.splashFailureBanner(
            state: updateCenter.splashState,
            lastTag: updateCenter.lastSplashTag,
            dismissedTag: updateCenter.dismissedSplashTag)
        {
            actionBanner(
                icon: "exclamationmark.triangle.fill", tint: .orange,
                text: failure.text,
                primaryTitle: splashApplying ? "Updating…" : "Update",
                primaryDisabled: splashApplying,
                primary: {
                    splashApplying = true
                    Task {
                        await updateCenter.applySplashUpdate()
                        splashApplying = false
                    }
                },
                dismissLabel: "Dismiss splash update failure",
                dismiss: { updateCenter.dismissSplash(tag: failure.updateTag) })
        }
    }

    /// Pure, tested model of the splash-apply failure line (fix pass,
    /// spec §3.4 "the state goes to `failed` with the log tail
    /// surfaced"): informational only — never a badge driver
    /// (`hasActiveAlert` ignores `.failed`) — with the SAME per-tag
    /// dismissal semantics as the available banner. `.failed` carries
    /// only the reason, so the Update target is the last tag the check
    /// half saw; no tag → no line (nothing to retry or dismiss against).
    nonisolated static func splashFailureBanner(
        state: UpdateCenter.SplashUpdateState,
        lastTag: String?,
        dismissedTag: String?
    ) -> (text: String, updateTag: String)? {
        guard case .failed(let reason) = state else { return nil }
        guard let lastTag, lastTag != dismissedTag else { return nil }
        return ("splash update failed — \(reason)", lastTag)
    }

    /// Action banner: the shared `banner` capsule with a trailing primary
    /// link button and an × dismiss. Deliberately NOT wrapped in an
    /// accessibilityElement — the buttons must stay individually
    /// reachable; each carries its own label.
    private func actionBanner(
        icon: String,
        tint: Color,
        text: String,
        primaryTitle: String,
        primaryDisabled: Bool,
        primary: @escaping () -> Void,
        dismissLabel: String,
        dismiss: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Button(primaryTitle, action: primary)
                .buttonStyle(.link)
                .font(.callout)
                .disabled(primaryDisabled)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.link)
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityLabel(dismissLabel)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Banner

    @ViewBuilder
    private var bannerSection: some View {
        if !proxyServer.isRunning, let error = proxyServer.lastError {
            banner(
                icon: "exclamationmark.circle.fill", tint: .red, text: error,
                accessibilityPrefix: "Error")
        } else if proxyServer.isRunning, let error = proxyServer.lastError {
            banner(
                icon: "exclamationmark.triangle.fill", tint: .orange, text: error,
                accessibilityPrefix: "Warning")
        } else if showCorruptBanner {
            // Informational, already-happened event: a session banner, not
            // a launch-time modal (HIG alerts.md — no alerts on start, none
            // for pure information).
            banner(
                icon: "exclamationmark.triangle.fill", tint: .orange,
                text: "config.json was corrupt — settings were reset to defaults. Previous settings were not recoverable.",
                accessibilityPrefix: "Warning")
        }
    }

    /// Tinted banner: color lives on the icon and capsule background; the
    /// message itself stays primary for contrast (HIG color.md — don't
    /// paint sentences in status colors).
    private func banner(icon: String, tint: Color, text: String, accessibilityPrefix: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(accessibilityPrefix): \(text)")
    }

    // MARK: - Client Header

    @ViewBuilder
    private var clientHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(
                proxyServer.boundPorts.sorted(by: { $0.key < $1.key }),
                id: \.key
            ) { name, port in
                Text(verbatim: "\(name):\(port)")
                    .font(.callout)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }
            if proxyServer.boundPorts.isEmpty {
                Text("No active listeners")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(clientHeaderAccessibilityLabel)
    }

    private var clientHeaderAccessibilityLabel: String {
        if proxyServer.boundPorts.isEmpty {
            return "No active listeners"
        }
        return proxyServer.boundPorts
            .sorted { $0.key < $1.key }
            .map { "\($0.key) on port \($0.value)" }
            .joined(separator: ", ")
    }

    // MARK: - Quota

    private var quotaSection: some View {
        HStack(alignment: .top, spacing: 8) {
            QuotaBarView(state: quotaModel.state, fetchedAt: quotaModel.fetchedAt, showsCaption: true)
            if quotaModel.canRefresh {
                Button {
                    Task { await quotaModel.refreshNow() }
                } label: {
                    if quotaModel.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(quotaModel.isRefreshing)
                .accessibilityLabel("Refresh quota now")
                .accessibilityHint("Polls the quota monitor immediately.")
            }
        }
    }

    // MARK: - Credentials

    /// Persistent credential row (login-flow UI item 2): same visual
    /// weight as the splash chip, directly under the quota section.
    /// Controller ruling: renders ONLY when a relay-kind vendor is
    /// configured — the `off` face is Settings-only.
    @ViewBuilder
    private var credentialSection: some View {
        if configStore.config.vendors.contains(where: { $0.vendorKind == .relay }) {
            let chip = credentialModel.face.chip
            HStack(spacing: 8) {
                Text(chip.text)
                    .font(.callout)
                    .foregroundStyle(chip.color)
                if let retry = credentialModel.lastLoginOutcome?.retryText {
                    Text(retry)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if credentialModel.loginInFlight {
                    Button("Cancel") {
                        credentialModel.cancelSignIn()
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                    .accessibilityLabel("Cancel sign-in")
                    .accessibilityHint("Aborts the browser login flow.")
                } else if credentialModel.face.isActionNeeded {
                    Button("Sign In…") {
                        credentialModel.startSignIn()
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                    .accessibilityLabel("Sign in to ZCode")
                    .accessibilityHint("Opens the browser for the ZCode login flow.")
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Off-Peak (off-peak wave 2 Task 6)

    /// One-line window-status chip, same visual weight as the credential
    /// row above. Renders ONLY while the surface is enabled — the off
    /// face lives in Settings (General → Off-Peak), mirroring the
    /// credentialSection ruling. Reads the monitor's cached status; the
    /// @Observable monitor re-renders the row on every poll.
    @ViewBuilder
    private var offPeakSection: some View {
        if configStore.config.offPeak.enabled {
            let face = OffPeakStatusChip.face(for: proxyServer.offPeakMonitor?.status ?? .idle)
            Text(face.text)
                .font(.callout)
                .foregroundStyle(face.color)
        }
    }

    // MARK: - Rules summary + splash lifecycle

    @ViewBuilder
    private var rulesAndHealthSection: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if let summary = RulesSummary.text(
                    mappings: configStore.config.modelMappings,
                    vendors: configStore.config.vendors)
                {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(summary)
                        .textSelection(.enabled)
                } else {
                    Text("No rules enabled — unmatched models pass through")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            splashChip(splashManager.state)
        }
        .accessibilityElement(children: .combine)
    }

    /// Lifecycle chip driven by the manager's process state (spec §5); the
    /// slow tick keeps the crashed-retry countdown live between transitions.
    /// Shape carries the state (filled / half / dashed-outline / alert) so
    /// color is never the only signal.
    private func splashChip(_ state: SplashState) -> some View {
        let face = SplashLifecycleChip.face(for: state, now: tick)
        return HStack(spacing: 4) {
            Image(systemName: face.symbolName)
                .font(.callout)
                .foregroundStyle(face.color)
            Text(face.text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .help("Splash lifecycle managed by ZGate (Settings → Splash)")
    }

    // MARK: - Env line

    @ViewBuilder
    private var envLineSection: some View {
        if let line = EnvExportLine.claudeLine(
            boundPorts: proxyServer.boundPorts,
            clients: configStore.config.clients)
        {
            HStack(spacing: 6) {
                Text(line)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button {
                    copyToClipboard(line)
                    copiedEnvLine = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copiedEnvLine = false
                    }
                } label: {
                    Text(copiedEnvLine ? "Copied" : "Copy")
                        .font(.callout)
                }
                .buttonStyle(.link)
                .accessibilityLabel("Copy environment line")
            }
        }
    }

    // MARK: - Control Row

    @ViewBuilder
    private var controlRow: some View {
        HStack(spacing: 8) {
            statusIndicator
                .frame(width: 120, alignment: .leading)

            Spacer()

            HStack(spacing: 6) {
                debugMenu

                if proxyServer.isRunning {
                    Button {
                        Task { await proxyServer.stop() }
                    } label: {
                        Text("Pause")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Pause proxying")
                    .accessibilityHint("Stops the local proxy listeners; resume restarts them.")
                } else {
                    Button {
                        Task { await proxyServer.start(config: configStore.config) }
                    } label: {
                        Text("Resume")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Resume proxying")
                    .accessibilityHint("Starts the local proxy server on configured ports.")
                }

                SettingsLink {
                    Image(systemName: "gear")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Open Settings")

                Button { NSApplication.shared.terminate(nil) } label: {
                    Text("Quit")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Quit ZGate")
                .accessibilityHint("Stops the proxy and closes the application.")
            }
        }
    }

    // MARK: - Debug (popover smoke)

    /// Debug menu for the executor-run popover smoke: seeds fake quota +
    /// traffic so the popover renders with data, and can simulate the
    /// credential alert. DEBUG builds only.
    #if DEBUG
    @ViewBuilder
    private var debugMenu: some View {
        Menu {
            Button("Seed demo data") { seedDemoData() }
            Button("Clear demo data") { clearDemoData() }
            Divider()
            Button("Simulate credential alert") {
                proxyServer.credentialEvents.emit(.expired(reason: "demo (seeded)"))
            }
            Button("Resolve credential alert (demo)") {
                proxyServer.credentialEvents.emit(.renewed(expiresAtMs: Int64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)))
            }
        } label: {
            Image(systemName: "ladybug")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Debug menu")
    }
    #else
    @ViewBuilder
    private var debugMenu: some View { EmptyView() }
    #endif

    #if DEBUG
    private func seedDemoData() {
        quotaModel.seedDemo(fraction: 0.63)
        let now = Date()
        let seeds: [(TimeInterval, TrafficEntry)] = [
            (-6, TrafficEntry(
                model: "glm-5.3", routeType: .mapped(targetModel: "GLM-5.3"),
                requestKind: .generation, httpStatus: 200, duration: 4.2, outputTokens: 2140,
                timestamp: now.addingTimeInterval(-6)).with(requestClass: .main)),
            (-21, TrafficEntry(
                model: "glm-5.3-flash", routeType: .mapped(targetModel: "Qwen3.8-27B-4bit"),
                requestKind: .generation, httpStatus: 200, duration: 12.8, outputTokens: 960,
                timestamp: now.addingTimeInterval(-21)).with(requestClass: .subagent)),
            (-34, TrafficEntry(
                model: "glm-5.3", routeType: .mapped(targetModel: "GLM-5.3"),
                requestKind: .webSearchBridge(searchCount: 2), httpStatus: 200, duration: 3.1,
                timestamp: now.addingTimeInterval(-34)).with(requestClass: .main)),
            (-47, TrafficEntry(
                model: "glm-5.3[1m]", routeType: .mapped(targetModel: "GLM-5.3-Flash"),
                requestKind: .countTokens, httpStatus: 200, duration: 0.2,
                timestamp: now.addingTimeInterval(-47)).with(requestClass: .auxiliary)),
            (-63, TrafficEntry(
                model: "claude-haiku-4-5", routeType: .blocked,
                requestKind: .blocked, httpStatus: 403,
                timestamp: now.addingTimeInterval(-63)).with(requestClass: .auxiliary)),
            (-88, TrafficEntry(
                model: "glm-5.3", routeType: .mapped(targetModel: "GLM-5.3"),
                requestKind: .generation, httpStatus: 529, duration: 31.6,
                timestamp: now.addingTimeInterval(-88)).with(requestClass: .workflow)),
        ]
        for (_, entry) in seeds {
            trafficLog.append(entry)
        }
    }

    private func clearDemoData() {
        quotaModel.clearDemo()
    }
    #endif

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Presents the alert for UNSEEN credential events only (high-water
    /// mark in `CredentialAlertPresenter.shared`), so one expiry does not
    /// re-present the modal on every popover open after a successful
    /// re-login. An event that fired while the popover was closed is unseen
    /// and still alerts on the next open.
    private func presentLatestCredentialEvent() {
        guard case let .expired(reason)? = CredentialAlertPresenter.shared.consume(
            events: proxyServer.credentialEvents.events)
        else { return }
        reloginMessage = ReloginAlertContent.message(for: reason)
        showingReloginAlert = true
    }

    // MARK: - Status Indicator

    @ViewBuilder
    private var statusIndicator: some View {
        Group {
            if proxyServer.isRunning {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                    Text("Running").font(.callout).fontWeight(.medium)
                }
            } else if proxyServer.lastError != nil {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                    Text("Error").font(.callout).fontWeight(.medium)
                }
            } else if proxyServer.isStopped {
                HStack(spacing: 6) {
                    Image(systemName: "pause.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Paused").font(.callout).fontWeight(.medium)
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Starting…").font(.callout)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(statusAccessibilityLabel)
    }

    private var statusAccessibilityLabel: String {
        if proxyServer.isRunning { return "Proxy running" }
        if proxyServer.lastError != nil { return "Proxy error" }
        if proxyServer.isStopped { return "Proxy paused" }
        return "Proxy starting"
    }

    // MARK: - Traffic

    /// Column headers, shared by the empty state and the pinned section
    /// header so the two branches can never drift apart. Lives INSIDE the
    /// scroll container as a pinned section header: any scrollbar inset
    /// applies to header and rows alike, so the columns stay aligned in
    /// every scrollbar state.
    private var trafficHeader: some View {
        HStack(spacing: 6) {
            Text("Recent Requests")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text("ttft")
                .frame(width: 48, alignment: .trailing)
            Text("tok/s")
                .frame(width: 46, alignment: .trailing)
            Text("in")
                .frame(width: 52, alignment: .trailing)
            Text("code")
                .frame(width: 34, alignment: .trailing)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
        .background(.thinMaterial)
    }

    @ViewBuilder
    private var trafficSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if trafficLog.entries.isEmpty {
                trafficHeader
                Text("No requests yet")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            Section {
                                ForEach(trafficLog.entries) { entry in
                                    TrafficRowView(entry: entry)
                                        .id(entry.id)
                                }
                            } header: {
                                trafficHeader
                            }
                        }
                    }
                    .frame(height: 240)
                    // Cosmetic: keeps the indicator knob off the code column
                    // during auto-scrolls. Alignment no longer depends on it —
                    // the header lives in the same scroll container, so any
                    // scrollbar inset hits header and rows equally.
                    .scrollIndicators(.hidden)
                    .onChange(of: trafficLog.entries.last?.id) { _, _ in
                        if let last = trafficLog.entries.last {
                            if reduceMotion {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            } else {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - TrafficRowView

/// Spec §6 request-log row: time, class → target, model, ms, tokens, status.
private struct TrafficRowView: View {
    let entry: TrafficEntry

    var body: some View {
        HStack(spacing: 6) {
            Text(entry.timeDisplayText)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.tertiary)

            VStack(alignment: .leading, spacing: 0) {
                Text(entry.displayModelLabel)
                    .font(.body)
                    .foregroundStyle(entry.isAuxiliaryTraffic ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.classTargetDisplayLabel)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(entry.ttftDisplayText)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 48, alignment: .trailing)

            Text(entry.tokensPerSecondDisplayText)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 46, alignment: .trailing)

            Text(entry.inputTokensDisplayText)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .trailing)

            Text("\(entry.httpStatus)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(statusColor)
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    /// Errors keep color; success is the default reading and needs none —
    /// green stays reserved for process-up status and the quota scale.
    private var statusColor: Color {
        switch entry.httpStatus {
        case 200..<300: return .secondary
        case 400..<500: return .orange
        default: return .red
        }
    }

    private var accessibilitySummary: String {
        // The unit is spoken only for a real value — "— tok/s" would
        // announce a unit for a number that does not exist.
        let tps = entry.tokensPerSecondDisplayText
        let tpsSpoken = tps == "—" ? tps : "\(tps) tok/s"
        var summary = "\(entry.timeDisplayText), \(entry.displayModelLabel), \(entry.classTargetDisplayLabel), HTTP \(entry.httpStatus), TTFT \(entry.ttftDisplayText), \(tpsSpoken)"
        if let input = entry.inputTokens, input > 0 {
            summary += ", \(input.compactTokenString) input tokens"
        }
        return summary
    }

}

// Note: running state with bound ports requires runtime start;
// isRunning and boundPorts are private(set) and cannot be set from a preview.
#Preview("Starting / Stopped") {
    let store = TokenStatsStore()
    let server = ProxyServer(tokenStatsStore: store)
    let quotaModel = QuotaStatusModel.live(server)
    quotaModel.seedDemo(fraction: 0.63)
    let splashManager = SplashManager()

    let log = TrafficLog()
    log.append(
        TrafficEntry(
            model: "glm-5.3", routeType: .mapped(targetModel: "GLM-5.3"),
            requestKind: .generation, httpStatus: 200, duration: 2.4, outputTokens: 1870)
            .with(requestClass: .main))
    log.append(
        TrafficEntry(
            model: "glm-5.3-flash", routeType: .mapped(targetModel: "Qwen3.8-27B-4bit"),
            requestKind: .generation, httpStatus: 200, duration: 12.5, outputTokens: 940)
            .with(requestClass: .subagent))
    log.append(
        TrafficEntry(
            model: "glm-5.3", routeType: .passthrough, requestKind: .countTokens,
            httpStatus: 200, duration: 0.3)
            .with(requestClass: .auxiliary))
    log.append(
        TrafficEntry(
            model: "claude-haiku-4-5", routeType: .blocked, requestKind: .blocked,
            httpStatus: 403))

    return StatusPopover()
        .environment(ConfigStore())
        .environment(server)
        .environment(log)
        .environment(store)
        .environment(LoginItemService())
        .environment(quotaModel)
        .environment(splashManager)
        .environment(CredentialStatusModel())
        .environment(UpdateCenter())
        .environment(AppUpdateService())
}

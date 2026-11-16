import Combine
import SwiftUI

struct StatusPopover: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer
    @Environment(TrafficLog.self) private var trafficLog
    @Environment(QuotaStatusModel.self) private var quotaModel
    @Environment(\.openSettings) private var openSettings
    @State private var showingCorruptAlert: Bool = false
    @State private var showingReloginAlert: Bool = false
    @State private var reloginMessage: String = ""
    @State private var copiedEnvLine: Bool = false
    /// Slow tick so the splash chip and quota caption age without traffic.
    @State private var tick: Date = .now

    private let slowTick = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            bannerSection
                .padding(.horizontal, 12)
                .padding(.top, 12)

            clientHeader
                .padding(.horizontal, 12)
                .padding(.top, bannerIsVisible ? 8 : 12)
                .padding(.bottom, 8)

            Divider()

            quotaSection
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

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
        .frame(width: 400)
        .onAppear {
            if configStore.didResetFromCorrupt {
                showingCorruptAlert = true
                configStore.clearCorruptFlag()
            }
            presentLatestCredentialEvent()
            quotaModel.recompute()
        }
        .onReceive(slowTick) { _ in tick = .now }
        .onChange(of: proxyServer.credentialEvents.events.count) { _, _ in
            presentLatestCredentialEvent()
        }
        .onChange(of: proxyServer.quotaEvents.events.count) { _, _ in
            quotaModel.recompute()
        }
        .alert("Config Reset", isPresented: $showingCorruptAlert) {
            Button("OK") { }
        } message: {
            Text("config.json was corrupt and has been reset to defaults. Your previous settings were not recoverable.")
        }
        .alert(ReloginAlertContent.title, isPresented: $showingReloginAlert) {
            Button("Copy Command") {
                copyToClipboard(ReloginAlertContent.command)
            }
            Button("OK", role: .cancel) { }
        } message: {
            Text(reloginMessage)
        }
        .task {
            guard !proxyServer.isRunning, !proxyServer.isStopped else { return }
            await proxyServer.start(config: configStore.config)
        }
    }

    private var bannerIsVisible: Bool {
        proxyServer.lastError != nil
    }

    // MARK: - Banner

    @ViewBuilder
    private var bannerSection: some View {
        if !proxyServer.isRunning, let error = proxyServer.lastError {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.leading)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("Error: \(error)")
        } else if proxyServer.isRunning, let error = proxyServer.lastError {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.leading)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("Warning: \(error)")
        }

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
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }
            if proxyServer.boundPorts.isEmpty {
                Text("No active listeners")
                    .font(.caption)
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
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Refresh quota now")
                .accessibilityHint("Polls the billing endpoints immediately.")
            }
        }
    }

    // MARK: - Rules summary + splash health

    private var splashHealth: SplashHealth? {
        SplashHealth.evaluate(
            vendors: configStore.config.vendors,
            lastSuccess: { id in
                (proxyServer.healthProvider as? LocalHealthMonitor)?.lastSuccess(forVendor: id)
            },
            now: tick)
    }

    @ViewBuilder
    private var rulesAndHealthSection: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if let summary = RulesSummary.text(
                    mappings: configStore.config.modelMappings,
                    vendors: configStore.config.vendors)
                {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                } else {
                    Text("No rules enabled — unmatched models pass through")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            if let splash = splashHealth {
                splashChip(splash)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func splashChip(_ health: SplashHealth) -> some View {
        let (color, symbol): (Color, String) = {
            switch health {
            case .up: return (.green, "drop.fill")
            case .down: return (.red, "drop")
            case .unknown: return (.secondary, "drop.triangle")
            }
        }()
        return HStack(spacing: 3) {
            Image(systemName: symbol)
                .imageScale(.small)
            Text(health.label)
        }
        .font(.caption2)
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.10))
        .clipShape(Capsule())
        .help("Splash local target reachability (TCP probe, 20 s cadence)")
        .accessibilityLabel(health.label)
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
                    .font(.caption2.monospaced())
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
                        .font(.caption2)
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
                .frame(width: 110, alignment: .leading)

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

                Button {
                    openSettings()
                    Task { @MainActor in
                        NSApp.setActivationPolicy(.regular)
                        try? await Task.sleep(for: .milliseconds(100))
                        NSApp.activate()
                        if let w = NSApp.windows.first(where: {
                            $0.identifier?.rawValue == "com.apple.SwiftUI.Settings"
                                || ($0.isVisible && $0.styleMask.contains(.titled)
                                    && $0.title.localizedCaseInsensitiveContains("settings"))
                        }) {
                            w.makeKeyAndOrderFront(nil)
                            w.orderFrontRegardless()
                        }
                    }
                } label: {
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
                HStack(spacing: 5) {
                    Circle().fill(.green).frame(width: 7, height: 7)
                    Text("Running").font(.caption).fontWeight(.medium)
                }
            } else if proxyServer.lastError != nil {
                HStack(spacing: 5) {
                    Circle().fill(.red).frame(width: 7, height: 7)
                    Text("Error").font(.caption).fontWeight(.medium).foregroundStyle(.red)
                }
            } else if proxyServer.isStopped {
                HStack(spacing: 5) {
                    Circle().fill(.secondary).frame(width: 7, height: 7)
                    Text("Paused").font(.caption).fontWeight(.medium).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 5) {
                    ProgressView().scaleEffect(0.55).frame(width: 7, height: 7)
                    Text("Starting...").font(.caption).foregroundStyle(.secondary)
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

    @ViewBuilder
    private var trafficSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Recent Requests")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("ms")
                    .frame(width: 42, alignment: .trailing)
                Text("tok")
                    .frame(width: 34, alignment: .trailing)
                Text("code")
                    .frame(width: 28, alignment: .trailing)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)

            if trafficLog.entries.isEmpty {
                Text("No requests yet")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(trafficLog.entries) { entry in
                                TrafficRowView(entry: entry)
                                    .id(entry.id)
                            }
                        }
                    }
                    .frame(maxHeight: 240)
                    .onChange(of: trafficLog.entries.last?.id) { _, _ in
                        if let last = trafficLog.entries.last {
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

// MARK: - TrafficRowView

/// Spec §6 request-log row: time, class → target, model, ms, tokens, status.
private struct TrafficRowView: View {
    let entry: TrafficEntry

    var body: some View {
        HStack(spacing: 6) {
            Text(entry.timeDisplayText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)

            VStack(alignment: .leading, spacing: 0) {
                Text(entry.displayModelLabel)
                    .font(.caption2)
                    .foregroundStyle(entry.isAuxiliaryTraffic ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.classTargetDisplayLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(entry.msDisplayText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 42, alignment: .trailing)

            Text(entry.tokensDisplayText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 34, alignment: .trailing)

            Text("\(entry.httpStatus)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(statusColor)
                .frame(width: 28, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .opacity(entry.isAuxiliaryTraffic ? 0.82 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var statusColor: Color {
        switch entry.httpStatus {
        case 200..<300: return .green
        case 400..<500: return .orange
        default: return .red
        }
    }

    private var accessibilitySummary: String {
        "\(entry.timeDisplayText), \(entry.displayModelLabel), \(entry.classTargetDisplayLabel), HTTP \(entry.httpStatus), \(entry.msDisplayText), \(entry.tokensDisplayText) tokens"
    }

}

// Note: running state with bound ports requires runtime start;
// isRunning and boundPorts are private(set) and cannot be set from a preview.
#Preview("Starting / Stopped") {
    let store = TokenStatsStore()
    let server = ProxyServer(tokenStatsStore: store)
    let quotaModel = QuotaStatusModel.live(server)
    quotaModel.seedDemo(fraction: 0.63)

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
}

import SwiftUI

@main
struct ModelProxyApp: App {
    @State private var configStore: ConfigStore
    @State private var tokenStatsStore: TokenStatsStore
    @State private var proxyServer: ProxyServer
    @State private var loginItemService: LoginItemService
    @State private var quotaModel: QuotaStatusModel
    @State private var credentialModel: CredentialStatusModel
    @State private var splashManager: SplashManager

    init() {
        AppPaths.migrateLegacyDirIfNeeded()   // 2026-11-18: ModelProxy → ZGate, before any store reads
        let store = TokenStatsStore()
        _tokenStatsStore = State(initialValue: store)
        let configStore = ConfigStore()
        _configStore = State(initialValue: configStore)
        let server = ProxyServer(tokenStatsStore: store)
        _proxyServer = State(initialValue: server)
        _loginItemService = State(initialValue: LoginItemService())
        // Menu-bar icon (quota ring with the ZΓ mark inside) reads the same
        // model the popover renders; the slow tick keeps the ring fresh
        // while the popover is closed.
        let quotaModel = QuotaStatusModel.live(server)
        _quotaModel = State(initialValue: quotaModel)
        // Credential status (login-flow UI): the same model feeds the
        // popover row, the Settings section, and the menu-bar badge (via
        // ProxyServer.credentialActionNeeded).
        let credentialModel = CredentialStatusModel.live(server: server, configStore: configStore)
        _credentialModel = State(initialValue: credentialModel)
        let splashManager = SplashManager()
        _splashManager = State(initialValue: splashManager)
        // Serve from LAUNCH, not from the first popover open: MenuBarExtra
        // window content is created lazily, so a .task on it defers until a
        // human clicks — leaving a running-but-not-listening proxy for every
        // headless ANTHROPIC_BASE_URL consumer and every launch-at-login
        // session. start() guards on isRunning, so the popover's own start
        // path (and Resume) is a no-op after this; quotaModel.start() and
        // configure are idempotent the same way.
        Task {
            await server.start(config: configStore.config)
            quotaModel.start()
            credentialModel.start()
            await AppLogManager.shared.configure(from: configStore.config.debug)
            // Package C: adopt an external splash or start ours per settings.
            // Guard lives here, not in configure — SplashManagerTests call
            // configure directly under the XCTest environment and need real
            // behavior on stub processes.
            guard SplashManager.shouldSupervise(environment: ProcessInfo.processInfo.environment) else { return }
            await splashManager.configure(settings: configStore.config.splash)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            StatusPopover()
                .environment(configStore)
                .environment(proxyServer)
                .environment(proxyServer.trafficLog)
                .environment(tokenStatsStore)
                .environment(loginItemService)
                .environment(AppLogManager.shared)
                .environment(quotaModel)
                .environment(credentialModel)
                .environment(splashManager)
        } label: {
            MenuBarLabel(quotaModel: quotaModel, proxyServer: proxyServer)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(configStore)
                .environment(proxyServer)
                .environment(tokenStatsStore)
                .environment(loginItemService)
                .environment(AppLogManager.shared)
                .environment(quotaModel)
                .environment(credentialModel)
                .environment(splashManager)
        }
    }
}

/// Menu-bar mark: icon-only — the quota ring (template image, arc =
/// remaining weekly fraction) with the ZΓ brand mark drawn inside it in
/// the healthy state; fault symbols (paused / launching / error /
/// credentials) replace the whole mark when set. The exact percentage
/// stays glanceable in the popover and in the accessibility label.
/// Invalidates on the same observable state the popover renders, so bar
/// and popover can never disagree.
private struct MenuBarLabel: View {
    let quotaModel: QuotaStatusModel
    let proxyServer: ProxyServer

    var body: some View {
        Group {
            if let symbol = proxyServer.menuBarSymbol {
                Image(systemName: symbol)
            } else {
                Image(nsImage: QuotaMenuBarIcon.image(
                    weeklyFraction: quotaModel.state.weeklyFraction,
                    stale: quotaModel.state.isStale))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = ["ZGate"]
        parts.append(
            proxyServer.isRunning
                ? "running" : (proxyServer.isStopped ? "paused" : "starting"))
        if let percent = quotaModel.state.percentText {
            parts.append("weekly quota \(percent) remaining")
        } else {
            parts.append("quota data unavailable")
        }
        return parts.joined(separator: ", ")
    }
}

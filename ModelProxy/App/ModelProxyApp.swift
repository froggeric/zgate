import SwiftUI

@main
struct ModelProxyApp: App {
    @State private var configStore: ConfigStore
    @State private var tokenStatsStore: TokenStatsStore
    @State private var proxyServer: ProxyServer
    @State private var loginItemService: LoginItemService
    @State private var quotaModel: QuotaStatusModel

    init() {
        let store = TokenStatsStore()
        _tokenStatsStore = State(initialValue: store)
        let configStore = ConfigStore()
        _configStore = State(initialValue: configStore)
        let server = ProxyServer(tokenStatsStore: store)
        _proxyServer = State(initialValue: server)
        _loginItemService = State(initialValue: LoginItemService())
        // Menu-bar title "ZΓ 63%" (spec §6) reads the same model the popover
        // renders; the slow tick keeps the title fresh while the popover is
        // closed.
        let quotaModel = QuotaStatusModel.live(server)
        _quotaModel = State(initialValue: quotaModel)
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
            await AppLogManager.shared.configure(from: configStore.config.debug)
        }
    }

    var body: some Scene {
        MenuBarExtra(quotaModel.state.menuBarTitle, systemImage: proxyServer.menuBarSymbol) {
            StatusPopover()
                .environment(configStore)
                .environment(proxyServer)
                .environment(proxyServer.trafficLog)
                .environment(tokenStatsStore)
                .environment(loginItemService)
                .environment(AppLogManager.shared)
                .environment(quotaModel)
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
                .onDisappear {
                    NSApp.setActivationPolicy(.accessory)
                }
        }
    }
}

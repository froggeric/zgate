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
        _configStore = State(initialValue: ConfigStore())
        let server = ProxyServer(tokenStatsStore: store)
        _proxyServer = State(initialValue: server)
        _loginItemService = State(initialValue: LoginItemService())
        // Menu-bar title "ZΓ 63%" (spec §6) reads the same model the popover
        // renders; the slow tick keeps the title fresh while the popover is
        // closed.
        _quotaModel = State(initialValue: QuotaStatusModel.live(server))
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
                .task {
                    quotaModel.start()
                    await AppLogManager.shared.configure(from: configStore.config.debug)
                }
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

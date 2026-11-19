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
    @State private var updateCenter: UpdateCenter
    @State private var appUpdate: AppUpdateService

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
        // Update subsystem (spec §3.4/§3.5): ONE AppUpdateService shared by
        // the center's ZGate check and the popover's explicit Install
        // action (stage() needs the check's lastCheckedRelease), so both
        // scenes get the same instance through the environment.
        let appUpdate = AppUpdateService()
        _appUpdate = State(initialValue: appUpdate)
        let updateCenter = UpdateCenter(appUpdate: appUpdate)
        _updateCenter = State(initialValue: updateCenter)
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
            // Update subsystem (spec §3.4): persistence rides ConfigStore
            // (load once; the center hands back its settings on every
            // mutation and we write them through config.update).
            updateCenter.attach(
                configLoad: { [weak configStore] in configStore?.config.update },
                configWrite: { [weak configStore] settings in
                    guard let configStore else { return }
                    configStore.config.update = settings
                    configStore.save()
                })
            // Package C: adopt an external splash or start ours per settings.
            // Guard lives here, not in configure — SplashManagerTests call
            // configure directly under the XCTest environment and need real
            // behavior on stub processes. The SAME guard scopes the splash
            // half of the update subsystem (checks + manager hooks); the
            // ZGate check runs in every environment (spec §3.4).
            let supervise = SplashManager.shouldSupervise(
                environment: ProcessInfo.processInfo.environment)
            if supervise {
                await splashManager.configure(settings: configStore.config.splash)
                updateCenter.attach(to: splashManager)
            }
            await updateCenter.start(splashChecksEnabled: supervise)
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
                .environment(updateCenter)
                .environment(appUpdate)
        } label: {
            MenuBarLabel(quotaModel: quotaModel, proxyServer: proxyServer, updateCenter: updateCenter)
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
                .environment(updateCenter)
                .environment(appUpdate)
        }
    }
}

/// Menu-bar mark: icon-only — the quota ring (template image, arc =
/// remaining weekly fraction) with the ZΓ brand mark drawn inside it in
/// the healthy state, plus the spec §5 update badge dot when
/// `updateCenter.hasActiveAlert`; fault symbols (paused / launching /
/// error / credentials) replace the whole mark when set and always
/// outrank the badge. The exact percentage stays glanceable in the
/// popover and in the accessibility label. Invalidates on the same
/// observable state the popover renders, so bar and popover can never
/// disagree. (Internal: UpdateAlertUITests pin the pure accessibility
/// helper.)
struct MenuBarLabel: View {
    let quotaModel: QuotaStatusModel
    let proxyServer: ProxyServer
    let updateCenter: UpdateCenter

    var body: some View {
        Group {
            if let symbol = proxyServer.menuBarSymbol {
                Image(systemName: symbol)
            } else {
                Image(nsImage: QuotaMenuBarIcon.image(
                    weeklyFraction: quotaModel.state.weeklyFraction,
                    stale: quotaModel.state.isStale,
                    updateAvailable: updateCenter.hasActiveAlert))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        // The pure helper's `running` Bool carries running/paused;
        // "starting" (neither running nor stopped) is the one nuance it
        // cannot — computed here, everything else stays shared.
        let status = proxyServer.isRunning
            ? "running" : (proxyServer.isStopped ? "paused" : "starting")
        return Self.label(
            status: status,
            quotaPercent: quotaModel.state.percentText,
            updateAvailable: updateCenter.hasActiveAlert)
    }

    /// Pure, tested form of the accessibility label.
    nonisolated static func accessibilityText(
        running: Bool, quotaPercent: String?, updateAvailable: Bool
    ) -> String {
        label(
            status: running ? "running" : "paused",
            quotaPercent: quotaPercent,
            updateAvailable: updateAvailable)
    }

    private nonisolated static func label(
        status: String, quotaPercent: String?, updateAvailable: Bool
    ) -> String {
        var parts = ["ZGate", status]
        parts.append(
            quotaPercent.map { "weekly quota \($0) remaining" }
                ?? "quota data unavailable")
        if updateAvailable { parts.append("update available") }
        return parts.joined(separator: ", ")
    }
}

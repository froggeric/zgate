import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import AsyncHTTPClient
import NIOHTTPCompression
import Observation
import OSLog

/// Manages one NIO listener per configured client port.
/// @MainActor: all state mutations happen on main thread for SwiftUI observers.
@MainActor
@Observable
final class ProxyServer {

    // MARK: - Observable State

    private(set) var isRunning: Bool = false
    /// True after user explicitly stops the proxy. Cleared on next start().
    private(set) var isStopped: Bool = false
    private(set) var lastError: String? = nil
    /// Ports currently bound, keyed by clientName for display.
    private(set) var boundPorts: [String: Int] = [:]
    /// Traffic log shared with all channel handlers.
    let trafficLog: TrafficLog = TrafficLog()
    /// Token stats store shared with all channel handlers.
    let tokenStatsStore: TokenStatsStore
    private let lineageBroker: any SessionLineageBrokering
    private let portableNormalizer: any PortableContentNormalizing
    private let requestCoordinator: any BranchRequestCoordinating
    private(set) var webSearchProvider: (any WebSearchBridgeProviding)?
    private(set) var webSearchForwardAsIs: Bool = false

    /// Relay signing context — built once per process on the first `start`
    /// with a relay-kind vendor configured. One SigningClient + a stable
    /// `x-session-id` for the whole run (zbridge per-process parity). The
    /// reference is passed around; its contents are never logged.
    private(set) var relayContext: RelayTarget.Context?
    /// Credential events surfaced to the UI (re-login alert observes).
    let credentialEvents = CredentialEventChannel()
    /// True while the credential face is `actionNeeded` (login-flow UI
    /// item 2): written by `CredentialStatusModel` on every recompute, read
    /// by `menuBarSymbol` for the exclamation badge — the menu bar stays
    /// truthful while the popover is closed.
    var credentialActionNeeded: Bool = false
    /// Quota threshold-crossing events surfaced to the UI (Task 9 observes).
    let quotaEvents = QuotaEventChannel()
    /// Routing-condition seams; Tasks 7 (health) / 8 (quota) provide the
    /// real implementations. nil = fail-open (see RouterExtensions).
    var healthProvider: (any TargetHealthProviding)?
    var quotaProvider: (any QuotaSnapshotProviding)?
    /// Quota poll service (Task 8): built once per process on the first
    /// `start` with a relay-kind vendor configured, like the signing context.
    /// Polling outlives server stop/start (billing is independent of the
    /// listener), so it is never torn down in `stop()`.
    private var quotaService: QuotaService?
    /// Endpoint routing service (relay fidelity Task 1): same lifecycle as
    /// the quota service — one per process, lazy `agent/configs` refresh
    /// consulted per relay request, fail-open on every failure. Never built
    /// inside the isolated test host (no live API calls from suite runs).
    private var endpointConfigService: EndpointConfigService?
    /// Client-version pin service (relay fidelity Task 4): polls
    /// `client/configs` at launch + every 6 h and bumps the impersonated
    /// CLI version when the server minimum rises (greater-only, silent on
    /// failure). Same lifecycle as the endpoint-routing service; never built
    /// inside the isolated test host.
    private var versionPinService: VersionPinService?
    /// Persistence sink for accepted version bumps — the app layer owns
    /// ConfigStore, so it injects this write-through (nil = bumps stay
    /// in-memory for this process only).
    var clientVersionSink: (@MainActor (String) -> Void)?
    /// Persistence sink for a minted fallback-edge key (relay fidelity
    /// Task 7) — the app layer writes it into the fallback vendor's
    /// `apiKey` (config.json) and hot-reloads routing. nil = the key stays
    /// in RelayHealth's memory for this process only.
    var fallbackKeySink: (@MainActor (String) -> Void)?
    /// Relay health machine (relay fidelity Task 7): the relay plane's
    /// degraded/risk admission gate plus the fallback edge's key
    /// lifecycle. Built once per process with the relay context; survives
    /// stop/start like the signing context.
    private var relayHealth: RelayHealth?
    /// Proactive renewal loop (item 5): started with the relay context,
    /// runs for the process. See start() for the test-host exclusion.
    @ObservationIgnored
    private var credentialKeeper: CredentialKeeper?
    /// Splash health probe (Task 7): TCP-probes loopback vendors and feeds
    /// the health seam. Built on first start, kept across restarts, and
    /// reconfigured whenever config changes. An explicitly injected
    /// `healthProvider` (tests) is never overridden.
    private var localHealthMonitor: LocalHealthMonitor?
    /// SigningClient factory for the relay context. Injectable for tests;
    /// the default is the production chain — best-effort store load, so a
    /// missing store surfaces at request time as the relay's
    /// signing-unavailable 502, never an unsigned request.
    @ObservationIgnored
    private let makeSigningClient: (@Sendable () -> SigningClient)?
    /// Off-peak async surface context (relay fidelity Task 10): built once
    /// per process like the signing context (no network at init — the
    /// surface is default-OFF and answers locally until enabled);
    /// `updateRouting` refreshes its config in place.
    @ObservationIgnored
    private var offPeakContext: OffPeakTarget.Context?

    // MARK: - Init

    init(
        tokenStatsStore: TokenStatsStore,
        lineageBroker: any SessionLineageBrokering = SessionLineageBroker(store: LineageStoreFactory.makeDefaultStore()),
        portableNormalizer: any PortableContentNormalizing = PortableContentNormalizer(),
        requestCoordinator: any BranchRequestCoordinating = BranchRequestCoordinator(),
        makeSigningClient: (@Sendable () -> SigningClient)? = nil
    ) {
        self.tokenStatsStore = tokenStatsStore
        self.lineageBroker = lineageBroker
        self.portableNormalizer = portableNormalizer
        self.requestCoordinator = requestCoordinator
        self.makeSigningClient = makeSigningClient
    }

    // MARK: - Internal State

    /// Live credential-store base (login-flow UI, item 4): the relay
    /// context's store loader re-resolves through this box on every
    /// attempt, so the Settings store selector takes effect on the next
    /// chain rebuild — no app restart (`updateRouting` rewrites it).
    private final class StoreBaseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var base: URL

        init(_ base: URL) { self.base = base }

        var current: URL { lock.withLock { base } }
        func set(_ newValue: URL) { lock.withLock { base = newValue } }
    }

    private let storeBaseBox = StoreBaseBox(CredentialStore.resolveBase(nil))

    private struct ListenerSlot {
        let channel: any Channel
        let router: RequestRouter
        let clientName: String
    }

    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var httpClient: HTTPClient?
    private var listeners: [ListenerSlot] = []

    // MARK: - Start

    /// Start one listener per client in `config`. Idempotent if already running.
    func start(config: AppConfig) async {
        guard !isRunning else { return }
        isStopped = false
        lastError = nil

        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        self.eventLoopGroup = group

        let clientConfig = HTTPClient.Configuration(
            redirectConfiguration: .disallow,
            timeout: .init(connect: .seconds(10)),
            decompression: .enabled(limit: .ratio(10))
        )
        let client = HTTPClient(eventLoopGroupProvider: .shared(group), configuration: clientConfig)
        self.httpClient = client
        self.webSearchProvider = WebSearchProviderFactory.make(from: config.webSearch)
        self.webSearchForwardAsIs = config.webSearch.provider == .forwardAsIs

        var slots: [ListenerSlot] = []
        var errors: [String] = []

        let trafficLog = self.trafficLog
        let tokenStatsStore = self.tokenStatsStore

        // Relay signing context: one per process, only when a relay-kind
        // vendor is configured. Best-effort store load (no secret leaves the
        // SigningClient); a cold start with no store fails later as the
        // signing-unavailable 502, never an unsigned request.
        if relayContext == nil, config.vendors.contains(where: { $0.vendorKind == .relay }) {
            // Store base: the persisted `credentialStoreBase` setting, nil =
            // the GUI/CLI shared default (item 2 of the login-flow wave).
            // Store-as-loader (item 3): no eager snapshot — the loader
            // re-runs per login attempt through the live box, so an
            // external re-login that rewrites the shared store — or a
            // Settings selector change (`updateRouting`) — is picked up by
            // this RUNNING process on the next chain rebuild.
            storeBaseBox.set(CredentialStore.resolveBase(config.credentialStoreBase))
            let signingClient = makeSigningClient?() ?? {
                var configuration = SigningClient.Configuration()
                let box = storeBaseBox
                configuration.storeLoader = {
                    try CredentialStore.loadDefault(base: box.current)
                }
                return SigningClient(configuration: configuration)
            }()
            // Quota service: polls z.ai's official monitor API with the same
            // z.ai API key Claude Code uses (read from the Claude settings
            // file at poll time — no credential-store involvement, no secret
            // in ZGate's config). Without a readable key the router seam
            // stays fail-open. Counting relayed requests rides the context,
            // so the 25-request poll trigger is wired exactly where relay
            // exchanges happen.
            if quotaService == nil {
                let service = QuotaService(events: quotaEvents)
                quotaService = service
                service.startPolling()
                AppLog.proxy.info("[ProxyServer] Quota service polling (monitor API, relay vendor configured)")
            }
            // Endpoint routing (relay fidelity Task 1): lazy agent/configs
            // refresh with the CLI's identity headers. The apiKeyId rides
            // the signing session when one exists; the flagged-request
            // Bearer material is the credential store's zcode plan JWT,
            // re-read per request through the live base box (a re-login or
            // Settings selector change takes effect on the next flagged
            // request). Both fail-open to "omit". Skipped entirely inside
            // the isolated test host — the relay path then serves the
            // pinned URL, exactly like a routing outage.
            if endpointConfigService == nil, AppPaths.isolatedBase == nil {
                var configuration = EndpointConfigService.Configuration()
                let signing = signingClient
                let box = storeBaseBox
                configuration.apiKeyIdProvider = { await signing.currentApiKeyId() }
                configuration.zcodeTokenProvider = {
                    (try? CredentialStore.loadDefault(base: box.current))
                        .flatMap { try? $0.zcodeJwtToken() }
                }
                let service = EndpointConfigService(configuration: configuration)
                endpointConfigService = service
                AppLog.proxy.info("[ProxyServer] Endpoint routing service ready (agent/configs, fail-open)")
            }
            // Relay health (relay fidelity Task 7): the degraded machine +
            // the fallback edge's mint chain. The mint's biz JWT comes from
            // the signing chain; the minted key persists through the app
            // layer's sink. Never built inside the isolated test host (no
            // live API calls from suite runs) — the health machine itself
            // still runs there, mint-free, exactly like a config without a
            // fallback key.
            if relayHealth == nil {
                var healthConfiguration = RelayHealth.Configuration()
                if AppPaths.isolatedBase == nil {
                    var minterConfiguration = ApiKeyMinter.Configuration()
                    minterConfiguration.bizJWTProvider = { try await signingClient.currentBizJWT() }
                    healthConfiguration.minter = ApiKeyMinter(configuration: minterConfiguration)
                    let sink = fallbackKeySink
                    healthConfiguration.onKeyMinted = { key in
                        Task { @MainActor in sink?(key) }
                    }
                }
                relayHealth = RelayHealth(configuration: healthConfiguration)
                AppLog.proxy.info("[ProxyServer] Relay health machine ready (degraded probes, fallback edge)")
            }
            // Client-version pin (relay fidelity Task 4): poll
            // client/configs for the server's force-update minimum; a
            // greater-only bump updates the live relay context (all four
            // version surfaces) and persists through the app layer's sink.
            // Silent on every failure — the current pin keeps serving.
            if versionPinService == nil, AppPaths.isolatedBase == nil {
                var configuration = VersionPinService.Configuration()
                configuration.initialVersion = config.relayClientVersion
                let box = storeBaseBox
                configuration.zcodeTokenProvider = {
                    (try? CredentialStore.loadDefault(base: box.current))
                        .flatMap { try? $0.zcodeJwtToken() }
                }
                let sink = clientVersionSink
                configuration.onBump = { [weak self] version in
                    Task { @MainActor [weak self] in
                        self?.relayContext?.clientVersion = version
                        sink?(version)
                    }
                }
                let service = VersionPinService(configuration: configuration)
                versionPinService = service
                await service.startPolling()
                AppLog.proxy.info("[ProxyServer] Version pin service polling (client/configs, 6 h cadence)")
            }
            relayContext = RelayTarget.Context(
                signingClient: signingClient,
                credentialEvents: credentialEvents,
                quota: quotaService,
                endpointConfig: endpointConfigService,
                clientVersion: config.relayClientVersion,
                relayHealth: relayHealth)
            AppLog.proxy.info("[ProxyServer] Relay signing context ready (relay vendor configured)")
            // Proactive renewal (item 5, report §C.4): keep the ladder
            // alive without relayed traffic. Runs for the process (never
            // torn down on stop/start, same ruling as quota polling) —
            // but never inside an isolated test host, where background
            // chain builds would hit the live API from a suite run.
            if AppPaths.isolatedBase == nil {
                let events = credentialEvents
                let keeper = CredentialKeeper(client: signingClient) { event in
                    Task { @MainActor in events.emit(event) }
                }
                keeper.start()
                credentialKeeper = keeper
                AppLog.proxy.info("[ProxyServer] Credential keeper running (proactive renewal)")
            }
        }
        let relayContext = self.relayContext

        // Off-peak async surface (relay fidelity Task 10): one context per
        // process over the shared server HTTP client. The zcode plan JWT
        // re-reads the credential store through the live base box (same
        // wiring as the endpoint-routing service); the coding-plan key is
        // Task 7's minted credential via the relay health machine. Both
        // answer nil when unavailable — the surface then fails its calls
        // cleanly (the orchestrator's tolerance ladder), never unsigned.
        if offPeakContext == nil {
            let box = storeBaseBox
            let health = self.relayHealth
            let versionSource = relayContext
            offPeakContext = OffPeakTarget.Context(
                config: config.offPeak,
                httpClient: client,
                jwtProvider: {
                    (try? CredentialStore.loadDefault(base: box.current))
                        .flatMap { try? $0.zcodeJwtToken() }
                },
                credentialProvider: { await health?.fallbackKey() },
                clientVersionProvider: { versionSource?.clientVersion ?? RelayTarget.clientVersion })
            AppLog.proxy.info("[ProxyServer] Off-peak async context ready (default-OFF until enabled)")
        }
        let offPeakContext = self.offPeakContext

        // Local health probe (Task 7): registers BEFORE any RequestRouter is
        // built below — routers capture the provider at construction (Task 6
        // lifecycle note), so this is the one point where the splash probe
        // connects to the router's health conditions.
        // Spec §6.1: the splash vendor's derived target (routing baseURL,
        // health-probe port) follows the configured `splash.port` — the
        // stored vendor row keeps its seeded 8123 default (in-memory sync
        // only, never persisted).
        let vendors = AppConfig.syncingSplashVendor(config.vendors, splashPort: config.splash?.port)
        // Fix round 1: push the fallback edge target for the DIRECT degraded
        // serve (class rules carry no rule backup). nil when the user
        // removed the edge vendor — degraded admission then answers today's
        // terminal.
        if let relayHealth {
            let edgeTarget = Self.fallbackEdgeRouteTarget(vendors: vendors)
            await relayHealth.configureFallbackEdgeTarget(edgeTarget)
        }
        if localHealthMonitor == nil {
            localHealthMonitor = LocalHealthMonitor()
        }
        localHealthMonitor?.configure(vendors: vendors)
        localHealthMonitor?.startProbing()
        if healthProvider == nil {
            healthProvider = localHealthMonitor
        }
        // Same lifecycle rule for the quota seam: routers capture the
        // provider at construction below; an injected `quotaProvider`
        // (tests) is never overridden.
        if quotaProvider == nil {
            quotaProvider = quotaService
        }

        // Spec §6.1: routing targets for the splash vendor follow the
        // configured `splash.port` (same synced array the health probe uses).
        for clientCfg in config.clients {
            let snapshot = RoutingSnapshot(from: config, for: clientCfg, vendors: vendors)
            let router = RequestRouter(
                snapshot: snapshot,
                healthProvider: healthProvider,
                quotaProvider: quotaProvider)

            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 256)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                        channel.pipeline.addHandler(
                            ProxyChannelHandler(
                                clientName: clientCfg.clientName,
                                router: router,
                                httpClient: client,
                                trafficLog: trafficLog,
                                tokenStatsStore: tokenStatsStore,
                                lineageBroker: self.lineageBroker,
                                portableNormalizer: self.portableNormalizer,
                                requestCoordinator: self.requestCoordinator,
                                webSearchProvider: self.webSearchProvider,
                                webSearchForwardAsIs: self.webSearchForwardAsIs,
                                relayContext: relayContext,
                                localHealth: self.localHealthMonitor,
                                offPeak: offPeakContext
                            )
                        )
                    }
                }
                .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)

            // Port auto-advance (binding plan): if the configured port is
            // taken, bind the next free port (bounded +1...+20) so the
            // copyable env line never advertises a dead port. The config
            // keeps the configured port; `boundPorts` carries the truth the
            // UI reads. Only EADDRINUSE advances — other bind errors
            // (permissions, bad port) fail immediately.
            let maxAdvance = 20
            var channel: (any Channel)?
            var bindError: (any Error)?
            for offset in 0...maxAdvance {
                do {
                    channel = try await bootstrap.bind(host: "127.0.0.1", port: clientCfg.port + offset).get()
                    if offset > 0 {
                        AppLog.proxy.info("[ProxyServer] Port \(clientCfg.port) (\(clientCfg.clientName)) in use; advanced to \(clientCfg.port + offset)")
                    }
                    break
                } catch let err as NIOCore.IOError where err.errnoCode == EADDRINUSE {
                    bindError = err
                    continue
                } catch {
                    bindError = error
                    break
                }
            }
            if let channel {
                let actualPort = channel.localAddress?.port ?? clientCfg.port
                AppLog.proxy.info("[ProxyServer] \(clientCfg.clientName) listening on 127.0.0.1:\(actualPort)")
                slots.append(ListenerSlot(channel: channel, router: router, clientName: clientCfg.clientName))
                boundPorts[clientCfg.clientName] = actualPort
            } else if let bindError, let ioError = bindError as? NIOCore.IOError,
                ioError.errnoCode == EADDRINUSE
            {
                errors.append("Ports \(clientCfg.port)–\(clientCfg.port + maxAdvance) (\(clientCfg.clientName)) all in use.")
            } else if let bindError {
                errors.append("Failed to start \(clientCfg.clientName): \(bindError.localizedDescription)")
            }
        }

        self.listeners = slots

        if slots.isEmpty {
            // No listeners started — surface first error and clean up.
            self.lastError = errors.first ?? "No clients configured."
            try? await client.shutdown()
            try? await group.shutdownGracefully()
            self.httpClient = nil
            self.eventLoopGroup = nil
        } else {
            self.isRunning = true
            if !errors.isEmpty {
                // Partial start — surface warnings but remain running.
                self.lastError = errors.joined(separator: " ")
            }
        }
    }

    // MARK: - Stop

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        isStopped = true
        boundPorts = [:]

        for slot in listeners {
            try? await slot.channel.close().get()
        }
        listeners = []

        await localHealthMonitor?.stopProbing()

        try? await httpClient?.shutdown()
        httpClient = nil

        try? await eventLoopGroup?.shutdownGracefully()
        eventLoopGroup = nil

        AppLog.proxy.info("[ProxyServer] Stopped.")
    }

    /// SF Symbol name for the menu bar icon, or nil when the healthy
    /// running state should draw the quota ring instead (the ring arc is
    /// the remaining weekly quota; see QuotaMenuBarIcon). Template
    /// rendering adapts every case to light/dark. Priority order: fault
    /// states outrank telemetry — a stopped proxy or a needed login is
    /// more urgent than any percentage.
    nonisolated static func menuBarSymbol(
        isRunning: Bool, hasError: Bool, credentialActionNeeded: Bool, isStopped: Bool
    ) -> String? {
        guard isRunning else {
            if hasError { return "exclamationmark.circle" }
            return isStopped ? "pause.circle" : "hourglass"
        }
        if credentialActionNeeded { return "exclamationmark.triangle" }
        if hasError { return "exclamationmark.circle" }
        return nil
    }

    var menuBarSymbol: String? {
        Self.menuBarSymbol(
            isRunning: isRunning,
            hasError: lastError != nil,
            credentialActionNeeded: credentialActionNeeded,
            isStopped: isStopped)
    }

    /// The fallback edge's route target built from the live vendor rows
    /// (fix round 1: the direct degraded serve). nil when no vendor points
    /// at the pinned edge.
    private static func fallbackEdgeRouteTarget(
        vendors: [Vendor]
    ) -> RoutingSnapshot.RouteTarget? {
        guard let vendor = vendors.first(where: { ApiKeyMinter.isFallbackEdge($0.baseURL) }) else {
            return nil
        }
        return RoutingSnapshot.RouteTarget(
            baseURL: vendor.baseURL,
            apiKey: vendor.apiKey,
            vendorName: vendor.name,
            vendorID: vendor.id,
            targetModel: nil,
            isPassthrough: false,
            connectTimeoutSeconds: vendor.connectTimeoutSeconds,
            readTimeoutSeconds: vendor.readTimeoutSeconds,
            signingDomain: vendor.signingDomain,
            replayPolicy: vendor.replayPolicy,
            supportsThinkingBlocks: vendor.supportsThinkingBlocks,
            supportsAnthropicCountTokens: vendor.supportsAnthropicCountTokens,
            repairsAnthropicToolCalls: vendor.repairsAnthropicToolCalls,
            stripsClaudeOnlyRequestFields: vendor.stripsClaudeOnlyRequestFields,
            applyGLMCanonicalization: vendor.applyGLMCanonicalization,
            vendorKind: vendor.vendorKind)
    }

    // MARK: - Hot Reload

    /// Push a new routing snapshot to all listeners that match by clientName.
    /// Called after ConfigStore.save(); does not restart any channel.
    func updateRouting(config: AppConfig) {
        self.webSearchProvider = WebSearchProviderFactory.make(from: config.webSearch)
        self.webSearchForwardAsIs = config.webSearch.provider == .forwardAsIs
        // Off-peak async surface: the live toggle/origin takes effect on
        // the next request (the context box is read per request).
        offPeakContext?.updateConfiguration(config.offPeak)
        // The credential-store selector rides along live (no restart): the
        // relay loader re-resolves through the box on every attempt.
        storeBaseBox.set(CredentialStore.resolveBase(config.credentialStoreBase))
        // Same splash-port sync as `start` (spec §6.1): hot-reload routing
        // and the health probe must not resurrect the stored row's stale
        // 8123 when the port changed.
        let vendors = AppConfig.syncingSplashVendor(config.vendors, splashPort: config.splash?.port)
        localHealthMonitor?.configure(vendors: vendors)
        // Fix round 1: the direct degraded serve follows the live config —
        // an added or removed edge vendor takes effect without a restart.
        if let relayHealth {
            let edgeTarget = Self.fallbackEdgeRouteTarget(vendors: vendors)
            Task { await relayHealth.configureFallbackEdgeTarget(edgeTarget) }
        }
        for slot in listeners {
            guard let clientCfg = config.clients.first(where: { $0.clientName == slot.clientName }) else {
                continue
            }
            let newSnapshot = RoutingSnapshot(from: config, for: clientCfg, vendors: vendors)
            Task {
                await slot.router.updateSnapshot(newSnapshot)
            }
        }
    }
}

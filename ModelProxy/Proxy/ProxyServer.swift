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
            // re-runs per login attempt, so an external re-login that
            // rewrites the shared store is picked up by this RUNNING
            // process on the next chain rebuild.
            let storeBase = CredentialStore.resolveBase(config.credentialStoreBase)
            let signingClient = makeSigningClient?() ?? {
                var configuration = SigningClient.Configuration()
                configuration.storeLoader = { try CredentialStore.loadDefault(base: storeBase) }
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
            relayContext = RelayTarget.Context(
                signingClient: signingClient,
                credentialEvents: credentialEvents,
                quota: quotaService)
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

        // Local health probe (Task 7): registers BEFORE any RequestRouter is
        // built below — routers capture the provider at construction (Task 6
        // lifecycle note), so this is the one point where the splash probe
        // connects to the router's health conditions.
        if localHealthMonitor == nil {
            localHealthMonitor = LocalHealthMonitor()
        }
        localHealthMonitor?.configure(vendors: config.vendors)
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

        for clientCfg in config.clients {
            let snapshot = RoutingSnapshot(from: config, for: clientCfg)
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
                                localHealth: self.localHealthMonitor
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

    /// SF Symbol name for the menu bar icon. Adapts to light/dark via template rendering.
    /// States in priority order: not running → xmark.circle, partial error → exclamationmark.circle,
    /// normal → arrow.triangle.branch.
    var menuBarSymbol: String {
        guard isRunning else { return "xmark.circle" }
        if lastError != nil { return "exclamationmark.circle" }
        return "arrow.triangle.branch"
    }

    // MARK: - Hot Reload

    /// Push a new routing snapshot to all listeners that match by clientName.
    /// Called after ConfigStore.save(); does not restart any channel.
    func updateRouting(config: AppConfig) {
        self.webSearchProvider = WebSearchProviderFactory.make(from: config.webSearch)
        self.webSearchForwardAsIs = config.webSearch.provider == .forwardAsIs
        localHealthMonitor?.configure(vendors: config.vendors)
        for slot in listeners {
            guard let clientCfg = config.clients.first(where: { $0.clientName == slot.clientName }) else {
                continue
            }
            let newSnapshot = RoutingSnapshot(from: config, for: clientCfg)
            Task {
                await slot.router.updateSnapshot(newSnapshot)
            }
        }
    }
}

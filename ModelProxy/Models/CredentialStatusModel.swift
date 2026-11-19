import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - Face (login-flow UI item 1)

/// The credential status faces, derived from `SigningClient.statusSnapshot()`
/// plus `CredentialEvent`s. A PURE type: the state machine below is
/// exhaustively unit-testable without UI, and no face ever carries token
/// material (the `actionNeeded` reason is a display reason off typed errors,
/// never rendered into the chip text).
enum CredentialFace: Equatable, Sendable {
    /// Healthy plan token; nil minutes = unknown TTL (no plan token minted
    /// yet — show without countdown).
    case signedIn(minutesLeft: Int?)
    /// A keeper refresh is in flight (chain build now, or a retry sitting
    /// in its backoff window).
    case renewing
    /// The in-app login flow is polling the browser authorization.
    case awaitingAuthorization
    /// The ladder is dead: red, persistent — does NOT clear until a
    /// `.renewed` / `.authorizationComplete` arrives.
    case actionNeeded(reason: String)
    /// The most recent relayed request was served by the UNSIGNED fail-open
    /// path (works, but never mistaken for healthy — item 5).
    case degraded
    /// No relay-kind vendor configured (Settings-only face; the popover row
    /// hides itself instead).
    case off
    /// Before the first snapshot.
    case unknown

    var isActionNeeded: Bool {
        if case .actionNeeded = self { return true }
        return false
    }

    /// The face for a given observable state. Priority: off/unknown guards,
    /// then the in-app login (authorizing…), then a dead ladder (persistent
    /// red), then the location-less setup gap (live store, no project-key
    /// location — action-needed; no retry inside ZGate can fix it), then
    /// transient renewal (only when a rung can still build it —
    /// a futile retry falls through to the dead-ladder red), then the
    /// standing degraded flag, then signed-in views — session countdown
    /// first, store/cache without countdown second — and finally the derived
    /// dead states (expired store token / no ladder at all), which are
    /// action-needed even before any request has fired.
    static func face(
        relayConfigured: Bool,
        snapshot: SigningClient.StatusSnapshot?,
        events: [CredentialEvent],
        loginInFlight: Bool
    ) -> CredentialFace {
        guard relayConfigured else { return .off }
        guard let snapshot else { return .unknown }
        if loginInFlight { return .awaitingAuthorization }
        if let reason = lastUnrecoveredExpired(events) {
            return .actionNeeded(reason: reason)
        }
        // The fresh-install setup gap: a live store that lacks its
        // project-key location. buildChain fails at the noLocation guard
        // before any network call, so no retry inside ZGate can ever
        // succeed — renewal here was a forever-lie (the keeper kept
        // re-seating it at ≤5 min intervals). Action-needed until a
        // GUI/CLI login writes the location; the snapshot re-reads the
        // store on every recompute, so the face self-clears — no event,
        // no restart — the moment the location appears. Requires a LIVE
        // store token: an expired one keeps the expired-login red below
        // (the more fundamental problem), and a cache-only machine CAN
        // build (a usable cache bypasses the location lookup).
        if snapshot.storeLacksProjectLocation,
            let storeExpiresAtMs = snapshot.storeAccessTokenExpiresAtMs,
            storeExpiresAtMs > snapshot.nowMs
        {
            return .actionNeeded(reason: Self.locationMissingReason)
        }
        if snapshot.phase == .handshaking { return .renewing }
        if snapshot.servedUnsigned { return .degraded }
        if case let .refreshFailed(stage, _) = events.last,
            stage != ZaiLoginClient.missingLocationStage
        {
            // A refresh failure reads as renewal while the ladder can still
            // build (viable store/cache — buildChain rebuilds from those,
            // never from held-session material) OR was working in-process
            // recently (a held session, even expired: the failure is then
            // likely transient server/network trouble rather than missing
            // credentials). A ladder with neither — login-less or
            // unreadable store — can never build on retry and falls through
            // to the derived dead-ladder red below. The login's location
            // warning is excluded: while the location is missing, the
            // setup-gap branch above has already answered; once a GUI/CLI
            // login populated it the warning is stale (it cannot recur) —
            // neither state is renewal.
            if snapshot.sessionExpiresAtMs != nil || storeOrCacheViable(snapshot) {
                return .renewing
            }
        }
        if let expiresAtMs = snapshot.sessionExpiresAtMs {
            return .signedIn(
                minutesLeft: max(0, Int((expiresAtMs - snapshot.nowMs) / 60_000)))
        }
        if storeOrCacheViable(snapshot) { return .signedIn(minutesLeft: nil) }
        if let storeExpiresAtMs = snapshot.storeAccessTokenExpiresAtMs,
            storeExpiresAtMs <= snapshot.nowMs
        {
            return .actionNeeded(reason: "stored login expired")
        }
        return .actionNeeded(reason: "no stored login")
    }

    /// The reason of the most recent `.expired` NOT yet followed by a
    /// recovery event (`.renewed` / `.authorizationComplete`); nil when the
    /// ladder is not dead. Every other event kind (`.refreshFailed`,
    /// `.awaitingAuthorization`, …) leaves a pending expiry standing —
    /// `actionNeeded` is persistent by design.
    private static func lastUnrecoveredExpired(_ events: [CredentialEvent]) -> String? {
        var reason: String?
        for event in events {
            switch event {
            case let .expired(found): reason = found
            case .renewed, .authorizationComplete: reason = nil
            default: break
            }
        }
        return reason
    }

    /// Derived reason when the store is live but location-less: the
    /// ladder can never mint until a GUI/CLI login populates the
    /// project-key location — retrying inside ZGate cannot fix it, so
    /// the face reads action-needed, not renewal.
    static let locationMissingReason = "project location missing"

    /// BizSessionCache's usable window (180 d TTL − 5 d margin) — a cache
    /// inside it can still build a chain on demand, so the face may claim
    /// signed-in (without countdown) even before the first mint.
    private static let cacheUsableWindowMs: Int64 = (15_552_000 - 432_000) * 1000

    /// A ladder that can build on demand: a live store access token, or a
    /// biz-session cache inside its usable window.
    private static func storeOrCacheViable(_ snapshot: SigningClient.StatusSnapshot) -> Bool {
        if let storeExpiresAtMs = snapshot.storeAccessTokenExpiresAtMs,
            storeExpiresAtMs > snapshot.nowMs
        {
            return true
        }
        if let cacheAcquiredAtMs = snapshot.cacheAcquiredAtMs {
            return snapshot.nowMs < cacheAcquiredAtMs + cacheUsableWindowMs
        }
        return false
    }
}

// MARK: - Chip (popover row, the splash chip's visual weight)

struct CredentialChipFace: Equatable, Sendable {
    let text: String
    let color: Color
}

extension CredentialFace {

    /// The popover/Settings rendering pin. The `actionNeeded` reason is
    /// deliberately NOT in the text — reasons flow to the alert and the
    /// Advanced raw log only, so no face string can ever carry credential
    /// material (the no-leak test asserts this for every face).
    var chip: CredentialChipFace {
        switch self {
        case let .signedIn(minutesLeft):
            return .init(
                text: minutesLeft.map { "● signed in · \($0) min left" } ?? "● signed in",
                color: .green)
        case .renewing:
            return .init(text: "● renewing", color: .orange)
        case .awaitingAuthorization:
            return .init(text: "● authorizing…", color: .orange)
        case let .actionNeeded(reason):
            // First-run copy: a machine that never stored a login reads
            // wrong as "expired"; the setup gap reads wrong as both. Only
            // the fixed derived literals are special-cased; every other
            // reason keeps the expired wording (no reason text is ever
            // rendered — the no-leak invariant).
            let text: String
            if reason == "no stored login" {
                text = "● sign in to use the relay"
            } else if reason == Self.locationMissingReason {
                // The login succeeded; the missing piece (the project-key
                // location) is one GUI/CLI login away — not "expired".
                text = "● finish setup in ZCode, then Reload"
            } else {
                text = "● login expired — sign in"
            }
            return .init(text: text, color: .red)
        case .degraded:
            return .init(text: "● degraded (unsigned)", color: .orange)
        case .off:
            return .init(text: "● off", color: .gray)
        case .unknown:
            return .init(text: "◐ checking…", color: .gray)
        }
    }
}

extension ZaiLoginOutcome {

    /// Fixed retry copy for the status row after a terminal login outcome;
    /// the model's typed client statuses (service unreachable, keychain
    /// access denied) get their own line. Only these strings render — the
    /// payload (server status / duration) never reaches the UI.
    var retryText: String? {
        switch self {
        case .ready: return nil
        case let .failed(status):
            switch status {
            case "service unreachable": return "Sign-in service unreachable — retry"
            case "flow expired": return "Sign-in window expired — retry"
            case "keychain access denied": return "Keychain access denied — retry"
            case "keychain unavailable": return "Keychain unavailable — retry"
            default: return "Login failed — retry"
            }
        case .timedOut: return "Login timed out — retry"
        }
    }
}

// MARK: - Login flow seam

/// The model's view of `ZaiLoginClient` — tests drive a stub; production
/// builds the real client (browser OAuth init → poll) with the event hook.
protocol LoginFlowDriving: Sendable {
    func begin() async throws
    func authorizeURL() async -> URL?
    func pollUntilTerminal() async throws -> ZaiLoginOutcome
}

extension ZaiLoginClient: LoginFlowDriving {}

/// Default flow when no client factory is wired (tests, previews): refuses
/// to start — the in-app login is only real behind `CredentialStatusModel.live`.
private struct UnavailableLoginFlow: LoginFlowDriving {
    func begin() async throws { throw ZaiLoginError.notStarted }
    func authorizeURL() async -> URL? { nil }
    func pollUntilTerminal() async throws -> ZaiLoginOutcome { throw ZaiLoginError.notStarted }
}

// MARK: - Model

/// Bridges the signing seams to SwiftUI (login-flow UI item 1): derives
/// `CredentialFace` from `SigningClient.statusSnapshot()` on a slow cadence
/// plus every observable nudge (popover appear/tick, credential events) and
/// runs the in-app login flow (item 3) — `ZaiLoginClient` begin → open the
/// authorize URL in the browser → poll; on ready the core persists the
/// store, then the model drops the session so the face flips to signed in
/// WITHOUT an app restart. Never renders or stores credential material: the
/// `ready` outcome is consumed, not kept.
@MainActor
@Observable
final class CredentialStatusModel {

    /// Re-read the seams this often while running (matches the popover's
    /// slow tick; minute-level countdowns and the menu-bar badge stay fresh
    /// while the popover is closed).
    static let refreshTick: TimeInterval = 20

    struct Environment {
        var relayConfigured: () -> Bool = { false }
        var events: () -> [CredentialEvent] = { [] }
        /// Where the login client's lifecycle events land (the shared
        /// credential channel in production — the same list `events` reads,
        /// so emitted events feed back into the next face derivation).
        var emitEvent: (CredentialEvent) -> Void = { _ in }
        var snapshot: () async -> SigningClient.StatusSnapshot? = { nil }
        var dropSession: () async -> Void = {}
        var openURL: (URL) -> Void = { _ in }
        var storeBase: () -> URL? = { nil }
        var makeLoginClient:
            (URL?, @escaping @Sendable (CredentialEvent) -> Void) -> any LoginFlowDriving =
            { _, _ in UnavailableLoginFlow() }
        /// Face-change tap for surfaces outside the observing views (the
        /// menu-bar badge writes `ProxyServer.credentialActionNeeded`).
        var onFaceChange: ((CredentialFace) -> Void)?
    }

    private let environment: Environment
    @ObservationIgnored private var lastSnapshot: SigningClient.StatusSnapshot?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private(set) var loginTask: Task<Void, Never>?

    private(set) var face: CredentialFace = .unknown
    private(set) var loginInFlight = false
    /// The last TERMINAL login outcome (failed / timed out) for the retry
    /// copy; nil after success or cancel. Never holds a `ready` payload.
    private(set) var lastLoginOutcome: ZaiLoginOutcome?

    init(environment: Environment = Environment()) {
        self.environment = environment
    }

    /// Model over the app's seams: the snapshot/drop calls ride the proxy's
    /// relay signing context (nil until the first relay-configured start —
    /// the `unknown` face), events mirror the shared channel the login
    /// client also emits into, and the login client persists through the
    /// Settings-selected store base.
    static func live(server: ProxyServer, configStore: ConfigStore) -> CredentialStatusModel {
        let events = server.credentialEvents
        return CredentialStatusModel(environment: .init(
            relayConfigured: {
                configStore.config.vendors.contains { $0.vendorKind == .relay }
            },
            events: { events.events },
            snapshot: { await server.relayContext?.signingClient.statusSnapshot() },
            dropSession: { await server.relayContext?.signingClient.dropSession() },
            openURL: { url in NSWorkspace.shared.open(url) },
            storeBase: {
                CredentialStore.resolveBase(configStore.config.credentialStoreBase)
            },
            makeLoginClient: { base, onEvent in
                var configuration = ZaiLoginClient.Configuration()
                configuration.storeBase = base
                configuration.onEvent = onEvent
                return ZaiLoginClient(configuration: configuration)
            },
            onFaceChange: { server.credentialActionNeeded = $0.isActionNeeded }))
    }

    /// Starts the background re-read tick (menu-bar badge freshness while
    /// the popover is closed). Idempotent; the loop holds the model weakly.
    func start() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.recompute()
                try? await Task.sleep(for: .seconds(Self.refreshTick))
            }
        }
    }

    /// Re-read the seams (nudged by appear/tick/credential events).
    func recompute() async {
        lastSnapshot = await environment.snapshot()
        deriveFace()
    }

    private func deriveFace() {
        face = CredentialFace.face(
            relayConfigured: environment.relayConfigured(),
            snapshot: lastSnapshot,
            events: environment.events(),
            loginInFlight: loginInFlight)
        environment.onFaceChange?(face)
    }

    // MARK: - In-app login (item 3)

    /// Runs the browser OAuth flow: begin → open the authorize URL → poll.
    /// On `ready` the client has already persisted through the store's
    /// envelope write path; the session drop that follows makes the next
    /// request rebuild on the fresh store — signed in, no restart. Failed /
    /// timed-out flows keep the previous (typically `actionNeeded`) face
    /// and surface fixed retry copy.
    func startSignIn() {
        guard !loginInFlight else { return }
        loginInFlight = true
        lastLoginOutcome = nil
        deriveFace()

        let environment = self.environment
        let base = environment.storeBase()
        // The client emits from its own executor; hop each event to main.
        let hook: @Sendable (CredentialEvent) -> Void = { [weak self] event in
            Task { @MainActor in self?.handleLoginEvent(event) }
        }
        loginTask = Task { [weak self] in
            var outcome: ZaiLoginOutcome?
            do {
                let client = environment.makeLoginClient(base, hook)
                try await client.begin()
                if let url = await client.authorizeURL() {
                    environment.openURL(url)
                }
                outcome = try await client.pollUntilTerminal()
            } catch is CancellationError {
                // User cancel: silently return to the previous face.
            } catch let error as ZaiLoginError {
                if case .http = error {
                    outcome = .failed(status: "service unreachable")
                } else {
                    outcome = .failed(status: "client error")
                }
            } catch let error as CredentialWriteError where error == .keychainAccessDenied {
                outcome = .failed(status: "keychain access denied")
            } catch let error as CredentialWriteError where error == .keychainUnavailable {
                outcome = .failed(status: "keychain unavailable")
            } catch {
                outcome = .failed(status: "client error")
            }
            await self?.finishLogin(outcome: outcome)
        }
    }

    /// Aborts the in-flight login cleanly (the poll loop's sleep throws on
    /// cancellation); the face falls back to the standing state.
    func cancelSignIn() {
        loginTask?.cancel()
    }

    private func handleLoginEvent(_ event: CredentialEvent) {
        environment.emitEvent(event)
    }

    private func finishLogin(outcome: ZaiLoginOutcome?) async {
        switch outcome {
        case .ready:
            // Credentials persisted by the client; hot-pickup the new store.
            // The outcome value itself is dropped — it carries credential
            // material and must not live in observable state.
            lastLoginOutcome = nil
            await environment.dropSession()
        case nil:
            break
        case let terminal:
            // failed / timedOut: payloads are status strings / durations
            // only, and retryText is the only thing that ever renders.
            lastLoginOutcome = terminal
        }
        loginInFlight = false
        // The client emits its terminal events (notably
        // `.authorizationComplete`) through a main-actor hop that is
        // already enqueued by now; yield once so they land in the channel
        // BEFORE the face derivation reads it — a recovery that recomputes
        // before its own event would flap back to `actionNeeded`.
        await Task.yield()
        await recompute()
    }

    // MARK: - Reload (item 4)

    /// "Reload credentials": drop the session so the next request rebuilds
    /// through the fresh store loader — recovers after an external
    /// GUI/CLI login without a restart.
    func reloadCredentials() async {
        await environment.dropSession()
        await recompute()
    }
}

// MARK: - Settings store selector (item 4)

/// The General-tab credential store selector as a pure mapping onto the
/// persisted `credentialStoreBase` setting: nil = the GUI/CLI shared
/// default (`~/.zcode`), the literal scratch spelling selects the legacy
/// `~/.zcode-scratch-v3`, anything else is a custom absolute path.
enum CredentialStoreSelection: Equatable, Sendable {
    case sharedWithGUI
    case legacyScratch
    case custom(path: String)

    /// The literal the scratch option persists (tilde-stable across home
    /// changes; `CredentialStore.resolveBase` tilde-expands it).
    static let legacyScratchSetting = "~/.zcode-scratch-v3"

    static func selection(for setting: String?) -> CredentialStoreSelection {
        guard let setting else { return .sharedWithGUI }
        if setting.isEmpty { return .custom(path: "") }  // explicit Custom, path not yet typed
        if setting == legacyScratchSetting || setting == CredentialStore.legacyScratchHome.path {
            return .legacyScratch
        }
        return .custom(path: setting)
    }

    var setting: String? {
        switch self {
        case .sharedWithGUI: return nil
        case .legacyScratch: return Self.legacyScratchSetting
        case let .custom(path): return path
        }
    }
}

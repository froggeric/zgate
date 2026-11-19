import Foundation
import SwiftUI
import Testing
@testable import ZGate

/// Login-flow UI wave, item 1–5: the credential status model — pure face
/// state machine over (relayConfigured, snapshot, events), chip rendering
/// pins (the `lifecycleChipFaces` pattern), the in-app login controller
/// over a stubbed flow driver, the Settings store-selector mapping, the
/// fail-open visibility snapshot flag, and the menu-bar badge / alert copy
/// pins. Synthetic fixtures only; no token material is ever rendered (the
/// no-leak assertions below are task-failing).
@Suite
struct CredentialStatusModelTests {

    // MARK: - Fixtures

    private static let nowMs: Int64 = 1_700_000_000_000

    private func snapshot(
        phase: SigningClient.Phase = .signed,
        nowMs explicitNowMs: Int64? = nil,
        sessionExpiresAtMs: Int64? = nil,
        sessionMarginRelaxed: Bool = false,
        storeAccessTokenExpiresAtMs: Int64? = nil,
        storeLacksProjectLocation: Bool = false,
        cacheAcquiredAtMs: Int64? = nil,
        servedUnsigned: Bool = false
    ) -> SigningClient.StatusSnapshot {
        let nowMs = explicitNowMs ?? Self.nowMs
        return SigningClient.StatusSnapshot(
            phase: phase,
            nowMs: nowMs,
            sessionExpiresAtMs: sessionExpiresAtMs,
            sessionMarginRelaxed: sessionMarginRelaxed,
            storeAccessTokenExpiresAtMs: storeAccessTokenExpiresAtMs,
            storeLacksProjectLocation: storeLacksProjectLocation,
            cacheAcquiredAtMs: cacheAcquiredAtMs,
            servedUnsigned: servedUnsigned)
    }

    private static func minutes(_ value: Int) -> Int64 {
        Int64(value) * 60_000
    }

    /// A reason string deliberately shaped like credential material — no
    /// rendered face string may ever carry any of it.
    private static let hostileReason =
        "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJmYWtlIn0.fakeSig.enc:v2:env:fingerprint.iv.tag.ct"

    // MARK: - Machine: off / unknown

    @Test("off face: no relay-kind vendor configured wins over everything")
    func faceIsOffWithoutRelayVendor() {
        #expect(
            CredentialFace.face(
                relayConfigured: false,
                snapshot: snapshot(sessionExpiresAtMs: Self.nowMs + Self.minutes(41)),
                events: [.expired(reason: "token expired")],
                loginInFlight: false)
            == .off)
    }

    @Test("unknown face: before the first snapshot")
    func faceIsUnknownBeforeFirstSnapshot() {
        #expect(
            CredentialFace.face(
                relayConfigured: true, snapshot: nil, events: [], loginInFlight: false)
            == .unknown)
    }

    // MARK: - Machine: signedIn

    @Test("healthy session shows whole minutes left (41.5 min → 41)")
    func healthySessionShowsMinutesLeft() {
        let face = CredentialFace.face(
            relayConfigured: true,
            snapshot: snapshot(sessionExpiresAtMs: Self.nowMs + Self.minutes(41) + 30_000),
            events: [],
            loginInFlight: false)
        #expect(face == .signedIn(minutesLeft: 41))

        // A margin-relaxed session rides its short window — same countdown.
        let relaxed = CredentialFace.face(
            relayConfigured: true,
            snapshot: snapshot(
                sessionExpiresAtMs: Self.nowMs + Self.minutes(2),
                sessionMarginRelaxed: true),
            events: [],
            loginInFlight: false)
        #expect(relaxed == .signedIn(minutesLeft: 2))
    }

    @Test("a session inside its last partial minute clamps at 0, never negative")
    func expiredSessionClampsAtZeroMinutes() {
        let face = CredentialFace.face(
            relayConfigured: true,
            snapshot: snapshot(sessionExpiresAtMs: Self.nowMs - 90_000),
            events: [],
            loginInFlight: false)
        #expect(face == .signedIn(minutesLeft: 0))
    }

    @Test("no plan token yet: a live store token or usable cache is signed in without countdown")
    func signedInWithoutCountdownWhenOnlyStoreOrCache() {
        // Live store token, never minted — TTL unknown until the first mint.
        let storeFace = CredentialFace.face(
            relayConfigured: true,
            snapshot: snapshot(
                phase: .unsigned, sessionExpiresAtMs: nil,
                storeAccessTokenExpiresAtMs: Self.nowMs + Self.minutes(30)),
            events: [],
            loginInFlight: false)
        #expect(storeFace == .signedIn(minutesLeft: nil))

        // No store, but a biz-session cache inside its usable window.
        let cacheFace = CredentialFace.face(
            relayConfigured: true,
            snapshot: snapshot(
                phase: .unsigned, sessionExpiresAtMs: nil,
                storeAccessTokenExpiresAtMs: nil,
                cacheAcquiredAtMs: Self.nowMs - Self.minutes(90)),
            events: [],
            loginInFlight: false)
        #expect(cacheFace == .signedIn(minutesLeft: nil))
    }

    // MARK: - Machine: renewing

    @Test("a chain build in flight shows renewing")
    func handshakingShowsRenewing() {
        let face = CredentialFace.face(
            relayConfigured: true,
            snapshot: snapshot(phase: .handshaking, sessionExpiresAtMs: Self.nowMs - 1),
            events: [],
            loginInFlight: false)
        #expect(face == .renewing)
    }

    @Test("the most recent refresh failure keeps renewing (backoff retry pending)")
    func pendingRefreshRetryShowsRenewing() {
        let face = CredentialFace.face(
            relayConfigured: true,
            snapshot: snapshot(sessionExpiresAtMs: Self.nowMs - 1),
            events: [
                .renewed(expiresAtMs: Self.nowMs),
                .refreshFailed(stage: "mint", reason: "HTTP 503"),
            ],
            loginInFlight: false)
        #expect(face == .renewing)
    }

    @Test("a refresh failure over a usable cache still reads renewing (cache can build)")
    func refreshFailureOverUsableCacheShowsRenewing() {
        let face = CredentialFace.face(
            relayConfigured: true,
            snapshot: snapshot(
                phase: .unsigned, sessionExpiresAtMs: nil,
                cacheAcquiredAtMs: Self.nowMs - Self.minutes(1)),
            events: [.refreshFailed(stage: "mint", reason: "HTTP 503")],
            loginInFlight: false)
        #expect(face == .renewing)
    }

    // MARK: - Machine: futile retries cannot mask the dead-ladder red

    @Test("a refresh failure cannot mask a login-less dead ladder (retry can never build)")
    func refreshFailureDoesNotMaskLoginlessDeadLadder() {
        // The keeper retries every ≤5 min and its .refreshFailed events used
        // to seat the face on "renewing" forever, unseating the red Sign In.
        let face = CredentialFace.face(
            relayConfigured: true,
            snapshot: snapshot(phase: .unsigned, sessionExpiresAtMs: nil),
            events: [.refreshFailed(stage: "zLogin", reason: "no location")],
            loginInFlight: false)
        #expect(face == .actionNeeded(reason: "no stored login"))
    }

    @Test("a refresh failure cannot mask an expired stored login")
    func refreshFailureDoesNotMaskExpiredStore() {
        let face = CredentialFace.face(
            relayConfigured: true,
            snapshot: snapshot(
                phase: .unsigned, sessionExpiresAtMs: nil,
                storeAccessTokenExpiresAtMs: Self.nowMs - 1),
            events: [.refreshFailed(stage: "zLogin", reason: "HTTP 401")],
            loginInFlight: false)
        #expect(face == .actionNeeded(reason: "stored login expired"))
    }

    // MARK: - Machine: location-less store (fresh-install setup gap)

    @Test("a live location-less store reads setup action-needed, not renewing")
    func locationlessLiveStoreIsSetupActionNotRenewing() {
        // The fresh-install post-login state: the in-app login wrote a
        // live store WITHOUT a project-key location (only a GUI/CLI
        // login populates it) and its trailing location warning is the
        // last event. buildChain fails before any network call while the
        // location is missing, so renewal can never succeed — "renewing"
        // here was a forever-lie (the keeper kept failing at ≤5 min
        // intervals, re-seating the same face).
        let face = CredentialFace.face(
            relayConfigured: true,
            snapshot: snapshot(
                phase: .unsigned, sessionExpiresAtMs: nil,
                storeAccessTokenExpiresAtMs: Self.nowMs + Self.minutes(30),
                storeLacksProjectLocation: true),
            events: [
                .awaitingAuthorization,
                .authorizationComplete,
                .refreshFailed(
                    stage: ZaiLoginClient.missingLocationStage,
                    reason: ZaiLoginClient.missingLocationReason),
            ],
            loginInFlight: false)
        #expect(face == .actionNeeded(reason: CredentialFace.locationMissingReason))
    }

    @Test("restart flavor: no events at all, still setup action-needed (not signed in)")
    func locationlessLiveStoreWithoutEventsIsSetupAction() {
        // Events are in-memory; after a restart on the fresh machine the
        // same snapshot must still derive the setup gap — previously it
        // read green "signed in" until the first keeper failure event.
        let face = CredentialFace.face(
            relayConfigured: true,
            snapshot: snapshot(
                phase: .unsigned, sessionExpiresAtMs: nil,
                storeAccessTokenExpiresAtMs: Self.nowMs + Self.minutes(30),
                storeLacksProjectLocation: true),
            events: [],
            loginInFlight: false)
        #expect(face == .actionNeeded(reason: CredentialFace.locationMissingReason))
    }

    @Test("a stale location warning over a store that since gained its location reads signed in")
    func staleLocationWarningReadsSignedIn() {
        // After the user completes one GUI/CLI login (populating the
        // location in the same store), the login's trailing location
        // warning is stale — it cannot recur — so it must not seat
        // "renewing" until the keeper's next .renewed.
        let face = CredentialFace.face(
            relayConfigured: true,
            snapshot: snapshot(
                phase: .unsigned, sessionExpiresAtMs: nil,
                storeAccessTokenExpiresAtMs: Self.nowMs + Self.minutes(30)),
            events: [
                .authorizationComplete,
                .refreshFailed(
                    stage: ZaiLoginClient.missingLocationStage,
                    reason: ZaiLoginClient.missingLocationReason),
            ],
            loginInFlight: false)
        #expect(face == .signedIn(minutesLeft: nil))
    }

    @Test("an expired location-less store stays on the expired-login red")
    func expiredLocationlessStoreStillReadsExpired() {
        // The expired token is the more fundamental problem — sign in
        // again — and remains the derived face.
        let face = CredentialFace.face(
            relayConfigured: true,
            snapshot: snapshot(
                phase: .unsigned, sessionExpiresAtMs: nil,
                storeAccessTokenExpiresAtMs: Self.nowMs - 1,
                storeLacksProjectLocation: true),
            events: [.refreshFailed(stage: "chain", reason: "no location")],
            loginInFlight: false)
        #expect(face == .actionNeeded(reason: "stored login expired"))
    }

    // MARK: - Machine: awaitingAuthorization

    @Test("an in-flight in-app login shows authorizing — even over an unrecovered expiry")
    func loginInFlightShowsAwaitingAuthorization() {
        let face = CredentialFace.face(
            relayConfigured: true,
            snapshot: snapshot(sessionExpiresAtMs: Self.nowMs + Self.minutes(41)),
            events: [.expired(reason: "token expired")],
            loginInFlight: true)
        #expect(face == .awaitingAuthorization)
    }

    // MARK: - Machine: actionNeeded persistence

    @Test("expired is actionNeeded and persists until renewed/authorizationComplete")
    func expiredEventIsActionNeededAndPersistsUntilRecovery() {
        let healthy = snapshot(sessionExpiresAtMs: Self.nowMs + Self.minutes(41))
        var events: [CredentialEvent] = [.expired(reason: "token expired")]

        #expect(
            CredentialFace.face(
                relayConfigured: true, snapshot: healthy, events: events, loginInFlight: false)
            == .actionNeeded(reason: "token expired"))

        // Non-recovery events do NOT clear it.
        events.append(.refreshFailed(stage: "mint", reason: "HTTP 500"))
        events.append(.awaitingAuthorization)
        #expect(
            CredentialFace.face(
                relayConfigured: true, snapshot: healthy, events: events, loginInFlight: false)
            == .actionNeeded(reason: "token expired"))

        // A keeper renewal recovers it.
        events.append(.renewed(expiresAtMs: Self.nowMs + Self.minutes(50)))
        #expect(
            CredentialFace.face(
                relayConfigured: true, snapshot: healthy, events: events, loginInFlight: false)
            == .signedIn(minutesLeft: 41))

        // A later expiry re-arms it, and the in-app completion recovers it.
        events.append(.expired(reason: "relay 401 after chain rebuild"))
        #expect(
            CredentialFace.face(
                relayConfigured: true, snapshot: healthy, events: events, loginInFlight: false)
            == .actionNeeded(reason: "relay 401 after chain rebuild"))
        events.append(.authorizationComplete)
        #expect(
            CredentialFace.face(
                relayConfigured: true, snapshot: healthy, events: events, loginInFlight: false)
            == .signedIn(minutesLeft: 41))
    }

    // MARK: - Machine: degraded (fail-open visibility, item 5)

    @Test("an unsigned fail-open serve shows degraded until the next signed success")
    func unsignedServeShowsDegradedAndClearsOnSignedSuccess() {
        let healthy = snapshot(sessionExpiresAtMs: Self.nowMs + Self.minutes(41))

        // Set: beats a healthy session and a pending retry alike.
        #expect(
            CredentialFace.face(
                relayConfigured: true,
                snapshot: snapshot(
                    sessionExpiresAtMs: Self.nowMs + Self.minutes(41), servedUnsigned: true),
                events: [],
                loginInFlight: false)
            == .degraded)
        #expect(
            CredentialFace.face(
                relayConfigured: true,
                snapshot: snapshot(
                    sessionExpiresAtMs: Self.nowMs + Self.minutes(41), servedUnsigned: true),
                events: [.refreshFailed(stage: "mint", reason: "HTTP 500")],
                loginInFlight: false)
            == .degraded)

        // ...but never masks a dead ladder.
        #expect(
            CredentialFace.face(
                relayConfigured: true,
                snapshot: snapshot(
                    sessionExpiresAtMs: Self.nowMs + Self.minutes(41), servedUnsigned: true),
                events: [.expired(reason: "token expired")],
                loginInFlight: false)
            == .actionNeeded(reason: "token expired"))

        // Clear: the flag died with the next signed success (healthy again).
        #expect(
            CredentialFace.face(
                relayConfigured: true, snapshot: healthy, events: [], loginInFlight: false)
            == .signedIn(minutesLeft: 41))
    }

    @Test("a dead store token or no ladder at all is actionNeeded, never 'ok'")
    func deadOrMissingStoreIsActionNeeded() {
        // Store token exp in the past, no session — the ladder is dead on
        // arrival even though no request has fired yet.
        let expiredStore = CredentialFace.face(
            relayConfigured: true,
            snapshot: snapshot(
                phase: .unsigned, sessionExpiresAtMs: nil,
                storeAccessTokenExpiresAtMs: Self.nowMs - 1),
            events: [],
            loginInFlight: false)
        guard case .actionNeeded = expiredStore else {
            Issue.record("expected actionNeeded, got \(expiredStore)")
            return
        }

        // Nothing at all: no session, no store token, no cache.
        let nothing = CredentialFace.face(
            relayConfigured: true,
            snapshot: snapshot(phase: .unsigned, sessionExpiresAtMs: nil),
            events: [],
            loginInFlight: false)
        guard case .actionNeeded = nothing else {
            Issue.record("expected actionNeeded, got \(nothing)")
            return
        }

        // A cache past its usable window does not rescue it either.
        let staleCache = CredentialFace.face(
            relayConfigured: true,
            snapshot: snapshot(
                phase: .unsigned, sessionExpiresAtMs: nil,
                cacheAcquiredAtMs: Self.nowMs - 200 * 24 * 3600 * 1000),
            events: [],
            loginInFlight: false)
        guard case .actionNeeded = staleCache else {
            Issue.record("expected actionNeeded, got \(staleCache)")
            return
        }
    }

    // MARK: - No-leak (task-failing)

    @Test("no rendered face string carries eyJ or enc:v2 substrings")
    func noRenderedFaceStringCarriesCredentialMaterial() {
        let faces: [CredentialFace] = [
            .signedIn(minutesLeft: 41),
            .signedIn(minutesLeft: nil),
            .signedIn(minutesLeft: 0),
            .renewing,
            .awaitingAuthorization,
            .actionNeeded(reason: Self.hostileReason),
            .actionNeeded(reason: CredentialFace.locationMissingReason),
            .degraded,
            .off,
            .unknown,
        ]
        for face in faces {
            let chip = face.chip
            #expect(!chip.text.contains("eyJ"), "leak in \(chip.text)")
            #expect(!chip.text.contains("enc:v2"), "leak in \(chip.text)")
        }
        // The hostile reason must also survive the full machine path
        // without reaching the rendered string.
        let machineFace = CredentialFace.face(
            relayConfigured: true,
            snapshot: snapshot(sessionExpiresAtMs: Self.nowMs + Self.minutes(41)),
            events: [.expired(reason: Self.hostileReason)],
            loginInFlight: false)
        #expect(machineFace.chip.text == "● login expired — sign in")
        #expect(!machineFace.chip.text.contains("eyJ"))
        #expect(!machineFace.chip.text.contains("enc:v2"))

        // Retry copy is fixed strings only — the outcome payload never renders.
        let outcomes: [ZaiLoginOutcome] = [
            .failed(status: Self.hostileReason),
            .timedOut(afterMs: 300_000),
        ]
        for outcome in outcomes {
            let text = outcome.retryText ?? ""
            #expect(!text.contains("eyJ"))
            #expect(!text.contains("enc:v2"))
        }
    }

    // MARK: - Chip pins (popover row, lifecycleChipFaces pattern)

    @Test("chip faces: exact text and color per face")
    func chipFacesPinExactTextAndColor() {
        #expect(
            CredentialFace.signedIn(minutesLeft: 41).chip
            == .init(text: "● signed in · 41 min left", color: .green))
        #expect(
            CredentialFace.signedIn(minutesLeft: nil).chip
            == .init(text: "● signed in", color: .green))
        #expect(CredentialFace.renewing.chip == .init(text: "● renewing", color: .orange))
        #expect(
            CredentialFace.awaitingAuthorization.chip
            == .init(text: "● authorizing…", color: .orange))
        #expect(
            CredentialFace.actionNeeded(reason: "anything").chip
            == .init(text: "● login expired — sign in", color: .red))
        // First-run copy: never-logged-in is not "expired".
        #expect(
            CredentialFace.actionNeeded(reason: "no stored login").chip
            == .init(text: "● sign in to use the relay", color: .red))
        // Setup-gap copy: login succeeded; the missing piece is one
        // GUI/CLI login away — not "expired".
        #expect(
            CredentialFace.actionNeeded(reason: CredentialFace.locationMissingReason).chip
            == .init(text: "● finish setup in ZCode, then Reload", color: .red))
        #expect(CredentialFace.degraded.chip == .init(text: "● degraded (unsigned)", color: .orange))
        #expect(CredentialFace.off.chip == .init(text: "● off", color: .gray))
        #expect(CredentialFace.unknown.chip == .init(text: "◐ checking…", color: .gray))
    }

    @Test("login outcome retry copy is fixed text; ready carries none")
    func loginOutcomeRetryCopyIsFixed() {
        #expect(ZaiLoginOutcome.failed(status: "auth_failed").retryText == "Login failed — retry")
        #expect(
            ZaiLoginOutcome.failed(status: "service unreachable").retryText
                == "Sign-in service unreachable — retry")
        #expect(
            ZaiLoginOutcome.failed(status: "flow expired").retryText
                == "Sign-in window expired — retry")
        #expect(
            ZaiLoginOutcome.failed(status: "keychain access denied").retryText
                == "Keychain access denied — retry")
        #expect(
            ZaiLoginOutcome.failed(status: "keychain unavailable").retryText
                == "Keychain unavailable — retry")
        #expect(
            ZaiLoginOutcome.timedOut(afterMs: 300_000).retryText == "Login timed out — retry")
        let ready = ZaiLoginOutcome.ready(
            ZaiLoginCredentials(accessToken: "synthetic", zcodeJwtToken: "synthetic", userInfoJSON: "{}"))
        #expect(ready.retryText == nil)
    }

    // MARK: - Fail-open snapshot flag (item 5, actor-level)

    @Test("the served-unsigned flag sets on a fail-open serve and clears on a signed success")
    func unsignedServeFlagSetsAndClearsThroughActor() async throws {
        let client = SigningClient(configuration: SigningClient.Configuration())
        await client.noteRelaySuccess(signed: false)
        var snapshot = await client.statusSnapshot()
        #expect(snapshot.servedUnsigned == true)

        await client.noteRelaySuccess()  // the default is a signed success
        snapshot = await client.statusSnapshot()
        #expect(snapshot.servedUnsigned == false)
    }

    // MARK: - Model controller (stubbed flow driver)

    private final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        private var _openedURLs: [URL] = []
        private var _droppedSession = 0
        private var _emitted: [CredentialEvent]
        private var _storeBases: [URL?] = []

        init(seeded: [CredentialEvent] = []) {
            _emitted = seeded
        }

        var openedURLs: [URL] { lock.withLock { _openedURLs } }
        var droppedSession: Int { lock.withLock { _droppedSession } }
        var emitted: [CredentialEvent] { lock.withLock { _emitted } }
        var storeBases: [URL?] { lock.withLock { _storeBases } }

        func opened(_ url: URL) { lock.withLock { _openedURLs.append(url) } }
        func dropped() { lock.withLock { _droppedSession += 1 } }
        func emit(_ event: CredentialEvent) { lock.withLock { _emitted.append(event) } }
        func storeBase(_ base: URL?) { lock.withLock { _storeBases.append(base) } }
    }

    /// Stub over the login seam: records begin/open/poll and calls the
    /// model's event hook exactly where the real client would (init →
    /// awaiting; ready → complete, from inside the poll).
    private final class StubLoginFlow: LoginFlowDriving, @unchecked Sendable {
        let lock = NSLock()
        private var _hook: (@Sendable (CredentialEvent) -> Void)?
        private var _began = false
        private var _pollCancelled = false
        private var pollContinuation: CheckedContinuation<ZaiLoginOutcome, Error>?
        var url = URL(string: "https://auth.example/synthetic-authorize")!
        var pollResult: ZaiLoginOutcome?

        var began: Bool { lock.withLock { _began } }
        var pollCancelled: Bool { lock.withLock { _pollCancelled } }

        func setHook(_ hook: @escaping @Sendable (CredentialEvent) -> Void) {
            lock.withLock { _hook = hook }
        }

        func begin() async throws {
            lock.withLock { _began = true }
            lock.withLock { _hook }?(.awaitingAuthorization)
        }

        func authorizeURL() async -> URL? { url }

        func pollUntilTerminal() async throws -> ZaiLoginOutcome {
            if let pollResult {
                // The real client emits complete after persisting, before
                // returning the ready outcome.
                if case .ready = pollResult {
                    lock.withLock { _hook }?(.authorizationComplete)
                }
                return pollResult
            }
            // No scripted result: park until cancelled (the cancel test).
            // Cancel-before-park safe: `cancelSignIn` can land before this
            // task even starts, in which case onCancel has already run and
            // a parked continuation would never be resumed (the WakeLatch
            // race class) — the body therefore checks the flag before
            // parking and fails fast instead.
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ZaiLoginOutcome, Error>) in
                    let shouldPark: Bool = lock.withLock {
                        if _pollCancelled { return false }
                        pollContinuation = continuation
                        return true
                    }
                    if !shouldPark { continuation.resume(throwing: CancellationError()) }
                }
            } onCancel: {
                let continuation: CheckedContinuation<ZaiLoginOutcome, Error>? = lock.withLock {
                    _pollCancelled = true
                    let pending = pollContinuation
                    pollContinuation = nil
                    return pending
                }
                continuation?.resume(throwing: CancellationError())
            }
            throw CancellationError()  // unreachable; keeps the type checker honest
        }
    }

    @MainActor
    private func makeModel(
        seededEvents: [CredentialEvent] = [],
        snapshot: SigningClient.StatusSnapshot? = nil,
        flow: StubLoginFlow
    ) -> (model: CredentialStatusModel, recorder: Recorder) {
        let recorder = Recorder(seeded: seededEvents)
        let model = CredentialStatusModel(environment: .init(
            relayConfigured: { true },
            events: { recorder.emitted },
            emitEvent: { recorder.emit($0) },
            snapshot: { snapshot },
            dropSession: { recorder.dropped() },
            openURL: { recorder.opened($0) },
            storeBase: {
                recorder.storeBase(nil)
                return nil
            },
            makeLoginClient: { base, hook in
                recorder.storeBase(base)
                flow.setHook(hook)
                return flow
            }))
        return (model, recorder)
    }

    @Test("recompute publishes the derived face and nudges the badge seam")
    @MainActor
    func recomputePublishesDerivedFace() async {
        var faces: [CredentialFace] = []
        let model = CredentialStatusModel(environment: .init(
            relayConfigured: { true },
            events: { [.expired(reason: "token expired")] },
            snapshot: {
                SigningClient.StatusSnapshot(
                    phase: .signed, nowMs: Self.nowMs,
                    sessionExpiresAtMs: Self.nowMs + Self.minutes(41),
                    sessionMarginRelaxed: false,
                    storeAccessTokenExpiresAtMs: nil,
                    storeLacksProjectLocation: false,
                    cacheAcquiredAtMs: nil,
                    servedUnsigned: false)
            },
            onFaceChange: { faces.append($0) }))
        await model.recompute()
        #expect(model.face == .actionNeeded(reason: "token expired"))
        #expect(faces == [.actionNeeded(reason: "token expired")])
    }

    @Test("sign-in happy path: browser opens, store persists, session drops — signed in without restart")
    @MainActor
    func signInHappyPathFlipsFaceWithoutRestart() async {
        let flow = StubLoginFlow()
        flow.pollResult = .ready(
            ZaiLoginCredentials(accessToken: "synthetic", zcodeJwtToken: "synthetic", userInfoJSON: "{}"))
        // Expired before the login; a fresh store token after it.
        let healthyStore = snapshot(
            phase: .unsigned, sessionExpiresAtMs: nil,
            storeAccessTokenExpiresAtMs: Self.nowMs + Self.minutes(30))
        let (model, recorder) = makeModel(
            seededEvents: [.expired(reason: "token expired")],
            snapshot: healthyStore,
            flow: flow)

        await model.recompute()
        #expect(model.face == .actionNeeded(reason: "token expired"))

        model.startSignIn()
        #expect(model.loginInFlight)
        #expect(model.face == .awaitingAuthorization)
        await model.loginTask?.value

        #expect(flow.began)
        #expect(recorder.openedURLs == [flow.url])
        #expect(recorder.droppedSession == 1)  // hot pickup, no restart
        #expect(
            recorder.emitted.dropFirst()
            == [.awaitingAuthorization, .authorizationComplete])
        #expect(!model.loginInFlight)
        #expect(model.face == .signedIn(minutesLeft: nil))
    }

    @Test("sign-in failure keeps actionNeeded and shows the fixed retry copy")
    @MainActor
    func signInFailedKeepsActionNeededWithRetryCopy() async {
        let flow = StubLoginFlow()
        flow.pollResult = .failed(status: "auth_failed")
        let (model, recorder) = makeModel(
            seededEvents: [.expired(reason: "token expired")],
            snapshot: snapshot(phase: .unsigned, sessionExpiresAtMs: nil),
            flow: flow)

        await model.recompute()
        model.startSignIn()
        await model.loginTask?.value

        #expect(model.lastLoginOutcome == .failed(status: "auth_failed"))
        #expect(model.lastLoginOutcome?.retryText == "Login failed — retry")
        #expect(model.face == .actionNeeded(reason: "token expired"))
        #expect(recorder.droppedSession == 0)  // nothing persisted — no pickup
    }

    @Test("sign-in timeout shows the timeout retry copy")
    @MainActor
    func signInTimeoutShowsTimeoutRetryCopy() async {
        let flow = StubLoginFlow()
        flow.pollResult = .timedOut(afterMs: 300_000)
        let (model, _) = makeModel(
            seededEvents: [.expired(reason: "token expired")],
            snapshot: snapshot(phase: .unsigned, sessionExpiresAtMs: nil),
            flow: flow)

        await model.recompute()
        model.startSignIn()
        await model.loginTask?.value

        #expect(model.lastLoginOutcome?.retryText == "Login timed out — retry")
    }

    @Test("cancel aborts the flow cleanly and returns to the previous face")
    @MainActor
    func cancelSignInAbortsCleanly() async {
        let flow = StubLoginFlow()  // no scripted result → parks in poll
        let (model, recorder) = makeModel(
            seededEvents: [.expired(reason: "token expired")],
            snapshot: snapshot(phase: .unsigned, sessionExpiresAtMs: nil),
            flow: flow)

        await model.recompute()
        model.startSignIn()
        #expect(model.face == .awaitingAuthorization)

        model.cancelSignIn()
        await model.loginTask?.value

        #expect(flow.pollCancelled)
        #expect(!model.loginInFlight)
        #expect(model.lastLoginOutcome == nil)  // cancel is not a failure
        #expect(model.face == .actionNeeded(reason: "token expired"))
        #expect(recorder.droppedSession == 0)
    }

    @Test("reload credentials drops the session for hot pickup of an external login")
    @MainActor
    func reloadCredentialsDropsSessionForHotPickup() async {
        let flow = StubLoginFlow()
        let (model, recorder) = makeModel(
            seededEvents: [],
            snapshot: snapshot(sessionExpiresAtMs: Self.nowMs + Self.minutes(41)),
            flow: flow)

        await model.reloadCredentials()
        #expect(recorder.droppedSession == 1)
        #expect(model.face == .signedIn(minutesLeft: 41))
    }

    // MARK: - Settings store selector (item 4)

    @Test("store selection maps the persisted setting in both directions")
    func storeSelectionMapsSettingRoundTrip() {
        // nil/absent → shared default.
        #expect(CredentialStoreSelection.selection(for: nil) == .sharedWithGUI)
        // Scratch spelling (literal or absolute) → legacy scratch.
        #expect(
            CredentialStoreSelection.selection(for: "~/.zcode-scratch-v3") == .legacyScratch)
        #expect(
            CredentialStoreSelection.selection(for: CredentialStore.legacyScratchHome.path)
            == .legacyScratch)
        // Anything else → custom (including the empty explicit choice).
        #expect(
            CredentialStoreSelection.selection(for: "/opt/zgate-store") == .custom(path: "/opt/zgate-store"))
        #expect(CredentialStoreSelection.selection(for: "") == .custom(path: ""))

        // Round trip back to the persisted setting.
        #expect(CredentialStoreSelection.sharedWithGUI.setting == nil)
        #expect(CredentialStoreSelection.legacyScratch.setting == "~/.zcode-scratch-v3")
        #expect(CredentialStoreSelection.custom(path: "/opt/zgate-store").setting == "/opt/zgate-store")

        // The scratch setting resolves to the legacy base through the core's
        // resolver, and shared resolves to the (isolation-aware) default.
        #expect(
            CredentialStore.resolveBase(CredentialStoreSelection.legacyScratch.setting)
            == CredentialStore.legacyScratchHome)
        #expect(
            CredentialStore.resolveBase(CredentialStoreSelection.sharedWithGUI.setting)
            == CredentialStore.defaultBase)
    }

    // MARK: - Menu-bar badge (item 2) + alert redesign (item 3)

    @Test("menu-bar symbol: fault states outrank the quota ring, healthy returns nil")
    func menuBarSymbolGainsBadgeWhileActionNeeded() {
        // Not running, no error, not deliberately stopped → launching.
        #expect(
            ProxyServer.menuBarSymbol(
                isRunning: false, hasError: false, credentialActionNeeded: false, isStopped: false)
            == "hourglass")
        // Deliberate pause is distinct from a fault.
        #expect(
            ProxyServer.menuBarSymbol(
                isRunning: false, hasError: false, credentialActionNeeded: false, isStopped: true)
            == "pause.circle")
        #expect(
            ProxyServer.menuBarSymbol(
                isRunning: false, hasError: true, credentialActionNeeded: true, isStopped: false)
            == "exclamationmark.circle")  // not running wins over credentials
        #expect(
            ProxyServer.menuBarSymbol(
                isRunning: true, hasError: false, credentialActionNeeded: true, isStopped: false)
            == "exclamationmark.triangle")
        #expect(
            ProxyServer.menuBarSymbol(
                isRunning: true, hasError: true, credentialActionNeeded: false, isStopped: false)
            == "exclamationmark.circle")
        // Healthy running state: nil = draw the quota ring.
        #expect(
            ProxyServer.menuBarSymbol(
                isRunning: true, hasError: false, credentialActionNeeded: false, isStopped: false)
            == nil)
    }

    @Test("alert copy is accurate: pickup without restart; Sign In… is primary, Copy Command secondary")
    func alertCopyAccurateAndActionsTitled() {
        #expect(ReloginAlertContent.signInActionTitle == "Sign In…")
        #expect(ReloginAlertContent.copyCommandActionTitle == "Copy Command")
        let message = ReloginAlertContent.message(for: "token expired")
        #expect(message.contains("token expired"))
        // Short message (HIG alerts.md): the command lives behind Copy
        // Command / Settings → Advanced, never as unselectable alert text.
        #expect(!message.contains(ReloginAlertContent.command))
        #expect(message.contains("Copy Command"))
        #expect(message.lowercased().contains("browser"))
        // The fixed false claim is gone: pickup now needs no restart.
        #expect(!message.contains("picks up the refreshed session on the next request"))
        #expect(message.contains("no restart needed"))
    }
}

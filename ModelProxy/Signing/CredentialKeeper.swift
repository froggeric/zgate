import AppKit
import Foundation

/// One-shot async wake latch: `wait()` suspends until `signal()`; a signal
/// with no waiter coalesces into the next wait. Cancellation-safe including
/// the cancel-before-park race (a cancelled wait never parks) so the
/// keeper's sleep-vs-wake race can always drain both children.
final class WakeLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    private var cancelled = false
    private var waiter: CheckedContinuation<Void, Never>?

    func signal() {
        let resume = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            if let waiter {
                self.waiter = nil
                return waiter
            }
            pending = true
            return nil
        }
        resume?.resume()
    }

    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // .signal: a coalesced signal won this wait; .cancel:
                // cancellation landed before the waiter parked — resume
                // immediately instead of parking a cancelled wait forever.
                enum Immediate { case none, signal, cancel }
                let immediate = lock.withLock { () -> Immediate in
                    if pending {
                        pending = false
                        return .signal
                    }
                    if cancelled {
                        cancelled = false
                        return .cancel
                    }
                    waiter = continuation
                    return .none
                }
                switch immediate {
                case .signal, .cancel: continuation.resume()
                case .none: break
                }
            }
        } onCancel: {
            let resume = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                if let waiter {
                    self.waiter = nil
                    return waiter
                }
                cancelled = true
                return nil
            }
            resume?.resume()
        }
    }
}

/// Proactive auto-renewal (item 5, report §C.4): keeps the signing ladder
/// alive by minting ~refreshMargin before project-token expiry, without
/// waiting for a relayed request. Sleep/wake aware (NSWorkspace.didWake →
/// immediate re-evaluation — the clock may have jumped past expiry). On
/// ladder death it emits the failure and backs off (mintThrottle base +
/// exponential jitter, capped) — never mint-loops.
///
/// No UI: the status task (later) consumes the events this emits and the
/// SigningClient snapshot. Scope: while the app runs; never torn down on
/// server stop/start (billing/credential cadence is listener-independent,
/// same ruling as quota polling).
///
/// Never logs and never emits token material — event payloads are
/// timestamps, stages, and error descriptions (which carry status codes
/// only by construction).
final class CredentialKeeper: @unchecked Sendable {

    struct Configuration {
        var now: @Sendable () -> Date = { Date() }
        /// Production suspends for real; tests park/advance a virtual clock.
        var sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        /// Same margin the CLI's in-process cache uses (120 s — mirrors
        /// SigningClient.refreshMargin).
        var refreshMargin: TimeInterval = 120
        /// Upper bound between schedule re-evaluations (5 min).
        var recheckInterval: TimeInterval = 300
        /// Backoff base after a failed renewal (SigningClient's 5 s
        /// mintThrottle).
        var backoffBase: TimeInterval = 5
        var backoffCap: TimeInterval = 300
        /// Scheduling jitter, added into the backoff and subtracted from
        /// the refresh target. Injectable (tests pin 0).
        var jitter: @Sendable () -> TimeInterval = { .random(in: 0...30) }
        /// Wake source subscription: registers a handler, returns an
        /// unsubscribe. Default: NSWorkspace.didWakeNotification.
        var wakeSubscription:
            @Sendable (@escaping @Sendable () -> Void) -> (@Sendable () -> Void) = { handler in
                let center = NSWorkspace.shared.notificationCenter
                let observer = center.addObserver(
                    forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
                ) { _ in handler() }
                return { center.removeObserver(observer) }
            }

        init() {}
    }

    private let client: SigningClient
    private let configuration: Configuration
    private let emit: @Sendable (CredentialEvent) -> Void
    private let wakeLatch = WakeLatch()

    private let stateLock = NSLock()
    private var loopTask: Task<Void, Never>?
    private var wakeCancel: (@Sendable () -> Void)?
    private var consecutiveFailures = 0
    /// Backoff delay scheduled by `nextDelay(after:)` after a failed
    /// renewal; cleared on the next success.
    private var pendingBackoff: TimeInterval?

    init(
        client: SigningClient,
        configuration: Configuration = Configuration(),
        emit: @escaping @Sendable (CredentialEvent) -> Void
    ) {
        self.client = client
        self.configuration = configuration
        self.emit = emit
    }

    // MARK: - Lifecycle

    func start() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            await self?.loop()
        }
        wakeCancel = configuration.wakeSubscription { [weak self] in
            self?.wakeLatch.signal()
        }
    }

    func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }
        loopTask?.cancel()
        loopTask = nil
        wakeCancel?()
        wakeCancel = nil
    }

    // MARK: - Loop

    private func loop() async {
        while !Task.isCancelled {
            let snapshot = await client.statusSnapshot()
            let delay = nextDelay(after: snapshot)
            if delay > 0 {
                let woken = await wait(seconds: delay)
                if Task.isCancelled { return }
                // A wake re-evaluates immediately with a fresh snapshot
                // (the clock may have jumped past expiry); a completed
                // sleep falls through to the renewal attempt.
                if !woken { await renew() }
            } else {
                await renew()
            }
        }
    }

    /// Waits `seconds`, or returns early when woken. True = woken.
    private func wait(seconds: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { [sleep = configuration.sleep] in
                try? await sleep(seconds)
                return false
            }
            group.addTask { [latch = wakeLatch] in
                await latch.wait()
                return true
            }
            let woken = await group.next() ?? false
            group.cancelAll()
            while await group.next() != nil {}
            return woken
        }
    }

    /// Next schedule: backoff after failure, else
    /// min(expiry − margin − jitter, now + recheckInterval) — clamped at 0
    /// (a session already inside its margin renews immediately). No
    /// session (never built / dropped) → recheck only; the keeper keeps
    /// ladders alive, it never cold-builds (no network at launch).
    private func nextDelay(after snapshot: SigningClient.StatusSnapshot) -> TimeInterval {
        stateLock.lock()
        let backoff = pendingBackoff
        stateLock.unlock()
        if let backoff { return backoff }

        guard let expiresAtMs = snapshot.sessionExpiresAtMs else {
            return configuration.recheckInterval + configuration.jitter()
        }
        let nowMs = Int64(configuration.now().timeIntervalSince1970 * 1000)
        // A margin-relaxed session rides its short server-anchored window
        // to true expiry (mirrors SigningClient.ensureSession).
        let marginMs = snapshot.sessionMarginRelaxed ? 0 : Int64(configuration.refreshMargin * 1000)
        let refreshAtMs = expiresAtMs - marginMs - Int64(configuration.jitter() * 1000)
        let recheckAtMs = nowMs + Int64(configuration.recheckInterval * 1000)
        return max(0, TimeInterval(min(refreshAtMs, recheckAtMs) - nowMs) / 1000)
    }

    private func renew() async {
        do {
            let session = try await client.ensureSession()
            stateLock.lock()
            consecutiveFailures = 0
            pendingBackoff = nil
            stateLock.unlock()
            emit(.renewed(expiresAtMs: session.expiresAtMs))
        } catch {
            stateLock.lock()
            consecutiveFailures += 1
            let failures = consecutiveFailures
            stateLock.unlock()
            // Ladder death keeps the existing terminal surface (the alert
            // task shows action-needed); other failures are non-terminal.
            let reason = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
            if case SigningClientError.reloginRequired = error {
                emit(.expired(reason: reason))
            } else {
                emit(.refreshFailed(stage: Self.stage(of: error), reason: reason))
            }
            // Bounded backoff: base × 2^(n−1) + jitter, capped — never a
            // mint loop against a dead ladder.
            let exponential = configuration.backoffBase * pow(2, Double(failures - 1))
            stateLock.lock()
            pendingBackoff = min(exponential + configuration.jitter(), configuration.backoffCap)
            stateLock.unlock()
        }
    }

    /// Chain stage for `.refreshFailed` — typed reasons only.
    private static func stage(of error: Error) -> String {
        switch error as? SigningClientError {
        case .reloginRequired, .loginFailed: "login"
        case .mintFailed: "mint"
        case .handshakeFailed, .unsealFailed: "handshake"
        default: "chain"
        }
    }
}

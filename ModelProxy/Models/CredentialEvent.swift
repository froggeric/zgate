import Foundation
import Observation

/// Credential state surfaced to the UI. Payloads carry display reasons,
/// durations, and timestamps only — never a token, key, or signature value.
enum CredentialEvent: Equatable, Sendable {
    /// zcode credentials need an interactive re-login: the relay answered
    /// 401 `token expired`, or RelayTarget's reject ladder exhausted after a
    /// chain rebuild (the Task-5 "CredentialError.expired" surface).
    case expired(reason: String)
    /// The in-app OAuth flow started and is waiting for the user's browser
    /// approval (item 4: ZaiLoginClient, emitted after init succeeds).
    case awaitingAuthorization
    /// The in-app OAuth flow completed and a fresh store was written
    /// (item 4: ZaiLoginClient, emitted after the ready-path persist).
    case authorizationComplete
    /// A proactive background renewal minted a fresh project token
    /// (item 5: CredentialKeeper).
    case renewed(expiresAtMs: Int64)
    /// A proactive renewal attempt failed without demanding re-login
    /// (item 5: CredentialKeeper) — payload is a typed chain stage and an
    /// error description (status codes only, never token material).
    case refreshFailed(stage: String, reason: String)
}

/// UI channel for credential events (the re-login alert observes this).
/// @MainActor so SwiftUI can observe directly — same pattern as TrafficLog.
/// RelayTarget emits; the proxy layer never reads.
@MainActor
@Observable
final class CredentialEventChannel {

    /// Ordered oldest → newest.
    private(set) var events: [CredentialEvent] = []

    func emit(_ event: CredentialEvent) {
        events.append(event)
    }
}

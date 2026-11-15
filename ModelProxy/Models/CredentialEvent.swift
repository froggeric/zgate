import Foundation
import Observation

/// Terminal credential state surfaced to the UI. Payloads carry display
/// reasons only — never a token, key, or signature value.
enum CredentialEvent: Equatable, Sendable {
    /// zcode credentials need an interactive re-login: the relay answered
    /// 401 `token expired`, or RelayTarget's reject ladder exhausted after a
    /// chain rebuild (the Task-5 "CredentialError.expired" surface).
    case expired(reason: String)
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

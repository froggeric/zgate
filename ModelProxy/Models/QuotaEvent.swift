import Foundation
import Observation

/// Quota threshold band. The level of the CURRENT fraction decides the band;
/// crossing into a different band emits one `QuotaEvent.levelChanged` (Task 9
/// colors the bar gold < 25%, red < 10%).
enum QuotaLevel: Int, Sendable, Equatable, Comparable {
    case normal = 0
    case warning = 1  // ≤ 25% remaining
    case critical = 2  // ≤ 10% remaining

    /// Band of a remaining fraction (0...1).
    static func level(forFraction fraction: Double) -> QuotaLevel {
        if fraction <= criticalThreshold { return .critical }
        if fraction <= warningThreshold { return .warning }
        return .normal
    }

    static let warningThreshold = 0.25
    static let criticalThreshold = 0.10

    static func < (lhs: QuotaLevel, rhs: QuotaLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// UI channel for quota events. @MainActor so SwiftUI can observe directly —
/// same pattern as `CredentialEventChannel`. QuotaService emits; the proxy
/// layer never reads. Payloads carry band transitions only — never a balance
/// value.
enum QuotaEvent: Equatable, Sendable {
    /// The remaining fraction crossed a threshold band (25%/10%). The first
    /// observation after launch establishes the baseline silently — events
    /// fire on CHANGES, so a steady level never spams per poll.
    case levelChanged(from: QuotaLevel, to: QuotaLevel)
}

@MainActor
@Observable
final class QuotaEventChannel {

    /// Ordered oldest → newest.
    private(set) var events: [QuotaEvent] = []

    func emit(_ event: QuotaEvent) {
        events.append(event)
    }
}

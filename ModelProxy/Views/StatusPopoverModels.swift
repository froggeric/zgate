import Foundation
import Observation
import SwiftUI

// MARK: - Credential re-login alert (Task 9, testable)

/// Presents the re-login alert only for UNSEEN `.expired` events. The
/// channel is append-only and carries no resolution event, so "seen" is a
/// high-water mark on the event count — without it, one expiry re-presents
/// the modal on every popover open for the rest of the session, even after
/// a successful re-login. The mark lives here, not in view `@State`,
/// because MenuBarExtra rebuilds the popover per open; `shared` is fine
/// since there is exactly one popover per process.
@MainActor
@Observable
final class CredentialAlertPresenter {

    static let shared = CredentialAlertPresenter()

    /// Events already surfaced to the user.
    private(set) var seenCount: Int = 0

    /// Pure decision (testable): the event to present given the channel and
    /// the high-water mark. nil when everything is already seen.
    static func pendingAlert(
        events: [CredentialEvent], seenCount: Int
    ) -> CredentialEvent? {
        guard events.count > seenCount else { return nil }
        return events.last
    }

    /// Marks the current channel contents seen and returns the event to
    /// show (a burst that fired while the popover was closed collapses to
    /// one alert on the next open); nil when nothing is new.
    func consume(events: [CredentialEvent]) -> CredentialEvent? {
        guard Self.pendingAlert(events: events, seenCount: seenCount) != nil else {
            return nil
        }
        seenCount = events.count
        return events.last
    }
}

/// Content for the credential-expired alert, driven by
/// `CredentialEventChannel`'s `.expired` events. Primary action is the
/// in-app browser login (login-flow UI item 3); the exact terminal command
/// from the Task 5 surface stays as the copyable fallback — the recovery
/// path if the browser flow ever breaks. The alert carries the command and
/// neutral instructions only, never a token, key, or signature value.
enum ReloginAlertContent: Sendable {
    /// The exact command (single line; wrapped only by display).
    static let command =
        "ZCODE_DATA_BASE_DIR=$HOME/.zcode-scratch-v3 ZCODE_CREDENTIAL_SECRET_FILE=$HOME/.zcode-scratch-v3/secret.txt node /Applications/ZCode.app/Contents/Resources/glm/zcode.cjs login zai"

    /// Alert title.
    static let title = "ZCode login required"

    /// Primary action: runs the in-app browser OAuth flow.
    static let signInActionTitle = "Sign In…"

    /// Secondary action: terminal fallback (copies the command below).
    static let copyCommandActionTitle = "Copy Command"

    /// Alert message: the service reason, the command to run, and the
    /// pickup note. With the store loader this is true for a RUNNING app —
    /// after the in-app login or an external one, no restart needed.
    static func message(for reason: String) -> String {
        """
        The relay rejected the stored credentials (\(reason)).

        Run this command in a terminal to re-login:

        \(command)

        It opens a browser for OAuth. After signing in, ZGate picks up the new session automatically — no restart needed.
        """
    }
}

// MARK: - Copyable env line (Task 9, testable)

/// Formation of the copyable client env line. The spec pins the exact
/// `export ANTHROPIC_BASE_URL=http://127.0.0.1:<port>` form, where the port
/// is the ACTUAL bound port (listeners auto-advance when the configured
/// port is taken), not the configured one.
enum EnvExportLine: Sendable {

    static func baseURLLine(port: Int) -> String {
        "export ANTHROPIC_BASE_URL=http://127.0.0.1:\(port)"
    }

    /// The port to advertise for the Claude Code listener: the bound port
    /// when the server is running (auto-advanced if the configured port was
    /// taken), else the configured port. nil when no claude-named client
    /// exists.
    static func claudePort(boundPorts: [String: Int], clients: [ClientConfig]) -> Int? {
        let claudeClients = clients.filter { $0.clientName.lowercased().contains("claude") }
        guard let client = claudeClients.first ?? clients.first else { return nil }
        return boundPorts[client.clientName] ?? client.port
    }

    /// Full line for the current state; nil when there is no client to
    /// advertise.
    static func claudeLine(boundPorts: [String: Int], clients: [ClientConfig]) -> String? {
        claudePort(boundPorts: boundPorts, clients: clients).map { baseURLLine(port: $0) }
    }
}

// MARK: - Active rules summary (Task 9, testable)

/// Condensed popover summary of the active rule table (spec §6): ordered
/// enabled rules as `match → target` pairs, class rules first in config
/// order, catch-all last regardless of position. Disabled rules are
/// counted, not listed.
enum RulesSummary: Sendable {

    /// `nil` when there are no enabled rules.
    static func text(mappings: [ModelMapping], vendors: [Vendor]) -> String? {
        func vendorName(_ id: UUID) -> String {
            vendors.first(where: { $0.id == id })?.name ?? "?"
        }
        var parts: [String] = []
        for mapping in mappings where mapping.isEnabled {
            let match: String
            if mapping.catchAll {
                match = "other"
            } else if let matchClass = mapping.matchClass {
                match = matchClass.rawValue
            } else {
                match = mapping.sourceModel
            }
            let target = "\(mapping.targetModel) @ \(vendorName(mapping.targetVendorID))"
            var part = "\(match) → \(target)"
            if let backupVendorID = mapping.backupTargetVendorID {
                let backupModel = mapping.backupTargetModel ?? mapping.targetModel
                part += " ⇄ \(backupModel) @ \(vendorName(backupVendorID))"
            }
            parts.append(part)
        }
        guard !parts.isEmpty else { return nil }
        let disabled = mappings.filter { !$0.isEnabled }.count
        let suffix = disabled > 0 ? "  (+\(disabled) off)" : ""
        return parts.joined(separator: " · ") + suffix
    }
}

// MARK: - Splash lifecycle chip (Package C, testable)

/// Popover face for the manager's process state (spec §5). The router's
/// health seam keeps its own truth in `LocalHealthMonitor` — this chip is
/// lifecycle, not reachability.
enum SplashLifecycleChip: Equatable, Sendable {

    struct Face: Equatable, Sendable {
        let text: String
        let color: Color
    }

    static func face(for state: SplashState, now: Date) -> Face {
        switch state {
        case .running(let profile, _, let adopted):
            return .init(
                text: "● splash · \(profile)" + (adopted ? " · external" : ""),
                color: .green)
        case .starting:
            return .init(text: "◐ splash · starting", color: .gray)
        case .crashed(_, _, let nextRetry):
            var text = "● splash"
            if let next = nextRetry {
                text += " · retry in \(max(0, Int(next.timeIntervalSince(now)))) s"
            } else {
                // No retry scheduled (spawn failure / readiness timeout).
                text += " · crashed"
            }
            return .init(text: text, color: .orange)
        case .stopping:
            return .init(text: "◐ splash · stopping", color: .gray)
        case .stopped:
            return .init(text: "○ splash · off", color: .gray)
        }
    }
}

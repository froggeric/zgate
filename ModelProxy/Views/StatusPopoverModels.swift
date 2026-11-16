import Foundation
import Observation

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
/// `CredentialEventChannel`'s `.expired` events. The command is the EXACT
/// re-login line from the Task 5 surface — presented copyable; the alert
/// carries the command and neutral instructions only, never a token, key,
/// or signature value.
enum ReloginAlertContent: Sendable {
    /// The exact command (single line; wrapped only by display).
    static let command =
        "ZCODE_DATA_BASE_DIR=$HOME/.zcode-scratch-v3 ZCODE_CREDENTIAL_SECRET_FILE=$HOME/.zcode-scratch-v3/secret.txt node /Applications/ZCode.app/Contents/Resources/glm/zcode.cjs login zai"

    /// Alert title.
    static let title = "ZCode login required"

    /// Alert message: the service reason, the command to run, and the note
    /// that it opens a browser for OAuth.
    static func message(for reason: String) -> String {
        """
        The relay rejected the stored credentials (\(reason)).

        Run this command in a terminal to re-login:

        \(command)

        It opens a browser for OAuth. ZGate picks up the refreshed session on the next request.
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

// MARK: - Splash health chip (Task 9, testable)

/// Splash (loopback target) reachability for the popover chip. Mirrors the
/// router's health semantics (`ClassRuleTable.healthStalenessLimit`): a
/// success inside the window is up; an aged-out success is down with the
/// last-seen time; never probed is unknown (routing fail-open).
enum SplashHealth: Equatable, Sendable {
    case up
    case down(lastSeen: Date?)
    case unknown

    /// nil when no loopback (splash) vendor is configured — the chip hides.
    static func evaluate(
        vendors: [Vendor],
        lastSuccess: (UUID) -> Date?,
        now: Date,
        staleness: TimeInterval = ClassRuleTable.healthStalenessLimit
    ) -> SplashHealth? {
        let splashVendors = vendors.filter { LocalTarget.isLoopbackBaseURL($0.baseURL) }
        guard let splash = splashVendors.first else { return nil }
        guard let lastSeen = lastSuccess(splash.id) else { return .unknown }
        return now.timeIntervalSince(lastSeen) <= staleness ? .up : .down(lastSeen: lastSeen)
    }

    var label: String {
        switch self {
        case .up: return "splash up"
        case .down: return "splash down"
        case .unknown: return "splash n/a"
        }
    }
}

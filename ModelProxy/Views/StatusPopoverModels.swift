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
/// path if the browser flow ever breaks. The message stays short (HIG
/// alerts.md): the command is one click away via Copy Command and also
/// lives in Settings → Advanced; alert text is not selectable, so it never
/// carries material someone must transcribe. Never a token, key, or
/// signature value.
enum ReloginAlertContent: Sendable {
    /// The exact command (single line; wrapped only by display).
    static let command =
        "ZCODE_DATA_BASE_DIR=$HOME/.zcode-scratch-v3 ZCODE_CREDENTIAL_SECRET_FILE=$HOME/.zcode-scratch-v3/secret.txt node /Applications/ZCode.app/Contents/Resources/glm/zcode.cjs login zai"

    /// Alert title.
    static let title = "ZCode Login Required"

    /// Primary action: runs the in-app browser OAuth flow.
    static let signInActionTitle = "Sign In…"

    /// Secondary action: terminal fallback (copies the command; the same
    /// line is shown in Settings → Advanced).
    static let copyCommandActionTitle = "Copy Command"

    /// Alert message: the service reason, the recovery path, and the
    /// pickup note. With the store loader this is true for a RUNNING app —
    /// after the in-app login or an external one, no restart needed.
    static func message(for reason: String) -> String {
        """
        The relay rejected the stored credentials (\(reason)).

        Choose Sign In… to open the browser and sign in again — ZGate picks up the new session automatically, no restart needed. The terminal fallback is one click away with Copy Command, and also in Settings → Advanced.
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

    /// Quick-start command for a Clients-tab row: the same env export
    /// (actual bound port, 127.0.0.1 host — identical semantics to
    /// `claudeLine`) plus the tool launch. One formatter so the popover
    /// env line and the tab's command can never disagree.
    static func quickStartCommand(client: ClientConfig, boundPort: Int?) -> String {
        let port = boundPort ?? client.port
        let tool: String
        let name = client.clientName.lowercased()
        if name.contains("claude") {
            tool = "claude"
        } else if name.contains("codex") {
            tool = "codex"
        } else {
            tool = name
        }
        // Gateway hint headers let the traffic list label subagent,
        // compaction and auxiliary requests.
        let hints = tool == "claude" ? " CLAUDE_CODE_GATEWAY_HINT_HEADERS=1" : ""
        return baseURLLine(port: port) + hints + " && \(tool)"
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
/// lifecycle, not reachability. State is shape + text (filled / half /
/// dashed / alert symbol), never color alone; gray faces use `.secondary`
/// so they dim correctly in both appearances.
enum SplashLifecycleChip: Equatable, Sendable {

    struct Face: Equatable, Sendable {
        let symbolName: String
        let text: String
        let color: Color
    }

    static func face(for state: SplashState, now: Date) -> Face {
        switch state {
        case .running(let profile, _, let adopted):
            return .init(
                symbolName: "circle.fill",
                text: "splash · \(profile)" + (adopted ? " · external" : ""),
                color: .green)
        case .starting:
            return .init(symbolName: "circle.lefthalf.filled", text: "splash · starting", color: .secondary)
        case .crashed(_, _, let nextRetry):
            var text = "splash"
            if let next = nextRetry {
                text += " · retry in \(max(0, Int(next.timeIntervalSince(now)))) s"
            } else {
                // No retry scheduled (spawn failure / readiness timeout).
                text += " · crashed"
            }
            return .init(symbolName: "exclamationmark.circle.fill", text: text, color: .orange)
        case .stopping:
            return .init(symbolName: "circle.lefthalf.filled", text: "splash · stopping", color: .secondary)
        case .stopped:
            return .init(symbolName: "circle.dashed", text: "splash · off", color: .secondary)
        }
    }
}

import Foundation

/// What ZGate recommends for Claude Code's settings file (configurator spec
/// v2). Absent in every pre-configurator config: tolerant per-key decode (the
/// DebugConfig lesson), and `AppConfig` writes the section only once it
/// differs from the defaults, so untouched installs stay byte-stable.
struct ClaudeSetupSettings: Hashable, Sendable {
    /// The three tier ids Claude Code asks for, without `[1m]`. The aliases
    /// never change at a model launch, and which model answers is ZGate's
    /// rule table. The configurator adds `[1m]` to an id whose window is 1M
    /// or more (measured on 2.1.323: the suffix pins the window there, and
    /// the window written beside it keeps proactive compaction on).
    var opusID: String = "opus"
    var sonnetID: String = "sonnet"
    var haikuID: String = "haiku"
    /// Offer the constant id `local`, routed to the active splash profile, so
    /// one session can run on the local model with its own context window.
    var localIDEnabled: Bool = false
    /// Window of an id ZGate routes to a model it knows no window for. GLM-5.4
    /// and GLM-5.3-Flash state 1M.
    var defaultContextWindow: Int = 1_000_000
    /// Percentage of the effective window at which Claude Code compacts.
    var compactPercent: Int = 70
    /// A window set here for a role (`opus`, `sonnet`, `haiku`, `local`) wins
    /// over what the route says.
    var contextWindows: [String: Int] = [:]

    /// The id of the local model; also the key of its routing rule.
    static let localID = "local"
    /// The roles that can carry a window set here.
    static let roles = ["opus", "sonnet", "haiku", "local"]

    /// `glm-5.4[1m]` and `glm-5.4` are the same id to Claude Code: it strips
    /// the suffix before sending and for saved settings.
    static func withoutOneM(_ id: String) -> String {
        id.lowercased().hasSuffix("[1m]") ? String(id.dropLast(4)) : id
    }

    /// The id Claude Code asks for a role. An empty setting falls back to the alias.
    func id(for role: String) -> String {
        let value: String
        switch role {
        case "opus": value = opusID
        case "sonnet": value = sonnetID
        case "haiku": value = haikuID
        default: return Self.localID
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? role : trimmed
    }
}

extension ClaudeSetupSettings: Codable {
    enum CodingKeys: String, CodingKey {
        case opusID, sonnetID, haikuID, localIDEnabled, defaultContextWindow, compactPercent, contextWindows
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        opusID = try c.decodeIfPresent(String.self, forKey: .opusID) ?? "opus"
        sonnetID = try c.decodeIfPresent(String.self, forKey: .sonnetID) ?? "sonnet"
        haikuID = try c.decodeIfPresent(String.self, forKey: .haikuID) ?? "haiku"
        localIDEnabled = try c.decodeIfPresent(Bool.self, forKey: .localIDEnabled) ?? false
        defaultContextWindow = try c.decodeIfPresent(Int.self, forKey: .defaultContextWindow) ?? 1_000_000
        compactPercent = try c.decodeIfPresent(Int.self, forKey: .compactPercent) ?? 70
        contextWindows = try c.decodeIfPresent([String: Int].self, forKey: .contextWindows) ?? [:]
    }
}

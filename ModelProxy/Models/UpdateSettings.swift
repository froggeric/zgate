import Foundation

/// Update-check preferences + last-seen state (spec §4), persisted under
/// `AppConfig.update`. Tolerant decode (SplashStorage's pattern): absent
/// keys fall back to defaults so pre-update configs and hand-edited
/// partials load without resetting anything.
struct UpdateSettings: Codable, Equatable, Sendable {
    /// Gates every automatic check (launch check + 24 h timer); manual
    /// "Check Now" is unaffected. Read live at every cycle boundary, so
    /// a mid-session toggle takes effect without a relaunch.
    var autoCheck: Bool = true
    /// Locked decision 2 default: apply splash updates automatically when
    /// the engine is stopped (consumed by the auto-apply task).
    var splashAutoApply: Bool = true
    /// Latest tag the splash check has seen (any outcome it could parse).
    var lastSplashTag: String?
    /// Latest tag the ZGate check has seen.
    var lastZGateTag: String?
    /// When `checkNow` last ran — even degraded (nil-on-failure) cycles
    /// bump it, so a failing check never retry-storms the API.
    var lastCheckAt: Date?
    /// Dismissing an alert records its tag; a NEWER tag re-alerts (the
    /// tag comparison lives in UpdateCenter's alert accessors).
    var dismissedSplashTag: String?
    var dismissedZGateTag: String?

    init(
        autoCheck: Bool = true,
        splashAutoApply: Bool = true,
        lastSplashTag: String? = nil,
        lastZGateTag: String? = nil,
        lastCheckAt: Date? = nil,
        dismissedSplashTag: String? = nil,
        dismissedZGateTag: String? = nil
    ) {
        self.autoCheck = autoCheck
        self.splashAutoApply = splashAutoApply
        self.lastSplashTag = lastSplashTag
        self.lastZGateTag = lastZGateTag
        self.lastCheckAt = lastCheckAt
        self.dismissedSplashTag = dismissedSplashTag
        self.dismissedZGateTag = dismissedZGateTag
    }

    enum CodingKeys: String, CodingKey {
        case autoCheck, splashAutoApply, lastSplashTag, lastZGateTag, lastCheckAt, dismissedSplashTag, dismissedZGateTag
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoCheck = (try? c.decode(Bool.self, forKey: .autoCheck)) ?? true
        splashAutoApply = (try? c.decode(Bool.self, forKey: .splashAutoApply)) ?? true
        lastSplashTag = try? c.decode(String.self, forKey: .lastSplashTag)
        lastZGateTag = try? c.decode(String.self, forKey: .lastZGateTag)
        lastCheckAt = try? c.decode(Date.self, forKey: .lastCheckAt)
        dismissedSplashTag = try? c.decode(String.self, forKey: .dismissedSplashTag)
        dismissedZGateTag = try? c.decode(String.self, forKey: .dismissedZGateTag)
    }
}

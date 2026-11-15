import Foundation

/// Model class a routing rule can match (spec §2 class map).
enum ModelClass: String, Codable, CaseIterable, Sendable {
    case opus, sonnet, haiku, auto
}

/// One `when` condition on a routing rule. Flat spec-§2 JSON shape
/// (`{"type": "timeWindow", "days": "weekdays", "from": "07:00", ...}`);
/// fields unused by the condition's `type` are ignored. ALL conditions on a
/// rule must hold (AND); an omitted/empty array means the rule always holds.
struct RuleCondition: Codable, Equatable, Sendable {

    enum Kind: String, Codable, Sendable {
        case timeWindow
        case quotaBelow
    }

    /// Which days the time window applies to.
    enum DayScope: String, Codable, Sendable {
        case weekdays
        case weekend
        case daily
    }

    var type: Kind
    /// timeWindow: day scope (nil = daily).
    var days: DayScope?
    /// timeWindow: "HH:mm" window start in `tz` (inclusive).
    var from: String?
    /// timeWindow: "HH:mm" window end in `tz` (exclusive); earlier than
    /// `from` wraps past midnight.
    var to: String?
    /// timeWindow: IANA time-zone identifier, e.g. "Europe/Paris"
    /// (nil = the local zone).
    var tz: String?
    /// quotaBelow: route while the remaining quota is below this percent.
    var percent: Double?

    init(
        type: Kind,
        days: DayScope? = nil,
        from: String? = nil,
        to: String? = nil,
        tz: String? = nil,
        percent: Double? = nil
    ) {
        self.type = type
        self.days = days
        self.from = from
        self.to = to
        self.tz = tz
        self.percent = percent
    }

    // MARK: - Codable (legacy-tolerant: `type` required, rest optional)

    enum CodingKeys: String, CodingKey {
        case type, days, from, to, tz, percent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(Kind.self, forKey: .type)
        days = try? c.decode(DayScope.self, forKey: .days)
        from = try? c.decode(String.self, forKey: .from)
        to = try? c.decode(String.self, forKey: .to)
        tz = try? c.decode(String.self, forKey: .tz)
        percent = try? c.decode(Double.self, forKey: .percent)
    }
}

import Foundation

/// A drained upstream error response, parsed from JSON only: the HTTP
/// status plus the business `code` and human message extracted from the
/// envelope (relay fidelity Task 6).
///
/// Classification NEVER runs over raw body bytes — 20-digit logids contain
/// every 4-digit code as a substring, so substring matching would
/// misclassify (the plan's explicit ruling). The `'expired'` detection on
/// the 401 ladder is different: it matches this parsed `message` field, not
/// the raw body.
struct RelayUpstreamError: Equatable, Sendable {
    let status: Int
    /// Business code from the envelope (`{code}` top-level, `{error.code}`
    /// nested) — nil when the body carried none.
    let code: Int?
    /// Human message (`{msg}`, `{message}`, `{error.message}`) — nil when
    /// the body carried none.
    let message: String?

    init(status: Int, code: Int? = nil, message: String? = nil) {
        self.status = status
        self.code = code
        self.message = message
    }

    /// Extracts `(code, message)` from the known envelope shapes:
    /// `{code, msg|message}`, `{error:{message, code}}`, and
    /// `{error:{type, message}}` (the Anthropic shape — message but no
    /// code). nil when the body is not a JSON object.
    static func parse(status: Int, body: Data) -> RelayUpstreamError? {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        else { return nil }
        return from(json: json, status: status)
    }

    /// Shared field extraction over a parsed top-level object.
    static func from(json: [String: Any], status: Int) -> RelayUpstreamError {
        let errorObject = json["error"] as? [String: Any]
        let code = RelayErrorTaxonomy.numberField(json["code"] ?? errorObject?["code"]).map(Int.init)
        let message = (errorObject?["message"] as? String)
            ?? json["message"] as? String
            ?? json["msg"] as? String
        return RelayUpstreamError(status: status, code: code, message: message)
    }

    /// Display string for logs and proxy-authored terminals: the envelope
    /// message, else a code/status identification — never a raw body dump.
    var displayReason: String {
        if let message, !message.isEmpty { return message }
        if let code { return "business code \(code)" }
        return "HTTP \(status)"
    }
}

/// Failure class the relay's remediation branches on. Task 7's degraded
/// machine (`RelayHealth`) consumes the same classes.
enum RelayFailureKind: Equatable, Sendable {
    /// Plan quota gone (1005/1113/1310, HTTP 402): no retry, quota poll
    /// tick, 429-shaped surface.
    case quotaExhausted
    /// True rate limit (1302/1303): the existing single-backoff-retry
    /// policy, then the caller's fallback.
    case rateLimited
    /// Concurrency cap (3008/3009/3010): up to 2 in-place retries.
    case concurrencyLimited
    /// Risk control (3012, HTTP 405): no retry, cooldown, clear 502.
    case riskControl
    /// Captcha challenge (3007): surfaced as-is, never solved.
    case captchaChallenge
    /// Model not served (3006): surfaced 400 as-is (Task 5 prevents the
    /// common cases upstream).
    case modelNotAllowed
    /// Bad request parameter (1210/3001): surfaced 400 as-is.
    case invalidParameter
    /// No known code and no class-carrying status — the caller's default
    /// handling (passthrough / the status ladder) applies.
    case unclassified
}

/// Business-code taxonomy: parsed-JSON code (or status fallback) → failure
/// class. Pure and synchronous — the remediation wiring lives in
/// RelayTarget.
enum RelayErrorTaxonomy {

    /// A code match always wins over the status fallbacks; `1114` is
    /// deliberately absent (no peer emits it — never classified).
    static func classify(_ error: RelayUpstreamError) -> RelayFailureKind {
        if let code = error.code {
            switch code {
            case 1005, 1113, 1310: return .quotaExhausted
            case 1302, 1303: return .rateLimited
            case 3008, 3009, 3010: return .concurrencyLimited
            case 3012: return .riskControl
            case 3007: return .captchaChallenge
            case 3006: return .modelNotAllowed
            case 1210, 3001: return .invalidParameter
            default: break  // unknown code: fall through to the status ladder
            }
        }
        switch error.status {
        case 402: return .quotaExhausted
        case 405: return .riskControl
        default: return .unclassified
        }
    }

    /// The parsed business envelope from a 200 response body, or nil when
    /// the body is not one: non-JSON, no top-level non-zero numeric `code`,
    /// or an Anthropic success (`type:"message"` — successes carry
    /// `type`/`id`, never `code`). This is the 200-envelope gate: only a
    /// non-nil return may be classified instead of relayed as success.
    static func businessEnvelope(status: Int, body: Data) -> RelayUpstreamError? {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        else { return nil }
        if (json["type"] as? String) == "message" { return nil }
        guard let code = numberField(json["code"]), code != 0 else { return nil }
        return RelayUpstreamError.from(json: json, status: status)
    }

    /// Number-or-numeric-string field, booleans excluded (the
    /// `QuotaService.MonitorEnvelope` / `SigningClient` parse discipline).
    static func numberField(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.doubleValue
        }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

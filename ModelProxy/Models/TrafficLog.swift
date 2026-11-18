import Foundation
import Observation

// MARK: - TrafficEntry

/// One recorded proxy request. No body content is stored.
struct TrafficEntry: Identifiable, Sendable {
    enum RouteType: Sendable {
        case passthrough
        case mapped(targetModel: String)
        case blocked
    }

    enum RequestKind: Sendable, Equatable {
        case generation
        case countTokens
        case auxiliary(endpointPath: String)
        case blocked
        case webSearchBridge(searchCount: Int)

        var endpointLabel: String {
            switch self {
            case .generation:
                return "messages"
            case .countTokens:
                return "count_tokens"
            case .auxiliary(let endpointPath):
                return endpointPath
            case .blocked:
                return "blocked"
            case .webSearchBridge:
                return "web_search"
            }
        }

        var isAuxiliary: Bool {
            switch self {
            case .generation, .blocked, .webSearchBridge:
                return false
            case .countTokens, .auxiliary:
                return true
            }
        }

        var shouldDisplayTPS: Bool {
            switch self {
            case .generation:
                return true
            case .countTokens, .auxiliary, .blocked, .webSearchBridge:
                return false
            }
        }
    }

    /// What kind of Claude Code request this was, from its gateway hint headers.
    enum RequestClass: String, Sendable, Equatable {
        case main
        case subagent
        case workflow
        case compaction
        case auxiliary
    }

    let id: UUID
    let model: String
    let routeType: RouteType
    let requestKind: RequestKind
    /// HTTP status returned to the client (200, 403, 502, etc.)
    let httpStatus: Int
    let timestamp: Date
    /// Total request duration in seconds; nil for blocked requests (no upstream call).
    let duration: TimeInterval?
    /// Time to FIRST body byte in seconds (perceived responsiveness); nil
    /// when no body chunk was relayed (blocked, errored, non-streamed).
    let ttft: TimeInterval?
    /// Output tokens from this request; nil when unavailable (blocked, replay, or no usage data).
    let outputTokens: Int?
    /// Claude Code request class; nil when the client sent no hint.
    private(set) var requestClass: RequestClass?

    init(
        model: String,
        routeType: RouteType,
        requestKind: RequestKind,
        httpStatus: Int,
        duration: TimeInterval? = nil,
        ttft: TimeInterval? = nil,
        outputTokens: Int? = nil,
        timestamp: Date = .now
    ) {
        self.id = UUID()
        self.model = model
        self.routeType = routeType
        self.requestKind = requestKind
        self.httpStatus = httpStatus
        self.duration = duration
        self.ttft = ttft
        self.outputTokens = outputTokens
        self.timestamp = timestamp
    }

    func with(requestClass: RequestClass?) -> TrafficEntry {
        var copy = self
        copy.requestClass = requestClass
        return copy
    }

    /// Side requests (token counting, titles, classifiers) are shown dimmed.
    var isAuxiliaryTraffic: Bool {
        requestKind.isAuxiliary || requestClass == .auxiliary
    }

    var displayModelLabel: String {
        let label: String
        switch requestKind {
        case .webSearchBridge(let searchCount):
            if searchCount == 1 {
                label = "Web Search - \(model)"
            } else {
                label = "Web Search (\(searchCount)) - \(model)"
            }
        case .generation, .countTokens, .auxiliary, .blocked:
            label = model
        }
        guard let requestClass, requestClass != .main else { return label }
        return "\(label) · \(requestClass.rawValue)"
    }

    var routeDisplayLabel: String {
        switch routeType {
        case .passthrough:
            return "pass"
        case .mapped(let targetModel):
            return targetModel
        case .blocked:
            return "blocked"
        }
    }

    // MARK: Task 9 log-row columns (time, class → target, model, ms, tokens, status)

    /// "14:03:07" — local clock time of the request.
    var timeDisplayText: String {
        Self.rowTimeFormatter.string(from: timestamp)
    }

    /// "haiku → Qwen3.8-27B-4bit" — the spec §6 class→target column. The
    /// class is the gateway-hint class when present, else the model's
    /// classified class; the target is the routed model (or pass/blocked).
    var classTargetDisplayLabel: String {
        let className = requestClass?.rawValue ?? ModelClass.classify(model)?.rawValue ?? "other"
        return "\(className) → \(routeDisplayLabel)"
    }

    /// TTFT rounded to seconds (one decimal under 1 s so fast relays stay
    /// distinguishable); "—" when unmeasured.
    var ttftDisplayText: String {
        guard let ttft else { return "—" }
        return ttft < 1 ? String(format: "%.1fs", ttft) : "\(Int(ttft.rounded()))s"
    }

    /// Decode speed: output tokens over the streaming window (duration
    /// minus TTFT). "—" when not derivable — including NON-STREAMED
    /// responses, where the first body byte arrives with the complete body
    /// (ttft ~ duration) and a "speed" would be fiction.
    var tokensPerSecondDisplayText: String {
        guard requestKind.shouldDisplayTPS,
              let outputTokens, outputTokens > 0,
              let duration,
              let ttft,
              ttft < 0.9 * duration else { return "—" }
        let streamSeconds = max(duration - ttft, 0.05)
        return "\(Int((Double(outputTokens) / streamSeconds).rounded()))/s"
    }

    /// Compact output-token count ("1.2k"); "—" when unavailable.
    var tokensDisplayText: String {
        outputTokens.map { $0.compactTokenString } ?? "—"
    }

    private static let rowTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var durationDisplayText: String {
        guard let duration else { return "-" }
        if duration < 1 {
            return String(format: "%.1fs", duration)
        } else if duration < 60 {
            return "\(Int(duration))s"
        } else {
            return String(format: "%.1fm", duration / 60)
        }
    }

    var tpsDisplayText: String {
        if case .webSearchBridge = requestKind {
            return "-"
        }
        guard requestKind.shouldDisplayTPS else { return "\u{2014}" }
        guard let outputTokens, outputTokens > 0,
              let duration, duration > 0 else { return "\u{2014}" }
        return "\(Int(Double(outputTokens) / duration))"
    }

    var accessibilitySummary: String {
        switch requestKind {
        case .webSearchBridge(let searchCount):
            let countLabel = searchCount == 1 ? "1 search" : "\(searchCount) searches"
            return "Web Search, \(model), \(countLabel), \(routeDisplayLabel), HTTP \(httpStatus), \(durationDisplayText), \(tpsDisplayText) t/s"
        case .generation, .countTokens, .auxiliary, .blocked:
            return "\(displayModelLabel), \(routeDisplayLabel), HTTP \(httpStatus), \(durationDisplayText), \(tpsDisplayText) t/s"
        }
    }
}

// MARK: - TrafficLog

/// Ring buffer of recent proxy requests. Capped at 500 entries (spec §6
/// live request log).
/// @MainActor so SwiftUI can observe it directly without cross-actor hops.
@MainActor
@Observable
final class TrafficLog {

    static let maxEntries = 500

    /// Ordered oldest → newest; consumers scroll/display newest last.
    private(set) var entries: [TrafficEntry] = []

    /// Append a new entry, evicting the oldest if the buffer is full.
    func append(_ entry: TrafficEntry) {
        if entries.count >= Self.maxEntries {
            entries.removeFirst()
        }
        entries.append(entry)
    }
}

import Foundation

/// Crash-relay backoff (spec §3.1): 1 s doubling, 60 s cap; the attempt
/// counter resets after `stableReset` (5 min) of continuous running.
enum SplashBackoff {
    static let cap: TimeInterval = 60
    static let stableReset: TimeInterval = 300

    /// Delay before relaunch attempt `attempt` (1-based). attempt ≤ 0 → 0.
    static func delay(attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        return min(TimeInterval(1 << min(attempt - 1, 6)), cap)
    }
}

/// Fixed-capacity stdout/stderr tail (spec §3.1: last 500 lines in memory).
struct LogRingBuffer: Equatable, Sendable {
    static let defaultCapacity = 500
    private(set) var lines: [String] = []
    let capacity: Int

    init(capacity: Int = LogRingBuffer.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    mutating func append(_ line: String) {
        lines.append(line)
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
    }
}

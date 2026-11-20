import Foundation
import Observation

/// The forwarder's off-peak window gate (wave 2 Task 4): a cached,
/// lock-guarded read of the polled window state. Deliberately narrow so
/// tests stub the gate without a live monitor — and so the request hot
/// path can never grow a request-time availability call.
protocol OffPeakAvailabilityMonitoring: Sendable {
    var isWindowOpen: Bool { get }
}

/// Server-driven off-peak window status, polled at a bounded cadence while
/// the surface is enabled (wave 2). Two consumers: the UI (displayString,
/// @Observable) and ProxyForwarder's off-peak gate (isWindowOpen, cached —
/// NEVER a request-time availability call on the hot path).
@Observable
final class OffPeakAvailabilityMonitor: @unchecked Sendable {

    enum Status: Equatable, Sendable {
        case idle
        case open
        case closedUntil(Date)
        case unavailable(String)
    }

    /// Availability poll cadence. NOT OffPeakConfig.pollIntervalSeconds
    /// (5 s — the in-queue ticket status poll); this is the idle-window
    /// health poll. Bounded: no exponential growth, no polling when stopped.
    static let pollIntervalSeconds: TimeInterval = 300

    private let lock = NSLock()
    private var statusValue: Status = .idle
    private var pollTask: Task<Void, Never>?
    private let probe: @Sendable () async throws -> OffPeakAvailability
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    init(probe: @escaping @Sendable () async throws -> OffPeakAvailability,
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = OffPeakTarget.defaultSleep) {
        self.probe = probe
        self.sleep = sleep
    }

    var status: Status { lock.lock(); defer { lock.unlock() }; return statusValue }
    var isWindowOpen: Bool { if case .open = status { return true }; return false }

    var displayString: String {
        switch status {
        case .idle: return "Off"
        case .open: return "Window open"
        case .closedUntil(let date): return "Closed until \(date.formatted(date: .omitted, time: .shortened))"
        case .unavailable(let reason): return "Unavailable (\(reason))"
        }
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard pollTask == nil else { return }   // idempotent
        pollTask = Task { [probe, sleep] in
            await self.runLoop(probe: probe, sleep: sleep)
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        pollTask?.cancel()
        pollTask = nil
        statusValue = .idle
    }

    private func runLoop(probe: @Sendable () async throws -> OffPeakAvailability,
                         sleep: @Sendable (TimeInterval) async throws -> Void) async {
        while !Task.isCancelled {
            do {
                let availability = try await probe()
                if Task.isCancelled { return }
                if availability.canTake {
                    setStatus(.open)
                } else if let next = availability.nextTakeAtSeconds {
                    setStatus(.closedUntil(Date(timeIntervalSince1970: Double(next))))
                } else {
                    setStatus(.unavailable("availability false without next_take_at"))
                }
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                setStatus(.unavailable(String(describing: error)))
                // fail-open status: keep polling on the fixed cadence
            }
            do { try await sleep(Self.pollIntervalSeconds) } catch { return }
        }
    }

    private func setStatus(_ new: Status) {
        lock.lock(); defer { lock.unlock() }
        guard pollTask != nil else { return }   // stopped mid-flight: no zombie writes
        statusValue = new
    }
}

extension OffPeakAvailabilityMonitor: OffPeakAvailabilityMonitoring {}

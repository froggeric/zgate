import Foundation
import Testing
@testable import ZGate

/// Offline tests for `OffPeakAvailabilityMonitor` — the polled off-peak
/// window-status service (wave 2 Task 1). No network, no real timers: the
/// probe and sleep closures are injected, and the fake probe SUSPENDS while
/// its queue is empty so each test sequences results by awaiting observed
/// state (a returning-immediately probe plus the instant sleep would let the
/// loop consume the whole queue before the first assertion — the sequencing
/// would be timing luck, not order).
struct OffPeakAvailabilityMonitorTests {

    // MARK: - Fakes

    /// Sequenced probe results. `next()` suspends when empty and resumes on
    /// `enqueue`, which is what makes the step-by-step assertions below
    /// deterministic; `callCount` doubles as the idempotence probe (a second
    /// polling loop would show up as an extra call).
    private final class ProbeQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [Result<OffPeakAvailability, Error>] = []
        private var waiters: [CheckedContinuation<Result<OffPeakAvailability, Error>, Never>] = []
        private var calls = 0

        init(_ seed: [Result<OffPeakAvailability, Error>]) {
            pending = seed
        }

        var callCount: Int {
            lock.lock(); defer { lock.unlock() }
            return calls
        }

        func next() async throws -> OffPeakAvailability {
            let result = await withCheckedContinuation { cont in
                lock.lock(); defer { lock.unlock() }
                calls += 1
                if let first = pending.first {
                    pending.removeFirst()
                    cont.resume(returning: first)
                } else {
                    waiters.append(cont)
                }
            }
            return try result.get()
        }

        func enqueue(_ result: Result<OffPeakAvailability, Error>) {
            lock.lock(); defer { lock.unlock() }
            if let waiter = waiters.first {
                waiters.removeFirst()
                waiter.resume(returning: result)
            } else {
                pending.append(result)
            }
        }
    }

    /// Records requested delays and returns immediately — unless `parks`, in
    /// which case the sleep SUSPENDS until released or the task is cancelled
    /// (mirroring `Task.sleep`'s throw-on-cancel), so a test can stop the
    /// monitor genuinely mid-sleep.
    private final class SleepGate: @unchecked Sendable {
        private let lock = NSLock()
        private var delays: [TimeInterval] = []
        private let parks: Bool
        private var waiter: CheckedContinuation<Void, Error>?
        private var released = false

        init(parks: Bool = false) {
            self.parks = parks
        }

        var recordedDelays: [TimeInterval] {
            lock.lock(); defer { lock.unlock() }
            return delays
        }

        var isParked: Bool {
            lock.lock(); defer { lock.unlock() }
            return waiter != nil
        }

        func sleep(_ delay: TimeInterval) async throws {
            lock.lock()
            delays.append(delay)
            let park = parks && !released
            lock.unlock()
            guard park else { return }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { cont in
                    // Registration races cancellation the same way a real
                    // sleep does; the isCancelled check below only helps if
                    // cancel wins AFTER entry, so tests stop() strictly after
                    // isParked turns true.
                    let immediate: Result<Void, Error>? = lock.withLock {
                        if released { return .success(()) }
                        if Task.isCancelled { return .failure(CancellationError()) }
                        waiter = cont
                        return nil
                    }
                    if let immediate { cont.resume(with: immediate) }
                }
            } onCancel: {
                self.resumeWaiter(with: .failure(CancellationError()))
            }
        }

        /// Wakes a parked sleep normally; no-op when already woken.
        func release() {
            resumeWaiter(with: .success(()))
        }

        private func resumeWaiter(with result: Result<Void, Error>) {
            lock.lock()
            let cont = waiter
            waiter = nil
            lock.unlock()
            cont?.resume(with: result)
        }
    }

    // MARK: - Helpers

    /// Bounded poll-wait: returns true once the condition holds, false after
    /// ~3 s. Sequencing relies on the condition, never on wall-clock delays.
    private func waitFor(_ condition: @autoclosure () -> Bool) async -> Bool {
        for _ in 0..<600 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    // MARK: - Tests

    @Test("open then closedUntil statuses surface and poll cadence is 300s")
    func statusesAndCadence() async {
        let gate = SleepGate()
        let queue = ProbeQueue([
            .success(OffPeakAvailability(canTake: true, nextTakeAtSeconds: nil)),
        ])
        let monitor = OffPeakAvailabilityMonitor(
            probe: { try await queue.next() },
            sleep: { try await gate.sleep($0) })

        monitor.start()
        #expect(await waitFor(monitor.displayString == "Window open"))
        #expect(monitor.isWindowOpen == true)

        queue.enqueue(.success(OffPeakAvailability(canTake: false, nextTakeAtSeconds: 1_764_000_000)))
        #expect(await waitFor(monitor.displayString.hasPrefix("Closed until ")))
        #expect(monitor.isWindowOpen == false)

        // Fixed idle-window cadence, not the 5 s in-queue ticket poll.
        #expect(!gate.recordedDelays.isEmpty)
        #expect(gate.recordedDelays.allSatisfy { $0 == OffPeakAvailabilityMonitor.pollIntervalSeconds })

        monitor.stop()
        #expect(monitor.displayString == "Off")
        #expect(monitor.isWindowOpen == false)
    }

    @Test("probe error becomes unavailable and polling continues")
    func failOpenStatus() async {
        let gate = SleepGate()
        let queue = ProbeQueue([
            .failure(URLError(.timedOut)),
        ])
        let monitor = OffPeakAvailabilityMonitor(
            probe: { try await queue.next() },
            sleep: { try await gate.sleep($0) })

        monitor.start()
        #expect(await waitFor(monitor.displayString.hasPrefix("Unavailable (")))
        #expect(monitor.isWindowOpen == false)

        // Fail-open status: the error did not stop the loop — the next poll
        // still runs and recovers to open.
        queue.enqueue(.success(OffPeakAvailability(canTake: true, nextTakeAtSeconds: nil)))
        #expect(await waitFor(monitor.displayString == "Window open"))
        #expect(monitor.isWindowOpen == true)

        monitor.stop()
        #expect(monitor.displayString == "Off")
    }

    @Test("start is idempotent and stop during sleep exits cleanly")
    func startStopLifecycle() async {
        let gate = SleepGate(parks: true)
        let queue = ProbeQueue([
            .success(OffPeakAvailability(canTake: true, nextTakeAtSeconds: nil)),
        ])
        let monitor = OffPeakAvailabilityMonitor(
            probe: { try await queue.next() },
            sleep: { try await gate.sleep($0) })

        monitor.start()
        monitor.start()
        #expect(await waitFor(monitor.displayString == "Window open"))
        #expect(await waitFor(gate.isParked))
        // Exactly one loop despite the double start; a second loop would have
        // consumed a second probe result by now.
        #expect(queue.callCount == 1)

        // Stop while the loop is suspended in its inter-poll sleep: cancel
        // must wake the sleep (like Task.sleep) and no zombie write may land.
        monitor.stop()
        #expect(monitor.displayString == "Off")
        #expect(monitor.isWindowOpen == false)

        gate.release()
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(monitor.displayString == "Off")
        #expect(monitor.isWindowOpen == false)
        #expect(queue.callCount == 1)
    }
}

import Foundation
import Testing
@testable import ZGate

/// ProxyServer monitor wiring (off-peak wave 2 Task 5): the availability
/// monitor's lifecycle rides the live off-peak toggle — enabling via
/// `updateRouting` (the Settings save path) starts polling without a
/// restart, disabling stops it, and `stop()` tears it down with the
/// per-start context so the next `start` rebuilds it. The probe and sleep
/// are injected through the `offPeakProbeOverride` / `offPeakSleepOverride`
/// seams (mirrors `quotaProvider`): no network, and the 30 ms sleep makes
/// the poll tick fast enough that a frozen call count across ~8 ticks is a
/// direct proof the loop died — never a real 300 s wait.
@MainActor
struct OffPeakMonitorWiringTests {

    // MARK: - Fakes

    /// Thread-safe counting probe: every call answers a fixed open window.
    private final class CountingProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0

        func call() async throws -> OffPeakAvailability {
            lock.lock()
            calls += 1
            lock.unlock()
            return OffPeakAvailability(canTake: true, nextTakeAtSeconds: nil)
        }

        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return calls
        }
    }

    // MARK: - Helpers

    /// Bounded poll-wait (~3 s): returns true once the condition holds.
    private func waitFor(_ condition: @autoclosure () -> Bool) async -> Bool {
        for _ in 0..<600 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    private func makeConfig(enabled: Bool) -> AppConfig {
        AppConfig(
            clients: [ClientConfig(
                clientName: "Claude Code", port: 0,
                defaultUpstream: "https://api.anthropic.com")],
            offPeak: OffPeakConfig(enabled: enabled))
    }

    // MARK: - Tests

    @Test("live toggle starts and stops polling without a restart")
    func liveToggleStartsAndStopsPollingWithoutRestart() async throws {
        let probe = CountingProbe()
        let server = ProxyServer(tokenStatsStore: TokenStatsStore())
        server.offPeakProbeOverride = { try await probe.call() }
        server.offPeakSleepOverride = { _ in
            try await Task.sleep(nanoseconds: 30_000_000)
        }

        // Disabled at start: no monitor, no polls.
        let config = makeConfig(enabled: false)
        await server.start(config: config)
        #expect(server.offPeakMonitor == nil)
        #expect(probe.count == 0)

        // Enable live (Settings save → updateRouting): monitor built and
        // polling, status leaves .idle — no restart.
        config.offPeak.enabled = true
        server.updateRouting(config: config)
        let monitor = try #require(server.offPeakMonitor)
        #expect(await waitFor(probe.count >= 1))
        #expect(await waitFor(monitor.status != OffPeakAvailabilityMonitor.Status.idle))
        #expect(monitor.isWindowOpen == true)

        // Disable live: stopped in place (status back to .idle — only
        // stop() resets it) and the call count freezes across ~8 ticks of
        // the injected 30 ms cadence.
        config.offPeak.enabled = false
        server.updateRouting(config: config)
        #expect(monitor.status == OffPeakAvailabilityMonitor.Status.idle)
        let frozen = probe.count
        try? await Task.sleep(nanoseconds: 250_000_000)
        #expect(probe.count == frozen)
        #expect(server.offPeakMonitor === monitor)  // stopped, not discarded

        // Re-enable: the SAME instance resumes polling (idempotent start).
        config.offPeak.enabled = true
        server.updateRouting(config: config)
        #expect(server.offPeakMonitor === monitor)
        #expect(await waitFor(probe.count > frozen))

        await server.stop()
    }

    @Test("stop tears the monitor down; restart with the surface on rebuilds it")
    func monitorDiesWithStopAndRebuildsOnRestart() async throws {
        let probe = CountingProbe()
        let server = ProxyServer(tokenStatsStore: TokenStatsStore())
        server.offPeakProbeOverride = { try await probe.call() }
        server.offPeakSleepOverride = { _ in
            try await Task.sleep(nanoseconds: 30_000_000)
        }

        // Enabled at start: the monitor is built in start() and polls.
        let config = makeConfig(enabled: true)
        await server.start(config: config)
        let firstMonitor = try #require(server.offPeakMonitor)
        #expect(await waitFor(firstMonitor.status != OffPeakAvailabilityMonitor.Status.idle))

        // stop() nils the monitor with the per-start context — the poll
        // task died with the stop, so no further polls land.
        await server.stop()
        #expect(server.offPeakMonitor == nil)
        #expect(server.offPeakContext == nil)
        let frozen = probe.count
        try? await Task.sleep(nanoseconds: 250_000_000)
        #expect(probe.count == frozen)

        // Restart with the surface still enabled: a NEW monitor (fresh
        // probe capture over the new context) polls again.
        await server.start(config: config)
        let secondMonitor = try #require(server.offPeakMonitor)
        #expect(secondMonitor !== firstMonitor)
        #expect(await waitFor(probe.count > frozen))
        #expect(await waitFor(secondMonitor.status != OffPeakAvailabilityMonitor.Status.idle))

        await server.stop()
        #expect(server.offPeakMonitor == nil)
    }
}

import SwiftUI

// MARK: - Display state (Task 9, testable)

/// The popover/menu-bar quota readout. Disambiguates the two degraded
/// states the Task 8 review pinned:
/// - `noData` — no snapshot was ever observed (nil fraction from the
///   billing poll, today's live truth until the balance endpoint is
///   cracked). Rendered as a deliberate empty state, NEVER a 0% bar and
///   never labeled "stale".
/// - `available(stale:)` — a last-known fraction exists; `stale` means the
///   last poll attempt failed, so the bar dims but keeps its value.
enum QuotaDisplayState: Equatable, Sendable {
    case noData
    case available(fraction: Double, stale: Bool)

    /// State selection from the service seams: nil snapshot always wins —
    /// staleness only qualifies data that exists.
    static func make(snapshot: QuotaSnapshot?, stale: Bool) -> QuotaDisplayState {
        guard let snapshot else { return .noData }
        return .available(fraction: min(max(snapshot.fractionRemaining, 0), 1), stale: stale)
    }

    var fraction: Double? {
        if case let .available(fraction, _) = self { return fraction }
        return nil
    }

    var isStale: Bool {
        if case let .available(_, stale) = self { return stale }
        return false
    }

    /// "63%" — whole percents; no-data has no text.
    var percentText: String? {
        fraction.map { "\(Int((($0) * 100).rounded()))%" }
    }

    /// Menu-bar title, spec §6 "ZΓ 63%" style. No data renders the bare
    /// mark so the item stays legible without implying an empty quota.
    var menuBarTitle: String {
        guard let percentText else { return "ZΓ" }
        return "ZΓ \(percentText)"
    }
}

/// Bar tint token derived from the Task 8 level bands (gold ≤ 25%,
/// red ≤ 10%). A token, not a `Color`, so the mapping is unit-testable
/// without Color equality; the view resolves the token to a tint.
enum QuotaBarTint: Equatable, Sendable {
    case normal
    case warning
    case critical

    static func tint(forFraction fraction: Double) -> QuotaBarTint {
        switch QuotaLevel.level(forFraction: fraction) {
        case .critical: return .critical
        case .warning: return .warning
        case .normal: return .normal
        }
    }

    var color: Color {
        switch self {
        case .normal: return .green
        case .warning: return .yellow
        case .critical: return .red
        }
    }
}

// MARK: - View model

/// Bridges the quota seams to SwiftUI. `QuotaService` is not observable
/// (thread-safe class with its own lock), so the model re-reads the seams
/// on a slow tick plus every observable nudge (popover appear, quota
/// events, manual refresh) and publishes one `QuotaDisplayState`.
/// Demo seeding (debug menu) overrides the read for the popover smoke.
@MainActor
@Observable
final class QuotaStatusModel {

    /// Poll the seams this often while the model is running (well under the
    /// 30 min poll cadence; cheap — two lock-guarded reads).
    static let refreshTick: TimeInterval = 60

    private let snapshot: () -> QuotaSnapshot?
    private let stale: () -> Bool
    private let refreshService: (() async -> Void)?
    private var ticker: Task<Void, Never>?

    /// Last observed snapshot time (for the "as of" caption); nil = never.
    private(set) var fetchedAt: Date?
    private(set) var state: QuotaDisplayState = .noData
    private var demoState: QuotaDisplayState?

    init(
        snapshot: @escaping () -> QuotaSnapshot?,
        stale: @escaping () -> Bool = { false },
        refreshService: (() async -> Void)? = nil
    ) {
        self.snapshot = snapshot
        self.stale = stale
        self.refreshService = refreshService
    }

    /// Model over the proxy's seams. `ProxyServer.quotaProvider` holds the
    /// concrete `QuotaService` whenever a relay vendor is configured (wired
    /// on first start); the cast exposes staleness + manual refresh without
    /// widening the router-facing `QuotaSnapshotProviding` protocol.
    static func live(_ proxyServer: ProxyServer) -> QuotaStatusModel {
        QuotaStatusModel(
            snapshot: { proxyServer.quotaProvider?.quotaSnapshot() },
            stale: { (proxyServer.quotaProvider as? QuotaService)?.isStale ?? false },
            refreshService: { [weak proxyServer] in
                if let service = proxyServer?.quotaProvider as? QuotaService {
                    await service.pollNow()
                }
            })
    }

    /// Starts the background re-read tick. Idempotent; cheap enough to run
    /// for the process lifetime (the menu-bar title needs it even while the
    /// popover is closed). The loop holds the model weakly and exits once
    /// the model is gone, so no deinit/cancel hop is needed.
    func start() {
        recompute()
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.refreshTick))
                guard let self else { return }
                await self.recompute()
            }
        }
    }

    /// Re-read the seams (nudged by appear/quota events). Demo override wins.
    func recompute() {
        if let demoState {
            state = demoState
            return
        }
        let snapshot = snapshot()
        state = QuotaDisplayState.make(snapshot: snapshot, stale: stale())
        fetchedAt = snapshot?.fetchedAt
    }

    /// Manual refresh button: poll now, then re-read.
    func refreshNow() async {
        await refreshService?()
        recompute()
    }

    /// True when a concrete poll target exists (hides the refresh button's
    /// spinner path when no relay vendor/quota service is configured).
    var canRefresh: Bool { refreshService != nil }

    // MARK: Demo seeding (debug)

    /// Seeds a fake healthy readout for the popover smoke (debug menu).
    /// Cleared by `clearDemo` or the next app launch.
    func seedDemo(fraction: Double) {
        demoState = .available(fraction: fraction, stale: false)
        fetchedAt = Date()
        recompute()
    }

    func clearDemo() {
        demoState = nil
        recompute()
    }

    var isDemoSeeded: Bool { demoState != nil }
}

// MARK: - Bar view

/// Quota bar + percent + "as of" caption. The three states are visually
/// distinct by design: fresh value (colored bar), stale value (dimmed bar,
/// still the real number), no data (empty track + explanatory caption —
/// the common path today, so it reads deliberate, not broken).
struct QuotaBarView: View {
    let state: QuotaDisplayState
    var fetchedAt: Date?
    /// Compact variant for the Settings quota tab (adds the caption row).
    var showsCaption: Bool = false

    var body: some View {
        switch state {
        case .noData:
            noDataView
        case let .available(fraction, stale):
            barView(fraction: fraction, stale: stale)
        }
    }

    private var noDataView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.0percent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Quota data unavailable")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("routing unaffected")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text("The billing endpoint returns no balance for this account yet, so no quota percentage is shown. Proxying and usage-based routing keep working.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Quota data unavailable; proxying unaffected")
    }

    private func barView(fraction: Double, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(state.percentText ?? "")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(stale ? .secondary : QuotaBarTint.tint(forFraction: fraction).color)
                if stale {
                    Text("last known")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if showsCaption, let fetchedAt {
                    Text("as of \(Self.timeFormatter.string(from: fetchedAt))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.18))
                    Capsule()
                        .fill(QuotaBarTint.tint(forFraction: fraction).color)
                        .opacity(stale ? 0.35 : 1)
                        .frame(width: max(proxy.size.width * fraction, 4))
                }
            }
            .frame(height: 6)
            .opacity(stale ? 0.6 : 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(stale
            ? "Quota \(state.percentText ?? ""), last known, poll failing"
            : "Quota \(state.percentText ?? "")")
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

import AppKit

// MARK: - Ring spec (testable)
//
// The menu-bar mark: a template ring gauge whose arc sweep is the
// remaining weekly quota. Drawn as black + alpha only so the system can
// tint it for light/dark menu bars (HIG the-menu-bar.md › Menu bar extras:
// "interface icons and symbols use black and clear colors to define their
// shapes; the system can apply other colors to the black areas").

/// Pure geometry/constants for the quota ring; the drawing below is a
/// mechanical execution of these values so tests can pin them.
enum QuotaRingSpec {
    static let canvas: CGFloat = 18
    static let diameter: CGFloat = 13
    static let lineWidth: CGFloat = 2
    /// Full-circle reference track.
    static let trackAlpha: CGFloat = 0.25
    /// Last-known (stale) arc dimming — dimmer than fresh (1.0) but well
    /// above the track: in a template image alpha is the ONLY channel, and
    /// a 0.35 arc over a 0.25 track reads as a dim full ring rather than
    /// "a real fraction, last known" (pixel-measured; the popover bars can
    /// dim harder because they also carry hue).
    static let staleArcAlpha: CGFloat = 0.55
    /// No snapshot ever observed: a dashed ring reads "not yet measured",
    /// never a 0% arc (QuotaDisplayState.noData pins the same distinction).
    static let noDataDash: [CGFloat] = [2, 2.2]
    static let noDataAlpha: CGFloat = 0.35
    /// Smallest inked sweep: 0% still shows a round-cap dot at 12 o'clock
    /// (4° is a ~3 px dot at 18 pt — perceptible but unmistakably "empty").
    static let minimumSweepDegrees: CGFloat = 4

    /// Arc sweep for a fraction, clamped into 0...1. A full fraction draws
    /// the complete circle (360°) so the round caps don't overlap.
    static func sweepDegrees(forFraction fraction: Double) -> CGFloat {
        let clamped = min(max(fraction, 0), 1)
        if clamped >= 0.999 { return 360 }
        return max(CGFloat(clamped) * 360, minimumSweepDegrees)
    }
}

// MARK: - Icon drawing

/// Draws the menu-bar template image. `weeklyFraction == nil` is the
/// no-data state (dashed ring); `stale` dims the arc to the shared
/// last-known constant. Callers re-render whenever the quota state
/// changes; the image is vector-recorded, so it stays crisp at any
/// backing store.
enum QuotaMenuBarIcon {
    static func image(weeklyFraction: Double?, stale: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: QuotaRingSpec.canvas, height: QuotaRingSpec.canvas))
        image.lockFocus()

        let rect = NSRect(
            x: (QuotaRingSpec.canvas - QuotaRingSpec.diameter) / 2,
            y: (QuotaRingSpec.canvas - QuotaRingSpec.diameter) / 2,
            width: QuotaRingSpec.diameter,
            height: QuotaRingSpec.diameter)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2

        if let fraction = weeklyFraction {
            // Track: full circle at low alpha.
            NSColor.black.withAlphaComponent(QuotaRingSpec.trackAlpha).setStroke()
            let track = NSBezierPath(ovalIn: rect)
            track.lineWidth = QuotaRingSpec.lineWidth
            track.stroke()

            // Value arc: clockwise from 12 o'clock. AppKit angles are
            // degrees counterclockwise from +x, so 90° is 12 o'clock and a
            // DECREASING end angle sweeps clockwise (through 3 o'clock).
            let alpha = stale ? QuotaRingSpec.staleArcAlpha : 1
            NSColor.black.withAlphaComponent(alpha).setStroke()
            let sweep = QuotaRingSpec.sweepDegrees(forFraction: fraction)
            let arc = NSBezierPath()
            arc.appendArc(
                withCenter: center, radius: radius,
                startAngle: 90, endAngle: 90 - Double(sweep), clockwise: true)
            arc.lineWidth = QuotaRingSpec.lineWidth
            arc.lineCapStyle = .round
            arc.stroke()
        } else {
            // No data: dashed ring, no arc.
            NSColor.black.withAlphaComponent(QuotaRingSpec.noDataAlpha).setStroke()
            let dashed = NSBezierPath(ovalIn: rect)
            dashed.lineWidth = QuotaRingSpec.lineWidth
            dashed.setLineDash(QuotaRingSpec.noDataDash, count: QuotaRingSpec.noDataDash.count, phase: 0)
            dashed.stroke()
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

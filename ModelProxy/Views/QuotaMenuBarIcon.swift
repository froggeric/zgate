import AppKit

// MARK: - Ring spec (testable)
//
// The menu-bar mark: a template ring gauge whose arc sweep is the
// remaining weekly quota, with the "ZΓ" brand mark drawn inside the ring.
// The mark rides every ring state (live arc, stale dimming, dashed
// no-data) and disappears with the ring whenever a fault symbol replaces
// the icon. Drawn as black + alpha only so the system can tint it for
// light/dark menu bars (HIG the-menu-bar.md › Menu bar extras:
// "interface icons and symbols use black and clear colors to define their
// shapes; the system can apply other colors to the black areas").

/// Pure geometry/constants for the quota ring; the drawing below is a
/// mechanical execution of these values so tests can pin them.
enum QuotaRingSpec {
    static let canvas: CGFloat = 18
    /// Raster oversampling for the composed icon (72 px at the 18 pt
    /// canvas): crisp on 1x/2x/3x menu bars, cheap to render.
    static let renderScale: CGFloat = 4
    /// Ring outer diameter — sized to host the ZΓ mark inside with ~1.5 pt
    /// clear margin per side (13.25 pt clear interior at lineWidth 1.75).
    static let diameter: CGFloat = 15
    static let lineWidth: CGFloat = 1.75
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

    // MARK: Update badge (spec §5)

    /// Update badge (spec §5): filled dot at the top-right of the ring.
    static let badgeRadius: CGFloat = 2.1
    static let badgeOffset: CGFloat = 3.4   // center offset toward the corner
    static let badgeAlpha: CGFloat = 0.95

    /// Arc sweep for a fraction, clamped into 0...1. A full fraction draws
    /// the complete circle (360°) so the round caps don't overlap.
    static func sweepDegrees(forFraction fraction: Double) -> CGFloat {
        let clamped = min(max(fraction, 0), 1)
        if clamped >= 0.999 { return 360 }
        return max(CGFloat(clamped) * 360, minimumSweepDegrees)
    }

    // MARK: Brand mark (ZΓ inside the ring)

    /// The brand mark — same glyph pair as the app icon.
    static let markText = "ZΓ"
    /// Preferred point size for the mark before auto-fit clamping.
    static let markBaseFontSize: CGFloat = 8
    /// Auto-fit box, as fractions of the ring's clear interior
    /// (diameter − lineWidth): the mark may fill at most 85% of the width
    /// and 60% of the cap height, keeping breathing room from the stroke.
    static let markMaxWidthRatio: CGFloat = 0.85
    static let markMaxCapRatio: CGFloat = 0.6

    /// Auto-fit: scale `markBaseFontSize` down (never up) so a mark
    /// measured AT the base size fits its box. Pure so tests can pin the
    /// clamping without a live font.
    static func fittedMarkFontSize(measuredWidth: CGFloat, measuredCapHeight: CGFloat) -> CGFloat {
        let clearSpan = diameter - lineWidth
        let widthScale = markMaxWidthRatio * clearSpan / max(measuredWidth, 0.01)
        let capScale = markMaxCapRatio * clearSpan / max(measuredCapHeight, 0.01)
        return markBaseFontSize * min(1, widthScale, capScale)
    }
}

// MARK: - Icon drawing

/// Draws the menu-bar template image. `weeklyFraction == nil` is the
/// no-data state (dashed ring); `stale` dims the arc to the shared
/// last-known constant; `updateAvailable` inks the spec §5 badge dot on
/// the ring's top-right (ring states only — fault symbols replace the
/// whole icon and outrank it). Callers re-render whenever the quota or
/// update state changes. Rendering is a deterministic high-resolution
/// raster (NSBitmapImageRep at `renderScale`, declared point size
/// `canvas`) — crisp at every menu-bar backing store, no deprecated
/// lockFocus, and pixel-exact for tests.
enum QuotaMenuBarIcon {
    static func image(weeklyFraction: Double?, stale: Bool, updateAvailable: Bool = false) -> NSImage {
        let pointSize = NSSize(width: QuotaRingSpec.canvas, height: QuotaRingSpec.canvas)
        let pixels = Int(QuotaRingSpec.canvas * QuotaRingSpec.renderScale)
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else {
            // Environment failure (no bitmap contexts at all): an empty
            // template image beats a crash in the menu bar.
            let image = NSImage(size: pointSize)
            image.isTemplate = true
            return image
        }
        // The context's scale is captured from rep.size at creation — set
        // the point size FIRST or the drawing lands 1:1 in the corner.
        rep.size = pointSize
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            let image = NSImage(size: pointSize)
            image.isTemplate = true
            return image
        }

        let rect = NSRect(
            x: (QuotaRingSpec.canvas - QuotaRingSpec.diameter) / 2,
            y: (QuotaRingSpec.canvas - QuotaRingSpec.diameter) / 2,
            width: QuotaRingSpec.diameter,
            height: QuotaRingSpec.diameter)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

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

        // Brand mark inside the ring, sharing the state's alpha so ring +
        // mark read as one composed icon (fresh 1.0, stale dimmed, no-data
        // dimmest). Fault symbols replace the whole image, mark included.
        let markAlpha: CGFloat
        if weeklyFraction != nil {
            markAlpha = stale ? QuotaRingSpec.staleArcAlpha : 1
        } else {
            markAlpha = QuotaRingSpec.noDataAlpha
        }
        drawMark(in: rect, alpha: markAlpha)

        // Update badge (spec §5): a filled dot at the ring's top-right,
        // drawn on every ring state (arc, stale, no-data) but only ever
        // on the ring — a fault symbol replaces the whole icon and always
        // outranks the badge (the caller gates on menuBarSymbol == nil).
        // Black + alpha like everything else, so it stays template-safe.
        if updateAvailable {
            let center = NSPoint(
                x: rect.midX + QuotaRingSpec.badgeOffset,
                y: rect.midY + QuotaRingSpec.badgeOffset)
            NSColor.black.withAlphaComponent(QuotaRingSpec.badgeAlpha).setFill()
            NSBezierPath(ovalIn: NSRect(
                x: center.x - QuotaRingSpec.badgeRadius, y: center.y - QuotaRingSpec.badgeRadius,
                width: QuotaRingSpec.badgeRadius * 2, height: QuotaRingSpec.badgeRadius * 2)).fill()
        }

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: pointSize)
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }

    /// Draws the ZΓ mark centered on its INK inside the ring's clear
    /// interior. `draw(at:)` anchors the line box's bottom-left corner
    /// (verified empirically), so the anchor drops one descender below the
    /// intended baseline; `baseline = midY − capHeight/2` then centers the
    /// cap box — both glyphs are caps, no descenders — while horizontal
    /// centering uses the tight device-metrics ink box (advance width
    /// carries bearings the eye doesn't). Auto-fit borrows the app-icon
    /// generator's recipe: measure at the base size, clamp into the fit
    /// box, draw on the 0.5 pt grid so 1x stays crisp.
    private static func drawMark(in rect: NSRect, alpha: CGFloat) {
        let baseFont = NSFont.boldSystemFont(ofSize: QuotaRingSpec.markBaseFontSize)
        let baseSize = (QuotaRingSpec.markText as NSString).size(
            withAttributes: [.font: baseFont])
        let fontSize = QuotaRingSpec.fittedMarkFontSize(
            measuredWidth: baseSize.width,
            measuredCapHeight: baseFont.capHeight)
        let font = NSFont.boldSystemFont(ofSize: fontSize)
        let attributed = NSAttributedString(string: QuotaRingSpec.markText, attributes: [
            .font: font,
            .foregroundColor: NSColor.black.withAlphaComponent(alpha),
        ])
        let ink = attributed.boundingRect(
            with: NSSize(width: QuotaRingSpec.canvas * 2, height: QuotaRingSpec.canvas * 2),
            options: [.usesLineFragmentOrigin, .usesDeviceMetrics])
        let x = ((rect.midX - ink.width / 2 - ink.origin.x) * 2).rounded() / 2
        let baseline = ((rect.midY - font.capHeight / 2) * 2).rounded() / 2
        // draw(at:) anchors the line box's BOTTOM-left corner (verified
        // empirically), which floats the glyphs |descender| above the
        // intended baseline — drop the anchor point accordingly.
        attributed.draw(at: NSPoint(x: x, y: baseline + font.descender))
    }
}

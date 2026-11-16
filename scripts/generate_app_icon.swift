// Generates the ZGate "ZΓ" app-icon PNGs into the AppIcon.appiconset.
// Pure CoreGraphics/CoreText — no external assets. Rerun after changing the
// design; keep Contents.json filenames in sync (or leave them untouched —
// the manifest below mirrors the committed one).
//
// Usage:
//   swift scripts/generate_app_icon.swift ModelProxy/Assets.xcassets/AppIcon.appiconset
//
// Design: white bold SF Pro "ZΓ", auto-fit to 62% width / 52% cap height,
// on a rounded-square indigo gradient (22.37% corners — the macOS squircle
// ratio), hairline border, drop shadow from 64px up.
import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "ModelProxy/Assets.xcassets/AppIcon.appiconset")

// Manifest entries: (filename, pixel size)
let entries: [(String, Int)] = [
    ("zgate-16x16@1x.png", 16),
    ("zgate-16x16@2x.png", 32),
    ("zgate-32x32@1x.png", 32),
    ("zgate-32x32@2x.png", 64),
    ("zgate-128x128@1x.png", 128),
    ("zgate-128x128@2x.png", 256),
    ("zgate-256x256@1x.png", 256),
    ("zgate-256x256@2x.png", 512),
    ("zgate-512x512@1x.png", 512),
    ("zgate-1024x1024@1x.png", 1024),
]

let glyphText = "ZΓ" as NSString

func render(size: Int) -> CGImage? {
    let s = CGFloat(size)
    guard let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    // macOS-style rounded-square background, vertical indigo gradient.
    let radius = s * 0.2237
    let rect = CGRect(x: 0, y: 0, width: s, height: s)
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [
        CGColor(red: 0.216, green: 0.322, blue: 0.553, alpha: 1),
        CGColor(red: 0.071, green: 0.102, blue: 0.184, alpha: 1),
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: s / 2, y: s), end: CGPoint(x: s / 2, y: 0), options: [])
    ctx.restoreGState()

    // Hairline border for definition against light and dark backdrops.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
    ctx.setLineWidth(max(1, s * 0.012))
    ctx.strokePath()
    ctx.restoreGState()

    // Auto-fit "ZΓ" white bold, centered on cap height.
    func makeLine(fontSize: CGFloat) -> CTLine {
        let font = NSFont.boldSystemFont(ofSize: fontSize)
        let attr = NSAttributedString(
            string: glyphText as String,
            attributes: [.font: font, .foregroundColor: NSColor.white])
        return CTLineCreateWithAttributedString(attr)
    }

    var fontSize = s * 0.5
    var line = makeLine(fontSize: fontSize)
    var ascent = CGFloat(0), descent = CGFloat(0), leading = CGFloat(0)
    var width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
    let maxTextWidth = s * 0.62
    let capHeight = (NSFont.boldSystemFont(ofSize: fontSize).capHeight)
    let maxTextHeight = s * 0.52
    let scale = min(maxTextWidth / width, maxTextHeight / capHeight)
    fontSize *= scale
    line = makeLine(fontSize: fontSize)
    width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
    let cap = NSFont.boldSystemFont(ofSize: fontSize).capHeight

    let textX = (s - width) / 2
    let baselineY = (s - cap) / 2

    ctx.saveGState()
    if size >= 64 {  // shadow reads as noise below this
        ctx.setShadow(
            offset: CGSize(width: 0, height: -s * 0.015), blur: s * 0.03,
            color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
    }
    ctx.textPosition = CGPoint(x: textX, y: baselineY)
    CTLineDraw(line, ctx)
    ctx.restoreGState()

    return ctx.makeImage()
}

for (name, size) in entries {
    guard let image = render(size: size) else {
        FileHandle.standardError.write("FAILED \(name)\n".data(using: .utf8)!)
        exit(1)
    }
    let url = outDir.appendingPathComponent(name)
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else {
        FileHandle.standardError.write("DEST FAILED \(name)\n".data(using: .utf8)!)
        exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(url.path) (\(size)x\(size))")
}

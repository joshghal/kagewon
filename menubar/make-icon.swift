import AppKit

// Draws the Kagewon app icon at every size macOS needs. Usage: make-icon <output .iconset folder>
// The mark is a ring (the circle, 원) with a vermilion disc offset inside it (the shadow, 影), on deep indigo.

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)

    // the rounded square, inset the way macOS icons are
    let inset = s * 0.09
    let card = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: card, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.20, blue: 0.40, alpha: 1), NSColor(srgbRed: 0.07, green: 0.09, blue: 0.22, alpha: 1)])!
        .draw(in: shape, angle: -90)

    // the ring: an open brush circle, thicker at the start like an ensō
    let center = NSPoint(x: s / 2, y: s / 2)
    let radius = s * 0.265
    let ring = NSBezierPath()
    ring.appendArc(withCenter: center, radius: radius, startAngle: 62, endAngle: 62 + 322, clockwise: false)
    ring.lineWidth = s * 0.05
    ring.lineCapStyle = .round
    NSColor(srgbRed: 0.96, green: 0.93, blue: 0.86, alpha: 1).setStroke()
    ring.stroke()

    // the shadow: a vermilion disc, offset down and to the right
    let disc = NSBezierPath(ovalIn: NSRect(x: center.x - s * 0.105 + s * 0.045, y: center.y - s * 0.105 - s * 0.05, width: s * 0.21, height: s * 0.21))
    NSColor(srgbRed: 0.93, green: 0.36, blue: 0.27, alpha: 1).setFill()
    disc.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count == 2 else { print("usage: make-icon <folder.iconset>"); exit(1) }
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let sizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes { try render(px).write(to: dir.appendingPathComponent(name + ".png")) }

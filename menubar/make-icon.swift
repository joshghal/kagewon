import AppKit

// Draws the Kagewon app icon at every size macOS needs. Usage: make-icon <output .iconset folder>
// The mark is a globe (the circle, 원, and the network) with its vermilion shadow (影) falling beside it, on deep indigo.
// The same drawing, in the same proportions, is in docs/logo.svg.

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

    // The drawing is laid out on a 112 unit card (see docs/logo.svg); k turns those units into pixels and pt flips y.
    let k = (s - 2 * inset) / 112
    func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: inset + (x - 8) * k, y: s - (inset + (y - 8) * k)) }
    func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> NSBezierPath {
        let c = pt(x, y)
        return NSBezierPath(ovalIn: NSRect(x: c.x - r * k, y: c.y - r * k, width: 2 * r * k, height: 2 * r * k))
    }
    let cream = NSColor(srgbRed: 0.96, green: 0.93, blue: 0.86, alpha: 1)

    // the shadow: a vermilion disc falling down and to the right, with a clear gap kept around the globe
    let everything = NSBezierPath(rect: NSRect(x: 0, y: 0, width: s, height: s))
    everything.append(circle(57.5, 57.5, 37))
    everything.windingRule = .evenOdd
    NSGraphicsContext.saveGraphicsState()
    everything.addClip()
    NSColor(srgbRed: 0.93, green: 0.36, blue: 0.27, alpha: 1).setFill()
    circle(72, 72, 33).fill()
    NSGraphicsContext.restoreGraphicsState()

    // the globe: a cream outline, one meridian, the equator, and two parallels
    cream.setStroke()
    func stroke(_ path: NSBezierPath) { path.lineWidth = 3.6 * k; path.lineCapStyle = .round; path.stroke() }
    stroke(circle(57.5, 57.5, 33))
    let centre = pt(57.5, 57.5)
    stroke(NSBezierPath(ovalIn: NSRect(x: centre.x - 14 * k, y: centre.y - 33 * k, width: 28 * k, height: 66 * k)))
    for (y, half) in [(57.5, 33.0), (39.5, 26.0), (75.5, 26.0)] as [(CGFloat, CGFloat)] {
        let line = NSBezierPath()
        line.move(to: pt(57.5 - half, y))
        line.line(to: pt(57.5 + half, y))
        stroke(line)
    }

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

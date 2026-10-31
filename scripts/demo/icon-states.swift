import AppKit

// Draws the menu bar icon in each of its states, on a dark and a light bar, with the real drawing code (Glyph.swift).
// Usage: icon-states <output png>
let states: [(String, Phase)] = [("Off", .off), ("Connecting", .starting), ("On", .on), ("Error", .error("x"))]
let scale: CGFloat = 8, cell: CGFloat = 170, rowHeight: CGFloat = 190
let width = Int(cell) * states.count + 40, height = Int(rowHeight) * 2 + 40
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(srgbRed: 0.96, green: 0.94, blue: 0.90, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()

func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    NSImage(size: image.size, flipped: false) { rect in
        image.draw(in: rect)
        color.set(); rect.fill(using: .sourceIn)
        return true
    }
}
for (row, (bar, ink)) in [(NSColor(white: 0.16, alpha: 1), NSColor.white), (NSColor(white: 0.90, alpha: 1), NSColor.black)].enumerated() {
    let y = CGFloat(height) - 20 - CGFloat(row + 1) * rowHeight + 10
    bar.setFill(); NSBezierPath(roundedRect: NSRect(x: 20, y: y, width: CGFloat(width) - 40, height: rowHeight - 20), xRadius: 12, yRadius: 12).fill()
    for (i, (name, phase)) in states.enumerated() {
        let x = 20 + CGFloat(i) * cell + (cell - 18 * scale) / 2
        tinted(menuBarGlyph(for: phase, spin: 0), ink).draw(in: NSRect(x: x, y: y + 34, width: 18 * scale, height: 18 * scale))
        (name as NSString).draw(at: NSPoint(x: 20 + CGFloat(i) * cell + cell / 2 - CGFloat(name.count) * 4.2, y: y + 8),
                                withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: ink])
    }
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

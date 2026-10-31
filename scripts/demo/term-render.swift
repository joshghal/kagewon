import AppKit

// Draws a terminal-style window from text, for the demonstration. The text is the real output of the real commands.
// Usage: term-render <output png> <screen text file>   (lines starting with "$ " are prompts)
let args = CommandLine.arguments
guard args.count == 3 else { print("usage: term-render <png> <text>"); exit(1) }
let maxColumns = 77
func wrapped(_ line: String) -> [String] { // a real terminal breaks a long line at its width; the break is shown with an indent
    var rest = Substring(line), out: [String] = []
    while rest.count > maxColumns { out.append(String(rest.prefix(maxColumns))); rest = rest.dropFirst(maxColumns) }
    out.append(String(rest))
    return out
}
let lines = try String(contentsOfFile: args[2], encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).flatMap { wrapped(String($0)) }
let size = NSSize(width: 660, height: 310), titleBar: CGFloat = 28, scale = 2
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let window = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 10, yRadius: 10)
NSColor(srgbRed: 0.07, green: 0.09, blue: 0.20, alpha: 1).setFill(); window.fill()
window.addClip()
NSColor(srgbRed: 0.13, green: 0.15, blue: 0.29, alpha: 1).setFill()
NSRect(x: 0, y: size.height - titleBar, width: size.width, height: titleBar).fill()
for i in 0..<3 {
    NSColor(white: 0.55, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 12 + CGFloat(i) * 20, y: size.height - 19, width: 11, height: 11)).fill()
}
let title = "Terminal" as NSString
title.draw(at: NSPoint(x: size.width / 2 - 24, y: size.height - 21), withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor(white: 0.8, alpha: 1)])

let font = NSFont(name: "Menlo", size: 13) ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
let cream = NSColor(srgbRed: 0.96, green: 0.93, blue: 0.86, alpha: 1), accent = NSColor(srgbRed: 0.93, green: 0.36, blue: 0.27, alpha: 1)
let lineHeight: CGFloat = 17
var y = size.height - titleBar - 22
let visible = Int((size.height - titleBar - 16) / lineHeight)
let shown = lines.count > visible ? Array(lines.suffix(visible)) : lines // like a real terminal: older lines scroll away
for (i, line) in shown.enumerated() {
    if line.hasPrefix("$ ") {
        ("$" as NSString).draw(at: NSPoint(x: 14, y: y), withAttributes: [.font: font, .foregroundColor: accent])
        (String(line.dropFirst(2)) as NSString).draw(at: NSPoint(x: 14 + 2 * 7.83, y: y), withAttributes: [.font: font, .foregroundColor: cream])
        if i == shown.count - 1 && line == "$ " { // the cursor of the prompt that is waiting
            cream.setFill(); NSRect(x: 14 + 2 * 7.83, y: y - 2, width: 7.83, height: 15).fill()
        }
    } else {
        (line as NSString).draw(at: NSPoint(x: 14, y: y), withAttributes: [.font: font, .foregroundColor: NSColor(srgbRed: 0.75, green: 0.88, blue: 0.80, alpha: 1)])
    }
    y -= lineHeight
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))

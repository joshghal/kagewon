import AppKit
import ImageIO
import UniformTypeIdentifiers

// Turns the recorded window images into captioned, animated GIFs.
// Usage: make-gif <manifest> <frames folder> <output folder>
// A manifest line is: flow|image|caption|milliseconds|points cropped from the top (the title bar of a terminal window)
struct Frame { let flow, file, caption: String; let ms, crop: Int }
let args = CommandLine.arguments
guard args.count == 4 else { print("usage: make-gif <manifest> <frames> <output>"); exit(1) }
var frames: [Frame] = []
for line in try String(contentsOfFile: args[1], encoding: .utf8).split(separator: "\n") {
    let p = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    if p.count == 5 { frames.append(Frame(flow: p[0], file: p[1], caption: p[2], ms: Int(p[3]) ?? 1500, crop: Int(p[4]) ?? 0)) }
}
var flows: [String] = []
for f in frames where !flows.contains(f.flow) { flows.append(f.flow) }

let cream = NSColor(srgbRed: 0.96, green: 0.94, blue: 0.90, alpha: 1)
let ink = NSColor(srgbRed: 0.12, green: 0.14, blue: 0.28, alpha: 1)
let accent = NSColor(srgbRed: 0.85, green: 0.30, blue: 0.22, alpha: 1)
let canvasWidth = 460, captionHeight = 92, margin = 14

func compose(_ frame: Frame, step: Int, of total: Int) -> CGImage {
    guard let source = NSImage(contentsOfFile: "\(args[2])/\(frame.file)") else { fatalError("missing \(frame.file)") }
    let scale = min(1.0, Double(canvasWidth - 2 * margin) / Double(source.size.width))
    let drawW = Double(source.size.width) * scale
    let drawH = (Double(source.size.height) - Double(frame.crop)) * scale
    let height = Int(drawH) + 2 * margin + captionHeight
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: canvasWidth, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    cream.setFill(); NSRect(x: 0, y: 0, width: canvasWidth, height: height).fill()
    // the picture, without the part that was cropped away from its top
    let x = (Double(canvasWidth) - drawW) / 2
    source.draw(in: NSRect(x: x, y: Double(captionHeight + margin), width: drawW, height: drawH),
                from: NSRect(x: 0, y: 0, width: source.size.width, height: source.size.height - Double(frame.crop)), operation: .sourceOver, fraction: 1)
    let para = NSMutableParagraphStyle(); para.lineBreakMode = .byWordWrapping
    let counter = "\(step) / \(total)" as NSString
    counter.draw(at: NSPoint(x: margin, y: captionHeight - 24), withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: accent])
    (frame.caption as NSString).draw(in: NSRect(x: margin, y: 8, width: canvasWidth - 2 * margin, height: captionHeight - 32),
                                     withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: ink, .paragraphStyle: para])
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage!
}

for flow in flows {
    let mine = frames.filter { $0.flow == flow }
    let url = URL(fileURLWithPath: "\(args[3])/\(flow).gif")
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, mine.count, nil) else { fatalError("cannot write \(flow)") }
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary)
    for (i, f) in mine.enumerated() {
        let props = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: Double(f.ms) / 1000.0]] as CFDictionary
        CGImageDestinationAddImage(dest, compose(f, step: i + 1, of: mine.count), props)
    }
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot finish \(flow)") }
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    print("\(flow).gif: \(mine.count) frames, \(size / 1024) KB")
}

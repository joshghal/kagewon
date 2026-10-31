import AppKit

/// The menu bar mark: a globe (the circle and the network). When the proxy is on, its shadow falls behind it as a crescent.
/// A dashed circle means connecting, and a circle with "!" means an error. It is a template image, so macOS colours it.
/// The shapes are drawn on an 18 point square with the y axis pointing down, the same way as docs/logo.svg.
func menuBarGlyph(for phase: Phase) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
        let cx: CGFloat = 7.6, cy: CGFloat = 7.6, r: CGFloat = 5.6
        let globe = NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
        NSColor.black.set()

        if case .on = phase {
            // the shadow, with the inside of the globe cut out of it so that only a crescent shows
            NSBezierPath(ovalIn: NSRect(x: 10.4 - r, y: 10.4 - r, width: 2 * r, height: 2 * r)).fill()
            NSGraphicsContext.current?.compositingOperation = .clear
            globe.fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        }

        globe.lineWidth = 1.4
        switch phase {
        case .launching, .starting: globe.setLineDash([2.2, 1.7], count: 2, phase: 0)
        default: break
        }
        globe.stroke()

        switch phase {
        case .off, .on:
            let meridian = NSBezierPath(ovalIn: NSRect(x: cx - 2.3, y: cy - r, width: 4.6, height: 2 * r))
            meridian.lineWidth = 1.2
            meridian.stroke()
            let equator = NSBezierPath()
            equator.move(to: NSPoint(x: cx - r, y: cy))
            equator.line(to: NSPoint(x: cx + r, y: cy))
            equator.lineWidth = 1.2
            equator.stroke()
        case .error:
            NSBezierPath(roundedRect: NSRect(x: 6.9, y: 4.2, width: 1.4, height: 4.4), xRadius: 0.7, yRadius: 0.7).fill()
            NSBezierPath(ovalIn: NSRect(x: 6.7, y: 9.7, width: 1.8, height: 1.8)).fill()
        case .launching, .starting:
            break
        }
        return true
    }
    image.isTemplate = true
    return image
}

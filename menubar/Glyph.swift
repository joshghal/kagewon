import AppKit

/// The menu bar mark: a globe (the circle and the network) and its shadow.
/// Off, only a thin arc of the shadow shows. On, the shadow is a solid crescent. A dashed circle means connecting,
/// and a circle with "!" means an error. It is a template image, so macOS colours it for the menu bar.
/// `spin` moves the dashes along the circle one step, so that connecting looks busy instead of stuck.
/// The shapes are drawn on an 18 point square with the y axis pointing down, the same way as docs/logo.svg.
func menuBarGlyph(for phase: Phase, spin: Int = 0) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { bounds in
        let cx: CGFloat = 7.7, cy: CGFloat = 7.7, r: CGFloat = 5.3
        let fall: CGFloat = 3.2
        func circle(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) -> NSBezierPath {
            NSBezierPath(ovalIn: NSRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius))
        }
        NSColor.black.set()

        switch phase {
        case .off, .on:
            // The shadow falls down and to the right. Everything inside a circle a little larger than the globe is left
            // clear, so a gap separates the two and the shadow never looks attached to the globe's outline.
            let outside = NSBezierPath(rect: bounds)
            outside.append(circle(cx, cy, r + 1.55))
            outside.windingRule = .evenOdd
            NSGraphicsContext.saveGraphicsState()
            outside.addClip()
            let shadow = circle(cx + fall, cy + fall, r)
            if case .on = phase {
                shadow.fill()
            } else {
                shadow.lineWidth = 1.1
                shadow.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()
        default:
            break
        }

        let globe = circle(cx, cy, r)
        globe.lineWidth = 1.3
        switch phase {
        case .launching, .starting: globe.setLineDash([2.1, 1.6], count: 2, phase: CGFloat(spin))
        default: break
        }
        globe.stroke()

        switch phase {
        case .off, .on:
            let meridian = NSBezierPath(ovalIn: NSRect(x: cx - 2.2, y: cy - r, width: 4.4, height: 2 * r))
            meridian.lineWidth = 1.1
            meridian.stroke()
            let equator = NSBezierPath()
            equator.move(to: NSPoint(x: cx - r, y: cy))
            equator.line(to: NSPoint(x: cx + r, y: cy))
            equator.lineWidth = 1.1
            equator.stroke()
        case .error:
            NSBezierPath(roundedRect: NSRect(x: cx - 0.7, y: cy - 3.5, width: 1.4, height: 4.2), xRadius: 0.7, yRadius: 0.7).fill()
            circle(cx, cy + 3.0, 0.9).fill()
        case .launching, .starting:
            break
        }
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "Kagewon"
    return image
}

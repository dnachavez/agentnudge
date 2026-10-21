import AppKit

/// The menu bar glyph: the AgentNudge mark, three quarters of a disc and a light in the
/// fourth, drawn as a template image so the system tints it for any menu bar. The light
/// tells the state: none when all is quiet, small while sessions run, full when one needs you.
enum StatusGlyph {
    enum State { case quiet, running, attention }

    static func image(_ state: State) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            NSColor.black.setFill()
            // A wider gutter than the logo's, so the quarters stay apart at 16 pt.
            for quarter in Mark.quarters(in: rect.insetBy(dx: 1.5, dy: 1.5), gutter: 7) {
                NSBezierPath(cgPath: quarter).fill()
            }
            let r: CGFloat
            switch state {
            case .quiet: r = 0
            case .running: r = 7
            case .attention: r = 13
            }
            if r > 0 { NSBezierPath(ovalIn: Mark.light(in: rect.insetBy(dx: 1.5, dy: 1.5), radius: r)).fill() }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "AgentNudge"
        return image
    }
}

/// The mark's geometry on its 100-unit grid: a radius-36 disc centred at 50, cut into
/// quarters by a gutter, with the light (radius 13) centred in the bottom-right cell.
/// Coordinates are y-down; `rect` maps to the disc's 77-unit span.
enum Mark {
    static func quarters(in rect: CGRect, gutter g: CGFloat = 5) -> [CGPath] {
        let s = rect.width / 77
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (x - 11.5) * s, y: rect.minY + (y - 11.5) * s)
        }
        let h = g / 2
        let r = 38.5 - h
        let corners: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (50 - h, 50 - h, 180, 270),  // top-left
            (50 + h, 50 - h, 270, 360),  // top-right
            (50 - h, 50 + h, 90, 180),   // bottom-left
        ]
        return corners.map { cx, cy, start, end in
            let path = CGMutablePath()
            path.move(to: p(cx, cy))
            path.addArc(center: p(cx, cy), radius: r * s, startAngle: start * .pi / 180, endAngle: end * .pi / 180, clockwise: false)
            path.closeSubpath()
            return path
        }
    }

    static func light(in rect: CGRect, radius: CGFloat = 13) -> CGRect {
        let s = rect.width / 77
        let c = CGPoint(x: rect.minX + (70.5 - 11.5) * s, y: rect.minY + (70.5 - 11.5) * s)
        return CGRect(x: c.x - radius * s, y: c.y - radius * s, width: 2 * radius * s, height: 2 * radius * s)
    }
}

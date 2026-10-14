import AppKit

/// The app icon, drawn in code so the Dock shows it even when the app runs as
/// a bare executable (no bundle yet). `scripts/make-icon.sh` exports the same
/// drawing to PNG/ICNS. A flat bot face, in the avatars' style, on a dark
/// macOS squircle.
enum AppIcon {
    static func image(size: CGFloat = 1024) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            draw(in: rect)
            return true
        }
    }

    static func draw(in rect: NSRect) {
        let s = rect.width / 1024
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
            NSRect(x: rect.minX + x * s, y: rect.minY + y * s, width: w * s, height: h * s)
        }

        // macOS icon grid: 824 pt squircle centered in 1024, with a soft drop shadow.
        let tile = NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 28 * s
        shadow.shadowOffset = NSSize(width: 0, height: -12 * s)
        shadow.set()
        NSColor(white: 0.07, alpha: 1).setFill()
        tile.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Barely-there vertical tone and a hairline edge keep the dark tile from looking flat-black.
        NSGraphicsContext.saveGraphicsState()
        tile.addClip()
        NSGradient(starting: NSColor(white: 0.13, alpha: 1), ending: NSColor(white: 0.05, alpha: 1))?
            .draw(in: r(100, 100, 824, 824), angle: 90)
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 1, alpha: 0.08).setStroke()
        tile.lineWidth = 4 * s
        tile.stroke()

        // The bot: same parts as a 64-unit avatar (dot eyes, smile), scaled to a 560 pt face.
        let faceSize: CGFloat = 560
        let ox = 512 - faceSize / 2, oy = 512 - faceSize / 2
        let u = faceSize / 64
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: rect.minX + (ox + x * u) * s, y: rect.minY + (oy + y * u) * s) }

        NSColor(red: 0.31, green: 0.61, blue: 0.98, alpha: 1).setFill()
        NSBezierPath(ovalIn: r(ox, oy, faceSize, faceSize)).fill()

        NSColor.white.setFill()
        for x: CGFloat in [22, 42] {
            let c = p(x, 30)
            let rad = 4.2 * u * s
            NSBezierPath(ovalIn: NSRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2)).fill()
        }

        let smile = NSBezierPath()
        smile.move(to: p(24, 41))
        smile.curve(to: p(40, 41), controlPoint1: p(27.5, 47.5), controlPoint2: p(36.5, 47.5))
        smile.lineWidth = 2.8 * u * s
        smile.lineCapStyle = .round
        NSColor.white.setStroke()
        smile.stroke()
    }
}

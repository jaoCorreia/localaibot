import SwiftUI

/// Animated "building a computer" mark for devices that are being created: a
/// monitor outline draws itself while a scan line sweeps the screen and a
/// breathing dot grid fills in behind it. Monochrome, drawn with Theme colors
/// so it matches the rest of the chrome. Reduce Motion freezes it.
struct DeviceLoader: View {
    var size: CGFloat = 120

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            canvas(at: 1.2)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                canvas(at: context.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func canvas(at t: TimeInterval) -> some View {
        Canvas { ctx, s in
            let line = Theme.secondary
            let faint = Theme.tertiary
            let w = s.width, h = s.height

            // Monitor body and screen, traced progressively in a repeating loop.
            let body = CGRect(x: w * 0.08, y: h * 0.10, width: w * 0.84, height: h * 0.58)
            let screen = body.insetBy(dx: w * 0.05, dy: h * 0.05)
            let cycle = 3.2
            let phase = t.truncatingRemainder(dividingBy: cycle) / cycle
            let trace = min(1, phase / 0.55)

            ctx.stroke(Path(roundedRect: body, cornerRadius: 8).trimmedPath(from: 0, to: trace),
                       with: .color(line), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

            // Stand.
            var stand = Path()
            stand.move(to: CGPoint(x: w * 0.5, y: body.maxY))
            stand.addLine(to: CGPoint(x: w * 0.5, y: h * 0.82))
            stand.move(to: CGPoint(x: w * 0.32, y: h * 0.84))
            stand.addLine(to: CGPoint(x: w * 0.68, y: h * 0.84))
            ctx.stroke(stand.trimmedPath(from: 0, to: min(1, max(0, (phase - 0.4) / 0.2))),
                       with: .color(line), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

            // Dot grid inside the screen; dots swell as the scan line passes.
            let cols = 9, rows = 5
            let scanX = screen.minX + screen.width * CGFloat((t * 0.45).truncatingRemainder(dividingBy: 1))
            for r in 0..<rows {
                for c in 0..<cols {
                    let x = screen.minX + screen.width * (CGFloat(c) + 0.5) / CGFloat(cols)
                    let y = screen.minY + screen.height * (CGFloat(r) + 0.5) / CGFloat(rows)
                    let near = max(0, 1 - abs(x - scanX) / (screen.width * 0.22))
                    let breathe = 0.5 + 0.5 * sin(t * 2 + Double(r * 3 + c) * 0.6)
                    let radius = 1.2 + 1.6 * near + 0.4 * breathe
                    let dot = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                    ctx.fill(Path(ellipseIn: dot),
                             with: .color((near > 0.05 ? line : faint).opacity(0.35 + 0.65 * near)))
                }
            }

            // Scan line.
            var scan = Path()
            scan.move(to: CGPoint(x: scanX, y: screen.minY))
            scan.addLine(to: CGPoint(x: scanX, y: screen.maxY))
            ctx.stroke(scan, with: .color(Theme.text.opacity(0.35)), lineWidth: 1)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

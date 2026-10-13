import SwiftUI

/// A bot's face drawn natively (same parts as the brain's SVG) so it can move:
/// idle bots blink and glance around now and then; working bots scan side to
/// side. Each bot gets its own rhythm from its id. Reduce Motion freezes it.
struct AnimatedFace: View {
    let face: Brain.Face
    var size: CGFloat = 28
    var working = false
    /// Desynchronizes blinks between bots.
    var seed: String = ""

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            canvas(at: 0, animated: false)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                canvas(at: context.date.timeIntervalSinceReferenceDate, animated: true)
            }
        }
    }

    private func canvas(at time: TimeInterval, animated: Bool) -> some View {
        let motion = animated ? Motion(time: time + phase, working: working) : .still
        return Canvas { ctx, canvasSize in
            ctx.scaleBy(x: canvasSize.width / 64, y: canvasSize.height / 64)
            FaceDrawing(face: face, motion: motion).draw(in: &ctx)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var phase: TimeInterval {
        Double(abs(seed.hashValue % 10_000)) / 10_000 * 40
    }
}

/// Where the eyes look and how open they are at a moment in time.
struct Motion {
    var gazeX: CGFloat = 0
    var gazeY: CGFloat = 0
    /// 1 = open, ~0.1 = closed.
    var openness: CGFloat = 1

    static let still = Motion()

    init(gazeX: CGFloat = 0, gazeY: CGFloat = 0, openness: CGFloat = 1) {
        self.gazeX = gazeX
        self.gazeY = gazeY
        self.openness = openness
    }

    init(time t: TimeInterval, working: Bool) {
        // Blink: a quick close/open every ~4.2 s, plus a double blink every third cycle.
        let period = 4.2
        let cycle = t.truncatingRemainder(dividingBy: period)
        let blink: (TimeInterval) -> CGFloat = { start in
            let d = cycle - start
            guard d >= 0, d < 0.16 else { return 1 }
            return CGFloat(0.12 + 0.88 * abs(cos(d / 0.16 * .pi)))
        }
        let doubleBlink = Int(t / period) % 3 == 0
        openness = min(blink(0), doubleBlink ? blink(0.24) : 1)

        if working {
            // Reading: smooth left-right scan, eyes slightly up.
            gazeX = CGFloat(sin(t * 2.2)) * 3.2
            gazeY = -1.2
        } else {
            // Idle: hold the center, glance to one side for a moment every ~7 s.
            let g = t.truncatingRemainder(dividingBy: 7.3)
            let side: CGFloat = Int(t / 7.3) % 2 == 0 ? 1 : -1
            let ease: (Double) -> CGFloat = { x in CGFloat(0.5 - 0.5 * cos(min(max(x, 0), 1) * .pi)) }
            let amount: CGFloat = g < 2.6 ? 0 : (g < 3.0 ? ease((g - 2.6) / 0.4) : (g < 4.2 ? 1 : 1 - ease((g - 4.2) / 0.4)))
            gazeX = side * 2.6 * amount
            gazeY = 0.6 * amount
        }
    }
}

/// Draws the catalog parts in a 64×64 space. Mirrors brain/src/bots/avatar.ts.
struct FaceDrawing {
    let face: Brain.Face
    let motion: Motion

    private let ink = Color.white
    private let eyeY: CGFloat = 31
    private let left: CGFloat = 22, right: CGFloat = 42

    func draw(in ctx: inout GraphicsContext) {
        let fill = Color(hex: face.fill)
        if face.accessory == "orbit" {
            ring(front: false, in: &ctx, color: fill)
            var planet = ctx
            planet.translateBy(x: 32, y: 29)
            planet.scaleBy(x: 0.68, y: 0.68)
            planet.translateBy(x: -32, y: -32)
            body(in: &planet, fill: fill)
            ring(front: true, in: &ctx, color: fill)
        } else {
            body(in: &ctx, fill: fill)
        }
    }

    private func body(in ctx: inout GraphicsContext, fill: Color) {
        ctx.fill(Circle().path(in: CGRect(x: 0, y: 0, width: 64, height: 64)), with: .color(fill))
        accessory(in: &ctx)
        eyes(in: &ctx)
        mouth(in: &ctx)
    }

    private func ring(front: Bool, in ctx: inout GraphicsContext, color: Color) {
        var c = ctx
        c.translateBy(x: 32, y: 40)
        c.rotate(by: .degrees(-14))
        var p = Path()
        // Half of an ellipse 30×7: the back half arcs over the top, the front under.
        p.addArc(center: .zero, radius: 1, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: front)
        let scaled = p.applying(CGAffineTransform(scaleX: 30, y: 7))
        c.stroke(scaled, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round))
    }

    private func accessory(in ctx: inout GraphicsContext) {
        switch face.accessory {
        case "antenna":
            ctx.fill(RoundedRectangle(cornerRadius: 1).path(in: CGRect(x: 31, y: 3, width: 2, height: 7)), with: .color(ink.opacity(0.8)))
            ctx.fill(Circle().path(in: CGRect(x: 29.4, y: 0.9, width: 5.2, height: 5.2)), with: .color(ink))
        case "cheeks":
            let deep = Color(hex: face.deep).opacity(0.3)
            ctx.fill(Circle().path(in: CGRect(x: 14, y: 37, width: 6, height: 6)), with: .color(deep))
            ctx.fill(Circle().path(in: CGRect(x: 44, y: 37, width: 6, height: 6)), with: .color(deep))
        default:
            break
        }
    }

    /// Applies gaze and blink around an eye's center.
    private func eye(_ cx: CGFloat, in ctx: inout GraphicsContext, draw: (inout GraphicsContext) -> Void) {
        var c = ctx
        c.translateBy(x: cx + motion.gazeX, y: eyeY + motion.gazeY)
        c.scaleBy(x: 1, y: max(motion.openness, 0.08))
        draw(&c)
    }

    private func eyes(in ctx: inout GraphicsContext) {
        switch face.eyes {
        case "dot":
            for x in [left, right] {
                eye(x, in: &ctx) { $0.fill(Circle().path(in: CGRect(x: -3.6, y: -3.6, width: 7.2, height: 7.2)), with: .color(ink)) }
            }
        case "pill":
            for x in [left, right] {
                eye(x, in: &ctx) { $0.fill(RoundedRectangle(cornerRadius: 2.6).path(in: CGRect(x: -2.6, y: -5.5, width: 5.2, height: 11)), with: .color(ink)) }
            }
        case "visor":
            eye((left + right) / 2, in: &ctx) {
                $0.fill(RoundedRectangle(cornerRadius: 2.5).path(in: CGRect(x: -(right - left) / 2 - 5, y: -2.5, width: right - left + 10, height: 5)), with: .color(ink))
            }
        case "ring":
            for x in [left, right] {
                eye(x, in: &ctx) { $0.stroke(Circle().path(in: CGRect(x: -3.8, y: -3.8, width: 7.6, height: 7.6)), with: .color(ink), lineWidth: 2.4) }
            }
        case "happy":
            for x in [left, right] {
                eye(x, in: &ctx) {
                    var p = Path()
                    p.move(to: CGPoint(x: -4, y: 1.5))
                    p.addQuadCurve(to: CGPoint(x: 4, y: 1.5), control: CGPoint(x: 0, y: -4.5))
                    $0.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                }
            }
        case "spark":
            for x in [left, right] {
                eye(x, in: &ctx) {
                    var p = Path()
                    let pts: [(CGFloat, CGFloat)] = [(0, -5), (1.4, -1.4), (5, 0), (1.4, 1.4), (0, 5), (-1.4, 1.4), (-5, 0), (-1.4, -1.4)]
                    p.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
                    for pt in pts.dropFirst() { p.addLine(to: CGPoint(x: pt.0, y: pt.1)) }
                    p.closeSubpath()
                    $0.fill(p, with: .color(ink))
                }
            }
        default:
            break
        }
    }

    private func mouth(in ctx: inout GraphicsContext) {
        switch face.mouth {
        case "smile":
            var p = Path()
            p.move(to: CGPoint(x: 25, y: 42))
            p.addQuadCurve(to: CGPoint(x: 39, y: 42), control: CGPoint(x: 32, y: 48))
            ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        case "line":
            ctx.fill(RoundedRectangle(cornerRadius: 1.2).path(in: CGRect(x: 26, y: 42, width: 12, height: 2.4)), with: .color(ink))
        case "dot":
            ctx.fill(Circle().path(in: CGRect(x: 30.1, y: 41.6, width: 3.8, height: 3.8)), with: .color(ink))
        case "o":
            ctx.stroke(Ellipse().path(in: CGRect(x: 29.4, y: 40.3, width: 5.2, height: 6.4)), with: .color(ink), lineWidth: 2)
        case "grin":
            var p = Path()
            p.move(to: CGPoint(x: 25, y: 41))
            p.addQuadCurve(to: CGPoint(x: 39, y: 41), control: CGPoint(x: 32, y: 49))
            p.closeSubpath()
            ctx.fill(p, with: .color(ink))
        default:
            break
        }
    }
}

import SwiftUI
import AppKit

/// A bot's face drawn natively (same parts as the brain's SVG) as a small 3D
/// ball with the face on its surface. Bots mostly hold still, now and then turn
/// to look somewhere, blink, and slip into a mood (happy, surprised, sleepy,
/// curious). Working bots read in steps, line by line. With
/// `followsPointer`, the bot watches the mouse and reacts as it comes close.
/// Each bot gets its own rhythm from its id. Reduce Motion freezes it.
struct AnimatedFace: View {
    let face: Brain.Face
    var size: CGFloat = 28
    var working = false
    /// Desynchronizes blinks between bots.
    var seed: String = ""
    /// Look at and react to the mouse, wherever it is on screen.
    var followsPointer = false
    /// The last request failed: finishing work then reads as a let-down.
    var failed = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var anchor = ViewAnchor()
    /// A short reaction to a request starting or finishing, and when it began.
    @State private var reaction: (kind: Reaction, at: TimeInterval)?

    var body: some View {
        Group {
            if reduceMotion {
                canvas(at: 0, animated: false)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    canvas(at: context.date.timeIntervalSinceReferenceDate, animated: true)
                }
            }
        }
        .onChange(of: working) { _, now in react(now ? .noticed : (failed ? .oops : .done)) }
        .onChange(of: failed) { _, now in if now { react(.oops) } }
        .background { if followsPointer { AnchorView(anchor: anchor) } }
    }

    private func react(_ kind: Reaction) {
        reaction = (kind, Date.timeIntervalSinceReferenceDate)
    }

    /// Mouse offset from the face's center, in points (y down), while following it.
    /// Read every frame, so it also works over the window behind a sheet or
    /// popover; outside the app's window the bot goes back to its own thing.
    private var look: CGVector? {
        guard followsPointer, let view = anchor.view, let window = view.window else { return nil }
        let mouse = NSEvent.mouseLocation
        let windows = [window, window.sheetParent, window.parent, NSApp.mainWindow].compactMap { $0 }
        guard windows.contains(where: { $0.frame.contains(mouse) }) else { return nil }
        let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
        return CGVector(dx: mouse.x - frame.midX, dy: frame.midY - mouse.y)
    }

    private func canvas(at time: TimeInterval, animated: Bool) -> some View {
        let t = time + phase
        var motion = animated ? Motion(time: t, working: working, look: look, size: size) : .still
        if animated, let reaction {
            motion.react(reaction.kind, age: time - reaction.at)
        }
        let pose = BlockPose(yaw: motion.yaw, pitch: motion.pitch, shape: BlockShape(face))
        return Canvas { ctx, canvasSize in
            ctx.scaleBy(x: canvasSize.width / 64, y: canvasSize.height / 64)
            FaceDrawing(face: face, motion: motion).draw(in: &ctx, pose: pose)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var phase: TimeInterval {
        Double(abs(seed.hashValue % 10_000)) / 10_000 * 40
    }
}

/// How a bot answers a request: perking up when one arrives, pleased when it's
/// done, deflated when it failed.
enum Reaction {
    case noticed, done, oops

    var duration: TimeInterval {
        switch self {
        case .noticed: return 0.9
        case .done: return 1.6
        case .oops: return 2.2
        }
    }
}

/// Holds the AppKit view behind a face so it can be located on screen.
final class ViewAnchor {
    weak var view: NSView?
}

private struct AnchorView: NSViewRepresentable {
    let anchor: ViewAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }
}

/// Where the head turns and the eyes look, how open they are, and the
/// expression of the moment.
struct Motion {
    var yaw: CGFloat = -0.32
    var pitch: CGFloat = 0.1
    var gazeX: CGFloat = 0
    var gazeY: CGFloat = 0
    /// 1 = open, ~0.1 = closed.
    var openness: CGFloat = 1
    /// Per-eye size on top of the above (a curious eye).
    var leftSize: CGFloat = 1, rightSize: CGFloat = 1
    /// 0…1: a happy squint (eyes pressed into crescents by a smile).
    var squint: CGFloat = 0
    /// 0…1: surprise (eyes pop wider).
    var widen: CGFloat = 0
    /// Head tilt of the face, in radians.
    var tilt: CGFloat = 0
    /// Mouth stretch: wider when happy, taller and narrower when surprised.
    var mouthX: CGFloat = 1
    var mouthY: CGFloat = 1
    /// Small vertical drift of the whole face (breathing).
    var bob: CGFloat = 0

    static let still = Motion()

    init() {}

    private enum Mood: CaseIterable { case none, happy, surprised, sleepy, curious }

    init(time t: TimeInterval, working: Bool, look: CGVector?, size: CGFloat) {
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
        bob = CGFloat(sin(t * 1.6)) * 0.5

        if let look {
            follow(look, size: size)
        } else if working {
            read(t)
        } else {
            idle(t)
        }
        // Squinting eyes don't blink all the way.
        openness = max(openness, 0.12 + 0.5 * squint)
    }

    /// Mostly still: every few seconds the head may turn to a new spot and hold
    /// there, the eyes leading. A mood plays now and then on its own clock.
    private mutating func idle(_ t: TimeInterval) {
        let seg = 4.8
        let i = Int(floor(t / seg)), g = t - Double(i) * seg
        let target: (Int) -> (CGFloat, CGFloat) = { n in
            // About half the time the bot rests facing forward.
            guard Self.random(n, 1) > 0.5 else { return (-0.3, 0.1) }
            return (CGFloat(Self.random(n, 2) * 1.2 - 0.6), CGFloat(Self.random(n, 3) * 0.3 - 0.06))
        }
        let (py, pp) = target(i - 1), (cy, cp) = target(i)
        let head = Self.ease(g / 0.7)
        let eyes = Self.ease(g / 0.18)
        yaw = py + (cy - py) * head
        pitch = pp + (cp - pp) * head
        // Eyes jump to the new spot first, then settle as the head catches up.
        let lead = (cy - py) * (eyes - head)
        gazeX = lead * 6
        gazeY = (cp - pp) * (eyes - head) * 6

        let mlen = 9.7
        let m = Int(floor(t / mlen)), mg = t - Double(m) * mlen
        let mood = Mood.allCases[Int(Self.random(m, 7) * Double(Mood.allCases.count)) % Mood.allCases.count]
        let side: CGFloat = Self.random(m, 8) > 0.5 ? 1 : -1
        let k = Self.window(mg, 3.6, 6.2, 0.3)
        express(mood, k, side: side)
    }

    /// Reading: the head steps across a line and back, the eyes snapping ahead,
    /// slightly narrowed in focus; a brief "aha" now and then.
    private mutating func read(_ t: TimeInterval) {
        let seg = 0.9
        let i = Int(floor(t / seg)), g = t - Double(i) * seg
        let stops: [CGFloat] = [-0.4, -0.15, 0.1, 0.35, -0.4]
        let step: (Int) -> CGFloat = { n in stops[((n % 4) + 4) % 4] }
        let (prev, cur) = (step(i - 1), step(i))
        let head = Self.ease(g / 0.35), eyes = Self.ease(g / 0.12)
        yaw = prev + (cur - prev) * head
        pitch = 0.14
        gazeX = (cur - prev) * (eyes - head) * 6 + cur * 2
        gazeY = -1.2
        squint = 0.22
        mouthX = 0.85
        let aha = Self.window(t.truncatingRemainder(dividingBy: 7.1), 6.2, 6.9, 0.15)
        widen = aha
        squint *= 1 - aha
        mouthY = 1 + 0.3 * aha
    }

    /// Watch the pointer: the head and eyes turn toward it; up close the bot
    /// lights up, and right on top of it it beams.
    private mutating func follow(_ v: CGVector, size: CGFloat) {
        let clamp: (CGFloat) -> CGFloat = { min(max($0, -1), 1) }
        let reach = max(size * 3, 140)
        yaw = clamp(v.dx / reach) * 0.7
        pitch = 0.06 + clamp(v.dy / reach) * 0.4
        gazeX = clamp(v.dx / (reach * 0.6)) * 3.4
        gazeY = clamp(v.dy / (reach * 0.6)) * 2.6
        let distance = hypot(v.dx, v.dy)
        let near = max(0, 1 - (distance - size * 0.5) / (size * 1.6))
        let onTop = distance < size * 0.5 ? CGFloat(1) : 0
        // Approaching: eyes widen with interest; close: a happy squint and a smile.
        widen = 0.5 * near * (1 - near)
        squint = max(near * near * 0.7, onTop)
        mouthX = 1 + 0.25 * near + 0.1 * onTop
        mouthY = 1 + 0.15 * onTop
        tilt = clamp(v.dx / reach) * 0.08 * near
    }

    /// Layers a reaction over whatever the bot is doing, fading in and out.
    mutating func react(_ kind: Reaction, age: TimeInterval) {
        guard age >= 0, age < kind.duration else { return }
        let k = Self.window(age, 0, kind.duration, 0.15)
        let mix: (CGFloat, CGFloat) -> CGFloat = { from, to in from + (to - from) * k }
        switch kind {
        case .noticed:
            // Eyes pop, face front, a quick nod up.
            widen = max(widen, k)
            squint *= 1 - k
            yaw = mix(yaw, -0.1)
            pitch = mix(pitch, -0.05)
            gazeX = mix(gazeX, 0)
            gazeY = mix(gazeY, -0.8)
            bob -= 2.2 * CGFloat(sin(min(age / 0.4, 1) * .pi))
            mouthX = mix(mouthX, 0.75)
            mouthY = mix(mouthY, 1.4)
        case .done:
            // Beaming, with a little hop.
            squint = max(squint, k)
            widen *= 1 - k
            mouthX = mix(mouthX, 1.3)
            mouthY = mix(mouthY, 1.15)
            tilt = mix(tilt, 0.12)
            yaw = mix(yaw, -0.2)
            gazeX = mix(gazeX, 0)
            bob -= 2.8 * CGFloat(abs(sin(min(age / 0.9, 1) * 2 * .pi)))
        case .oops:
            // Droopy eyes, a small frown-ish mouth and a slow head shake.
            widen *= 1 - k
            squint *= 1 - k
            openness *= 1 - 0.4 * k
            gazeX = mix(gazeX, 0)
            gazeY = mix(gazeY, 1.6)
            tilt = mix(tilt, -0.1)
            mouthX = mix(mouthX, 0.7)
            pitch = mix(pitch, 0.22)
            yaw = mix(yaw, -0.2) + 0.25 * k * CGFloat(sin(age * 9))
        }
    }

    private mutating func express(_ mood: Mood, _ k: CGFloat, side: CGFloat) {
        switch mood {
        case .none:
            break
        case .happy:
            squint = k
            mouthX = 1 + 0.2 * k
            tilt = side * 0.12 * k
        case .surprised:
            widen = k
            mouthX = 1 - 0.2 * k
            mouthY = 1 + 0.6 * k
            gazeY -= k
        case .sleepy:
            openness *= 1 - 0.6 * k
            gazeY += 1.2 * k
            tilt = side * 0.08 * k
            pitch += 0.12 * k
            mouthX = 1 - 0.15 * k
        case .curious:
            if side > 0 { rightSize = 1 + 0.2 * k } else { leftSize = 1 + 0.2 * k }
            tilt = side * 0.16 * k
            gazeX += side * 1.5 * k
            yaw += side * 0.15 * k
        }
    }

    private static func ease(_ x: Double) -> CGFloat {
        CGFloat(0.5 - 0.5 * cos(min(max(x, 0), 1) * .pi))
    }

    /// 0 → 1 → 0 over [start, end], easing in and out over `edge` seconds.
    private static func window(_ g: Double, _ start: Double, _ end: Double, _ edge: Double) -> CGFloat {
        min(ease((g - start) / edge), 1 - ease((g - (end - edge)) / edge))
    }

    /// Stable pseudo-random number in [0, 1) for a time slot.
    private static func random(_ n: Int, _ salt: Int) -> Double {
        let x = sin(Double(n) * 12.9898 + Double(salt) * 78.233) * 43758.5453
        return x - floor(x)
    }
}

/// Draws the catalog parts in a 64×64 space. Mirrors brain/src/bots/avatar.ts.
struct FaceDrawing {
    let face: Brain.Face
    let motion: Motion

    private let ink = Color.white
    private let eyeY: CGFloat = 31
    private let left: CGFloat = 22, right: CGFloat = 42

    func draw(in ctx: inout GraphicsContext, pose: BlockPose) {
        pose.drawBody(in: &ctx, fill: Color(hex: face.fill))
        // The face sits on the block's front plane: map the 64×64 face space onto it.
        ctx.transform = pose.frontPlane.concatenating(ctx.transform)
        ctx.translateBy(x: 32, y: 36 + motion.bob)
        ctx.rotate(by: .radians(motion.tilt))
        ctx.translateBy(x: -32, y: -36)
        accessory(in: &ctx)
        eyes(in: &ctx)
        mouth(in: &ctx)
    }

    private func accessory(in ctx: inout GraphicsContext) {
        switch face.accessory {
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
        // A squint lifts and flattens the eye; surprise enlarges it; a blink
        // squashes it and widens it a touch.
        c.translateBy(x: cx + motion.gazeX, y: eyeY + motion.gazeY - motion.squint * 1.2)
        let isLeft = cx < 31, isRight = cx > 33
        let size = isLeft ? motion.leftSize : (isRight ? motion.rightSize : (motion.leftSize + motion.rightSize) / 2)
        let grow = (1 + 0.28 * motion.widen) * size
        let height = max(motion.openness, 0.08) * (1 - 0.5 * motion.squint)
        c.scaleBy(x: grow * (1 + 0.15 * (1 - motion.openness)), y: grow * height)
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
        var ctx = ctx
        ctx.translateBy(x: 32, y: 43)
        ctx.scaleBy(x: motion.mouthX, y: motion.mouthY)
        ctx.translateBy(x: -32, y: -43)
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

/// Orientation of a bot's ball and where its face sits on it.
struct BlockPose {
    var yaw: CGFloat
    var pitch: CGFloat
    let shape: BlockShape

    init(yaw: CGFloat, pitch: CGFloat, shape: BlockShape) {
        self.yaw = yaw
        self.pitch = pitch
        self.shape = shape
    }

    /// Maps the 64×64 face space onto the ball: the face slides toward the limb
    /// and squeezes as the ball turns.
    var frontPlane: CGAffineTransform {
        let r = shape.radii
        let sx = cos(yaw) * 0.86, sy = cos(pitch) * 0.86
        let cx = 32 + r.a * 0.78 * sin(yaw) * cos(pitch)
        let cy = 32 + r.b * 0.78 * sin(pitch)
        return CGAffineTransform(a: sx, b: 0, c: -sin(yaw) * sin(pitch) * 0.3, d: sy,
                                 tx: cx - 32 * sx, ty: cy - 32 * sy)
    }

    /// A softly lit ball: light toward the upper left, slightly deeper color at
    /// the far edge.
    func drawBody(in ctx: inout GraphicsContext, fill: Color) {
        let r = shape.radii
        let body = shape.path
        let hi = CGPoint(x: 32 - r.a * 0.3, y: 32 - r.b * 0.35)
        // Soft: mostly the flat color, only gently darker toward the far edge.
        let shading = Gradient(stops: [
            .init(color: Self.shade(fill, 1.05), location: 0),
            .init(color: fill, location: 0.5),
            .init(color: Self.shade(fill, 0.86), location: 1),
        ])
        ctx.fill(body, with: .radialGradient(shading, center: hi, startRadius: 0, endRadius: max(r.a, r.b) * 1.7))
    }

    private static func shade(_ color: Color, _ factor: CGFloat) -> Color {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return color }
        func f(_ v: CGFloat) -> Double { Double(min(max(v * factor, 0), 1)) }
        return Color(red: f(c.redComponent), green: f(c.greenComponent), blue: f(c.blueComponent))
    }
}

/// The proportions of a bot's ball. Every bot gets one, picked from its face so
/// it stays the same between launches.
enum BlockShape: String, CaseIterable {
    case round, egg, wide, bean, star, asterisk

    init(_ face: Brain.Face) {
        if let name = face.shape, let shape = BlockShape(rawValue: name) {
            self = shape
            return
        }
        // Older brains don't send a shape: derive it the way they used to.
        let sum = (face.fill + face.eyes + face.mouth + face.accessory).utf8.reduce(UInt(0)) { ($0 &* 31) &+ UInt($1) }
        self = Self.allCases[Int(sum % UInt(Self.allCases.count))]
    }

    /// Superellipse exponent: 2 is an ellipse; higher flattens the sides into
    /// tighter corners (a pill, like the wide bots).
    private var squareness: CGFloat {
        switch self {
        case .round: return 2
        case .egg: return 2.2
        case .wide: return 3.4
        case .bean: return 2.8
        case .star, .asterisk: return 2
        }
    }

    /// The silhouette, centered in the 64×64 face space.
    var path: Path {
        if let lobes = polar { return Self.polarPath(lobes) }
        let r = radii, n = squareness
        var p = Path()
        for i in 0..<72 {
            let t = CGFloat(i) / 72 * 2 * .pi
            let c = cos(t), s = sin(t)
            let pt = CGPoint(x: 32 + r.a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n),
                             y: 32 + r.b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }

    /// Half width and half height in the 64×64 face space.
    var radii: (a: CGFloat, b: CGFloat) {
        switch self {
        case .round: return (27, 27)
        case .egg: return (23, 27)
        case .wide: return (29, 21)
        case .bean: return (27, 23)
        case .star, .asterisk: return (29, 29)
        }
    }

    /// Shapes with points: radius as a function of the angle, one point up.
    /// The inner radius still clears the eyes and mouth. Same as the brain's SVG.
    private var polar: (count: CGFloat, base: CGFloat, power: CGFloat)? {
        switch self {
        case .star: return (5, 0.62, 1)        // soft five-pointed star
        case .asterisk: return (6, 0.6, 4)     // six rounded arms
        default: return nil
        }
    }

    private static func polarPath(_ s: (count: CGFloat, base: CGFloat, power: CGFloat)) -> Path {
        var p = Path()
        for i in 0..<240 {
            let t = CGFloat(i) / 240 * 2 * .pi
            let wave = s.count == 5 ? (1 + cos(5 * (t + .pi / 2))) / 2 : pow(abs(cos(3 * (t + .pi / 2))), s.power)
            let r = 29 * (s.base + (1 - s.base) * wave)
            let pt = CGPoint(x: 32 + r * cos(t), y: 32 + r * sin(t))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

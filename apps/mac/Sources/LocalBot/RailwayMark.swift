import SwiftUI

/// Railway symbol from https://railway.com/assets/LogoLockup-Bv6YZB8u.js
struct RailwayMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0.9544653, y: 0.7073194))
        path.addCurve(to: CGPoint(x: 0.4994722, y: 0.9999792), control1: CGPoint(x: 0.8755208, y: 0.8798611), control2: CGPoint(x: 0.7017292, y: 0.9999792))
        path.addCurve(to: CGPoint(x: 0.0439660, y: 0.7073194), control1: CGPoint(x: 0.1617972, y: 0.9948750), control2: CGPoint(x: 0.0444646, y: 0.7085347))
        path.addLine(to: CGPoint(x: 0.9544653, y: 0.7073194))
        path.closeSubpath()
        path.move(to: CGPoint(x: 0.4994722, y: 0.0000000))
        path.addCurve(to: CGPoint(x: 1.0000000, y: 0.5002035), control1: CGPoint(x: 0.7759167, y: 0.0000021), control2: CGPoint(x: 1.0000069, y: 0.2239736))
        path.addCurve(to: CGPoint(x: 0.9745278, y: 0.6570833), control1: CGPoint(x: 0.9999514, y: 0.5535222), control2: CGPoint(x: 0.9913611, y: 0.6064861))
        path.addLine(to: CGPoint(x: 0.0266319, y: 0.6570833))
        path.addCurve(to: CGPoint(x: 0.0162965, y: 0.6202222), control1: CGPoint(x: 0.0204326, y: 0.6377431), control2: CGPoint(x: 0.0162965, y: 0.6202222))
        path.addLine(to: CGPoint(x: 0.7107153, y: 0.6202222))
        path.addCurve(to: CGPoint(x: 0.8087361, y: 0.5594688), control1: CGPoint(x: 0.7550764, y: 0.6202153), control2: CGPoint(x: 0.7917083, y: 0.5975208))
        path.addCurve(to: CGPoint(x: 0.7921944, y: 0.4372354), control1: CGPoint(x: 0.8272361, y: 0.5180604), control2: CGPoint(x: 0.8194028, y: 0.4748319))
        path.addCurve(to: CGPoint(x: 0.6792014, y: 0.3136799), control1: CGPoint(x: 0.7627639, y: 0.3965875), control2: CGPoint(x: 0.7133889, y: 0.3395292))
        path.addCurve(to: CGPoint(x: 0.4710069, y: 0.2568563), control1: CGPoint(x: 0.6162014, y: 0.2660229), control2: CGPoint(x: 0.5361458, y: 0.2590278))
        path.addLine(to: CGPoint(x: 0.4523125, y: 0.2561646))
        path.addCurve(to: CGPoint(x: 0.2617569, y: 0.2542111), control1: CGPoint(x: 0.4221111, y: 0.2549042), control2: CGPoint(x: 0.4163611, y: 0.2542111))
        path.addLine(to: CGPoint(x: 0.2617569, y: 0.2542722))
        path.addCurve(to: CGPoint(x: 0.0637819, y: 0.2544965), control1: CGPoint(x: 0.2617569, y: 0.2542722), control2: CGPoint(x: 0.1309444, y: 0.2543556))
        path.addCurve(to: CGPoint(x: 0.4994722, y: 0.0000000), control1: CGPoint(x: 0.1497215, y: 0.1026889), control2: CGPoint(x: 0.3124583, y: 0.0000000))
        path.closeSubpath()
        path.move(to: CGPoint(x: 0.7655625, y: 0.5289917))
        path.addCurve(to: CGPoint(x: 0.7107153, y: 0.5690306), control1: CGPoint(x: 0.7598333, y: 0.5511576), control2: CGPoint(x: 0.7422014, y: 0.5690306))
        path.addLine(to: CGPoint(x: 0.0042722, y: 0.5690306))
        path.addCurve(to: CGPoint(x: 0.0003868, y: 0.5289917), control1: CGPoint(x: 0.0024507, y: 0.5558674), control2: CGPoint(x: 0.0011875, y: 0.5425153))
        path.addLine(to: CGPoint(x: 0.7655625, y: 0.5289917))
        path.closeSubpath()
        path.move(to: CGPoint(x: 0.2616181, y: 0.3044229))
        path.addCurve(to: CGPoint(x: 0.4501319, y: 0.3063354), control1: CGPoint(x: 0.3942222, y: 0.3044229), control2: CGPoint(x: 0.4168194, y: 0.3049653))
        path.addCurve(to: CGPoint(x: 0.7497778, y: 0.4638062), control1: CGPoint(x: 0.5500556, y: 0.3105972), control2: CGPoint(x: 0.6199236, y: 0.2960458))
        path.addCurve(to: CGPoint(x: 0.7595833, y: 0.4782514), control1: CGPoint(x: 0.7533681, y: 0.4683785), control2: CGPoint(x: 0.7569306, y: 0.4730694))
        path.addLine(to: CGPoint(x: 0.0000000, y: 0.4782514))
        path.addCurve(to: CGPoint(x: 0.0046389, y: 0.4278972), control1: CGPoint(x: 0.0007125, y: 0.4614035), control2: CGPoint(x: 0.0022569, y: 0.4445910))
        path.addLine(to: CGPoint(x: 0.4039097, y: 0.4278972))
        path.addLine(to: CGPoint(x: 0.4039097, y: 0.3771972))
        path.addLine(to: CGPoint(x: 0.0146688, y: 0.3771972))
        path.addCurve(to: CGPoint(x: 0.0383507, y: 0.3047889), control1: CGPoint(x: 0.0192361, y: 0.3564965), control2: CGPoint(x: 0.0286243, y: 0.3310431))
        path.addCurve(to: CGPoint(x: 0.2616181, y: 0.3044229), control1: CGPoint(x: 0.1134861, y: 0.3045889), control2: CGPoint(x: 0.1906444, y: 0.3044229))
        path.closeSubpath()
        return path.applying(CGAffineTransform(scaleX: rect.width, y: rect.height))
    }
}

/// An SF Symbol, or a brand mark for the few names that have one ("railway").
struct SymbolIcon: View {
    let name: String
    var size: CGFloat = 12

    var body: some View {
        if name == "railway" {
            RailwayMark().frame(width: size * 1.15, height: size * 1.15)
        } else if name == "logo.gemini" {
            GeminiMark().frame(width: size * 1.2, height: size * 1.2)
        } else if name.hasPrefix("logo."), let logo = ProviderLogos.image(String(name.dropFirst(5))) {
            Image(nsImage: logo).renderingMode(.template).resizable().scaledToFit()
                .frame(width: size * 1.2, height: size * 1.2)
        } else {
            Image(systemName: name).font(.system(size: size))
        }
    }
}

/// Gemini's four-pointed spark: each side is a shallow arc bowing toward the
/// center (radius about 64% of the mark, as in the official symbol).
struct GeminiMark: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        // Quad control between the center and the corner each side faces.
        func control(_ cx: CGFloat, _ cy: CGFloat) -> CGPoint {
            CGPoint(x: c.x + (cx - c.x) * 0.155, y: c.y + (cy - c.y) * 0.155)
        }
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY), control: control(rect.maxX, rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.maxY), control: control(rect.maxX, rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.midY), control: control(rect.minX, rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY), control: control(rect.minX, rect.minY))
        path.closeSubpath()
        return path
    }
}

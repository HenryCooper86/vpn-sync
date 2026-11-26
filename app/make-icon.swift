// Renders the 1024×1024 app icon: a frosted glass shield on a midnight tile; inside it, nested
// shield outlines narrow like a tunnel toward a glowing keyhole (VPN + security).
// Usage: `swift make-icon.swift out.png`
import AppKit
import CoreGraphics

let S: CGFloat = 1024
let out = CommandLine.arguments[1]
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                                         CGFloat(hex & 0xFF) / 255, a])!
}
func white(_ a: CGFloat) -> CGColor { CGColor(colorSpace: cs, components: [1, 1, 1, a])! }
func grad(_ colors: [CGColor], _ locs: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs)!
}

/// A shield: flat top with rounded corners, straight sides, curving to a point at the bottom.
func shield(_ r: CGRect) -> CGPath {
    let p = CGMutablePath()
    let c = r.width * 0.16                       // top corner radius
    let shoulder = r.minY + r.height * 0.50       // where the sides start curving in
    p.move(to: CGPoint(x: r.minX, y: r.maxY - c))
    p.addQuadCurve(to: CGPoint(x: r.minX + c, y: r.maxY), control: CGPoint(x: r.minX, y: r.maxY))
    // top edge dips slightly in the middle, like a heater shield
    p.addQuadCurve(to: CGPoint(x: r.maxX - c, y: r.maxY), control: CGPoint(x: r.midX, y: r.maxY - r.height * 0.05))
    p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY - c), control: CGPoint(x: r.maxX, y: r.maxY))
    p.addLine(to: CGPoint(x: r.maxX, y: shoulder))
    p.addCurve(to: CGPoint(x: r.midX, y: r.minY),
               control1: CGPoint(x: r.maxX, y: r.minY + r.height * 0.22),
               control2: CGPoint(x: r.midX + r.width * 0.20, y: r.minY + r.height * 0.06))
    p.addCurve(to: CGPoint(x: r.minX, y: shoulder),
               control1: CGPoint(x: r.midX - r.width * 0.20, y: r.minY + r.height * 0.06),
               control2: CGPoint(x: r.minX, y: r.minY + r.height * 0.22))
    p.closeSubpath()
    return p
}

/// The same path scaled toward a focal point (for the tunnel rings).
func scaled(_ path: CGPath, by k: CGFloat, toward f: CGPoint) -> CGPath {
    var t = CGAffineTransform(translationX: f.x, y: f.y).scaledBy(x: k, y: k).translatedBy(x: -f.x, y: -f.y)
    return path.copy(using: &t)!
}

// macOS icon grid: 824×824 body centred in 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let tile = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

// Tile shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: CGColor(colorSpace: cs, components: [0, 0, 0, 0.38])!)
ctx.addPath(tile); ctx.setFillColor(rgb(0x0D1B2E)); ctx.fillPath()
ctx.restoreGState()

// Tile: midnight blue, lighter at the top, a soft cyan glow behind where the shield sits
ctx.saveGState()
ctx.addPath(tile); ctx.clip()
ctx.drawLinearGradient(grad([rgb(0x243F66), rgb(0x0B1628)], [0, 1]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.drawRadialGradient(grad([rgb(0x3FA9F5, 0.40), rgb(0x3FA9F5, 0)], [0, 1]),
                       startCenter: CGPoint(x: 512, y: 470), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 470), endRadius: 430, options: [])
ctx.drawLinearGradient(grad([white(0.14), white(0)], [0, 1]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 660), options: [])
ctx.restoreGState()

// Glass shield
let sr = CGRect(x: 512 - 285, y: 178, width: 570, height: 606)
let sp = shield(sr)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -20), blur: 44, color: CGColor(colorSpace: cs, components: [0, 0, 0, 0.45])!)
ctx.addPath(sp); ctx.setFillColor(white(0.10)); ctx.fillPath()
ctx.restoreGState()

let focus = CGPoint(x: sr.midX, y: sr.minY + sr.height * 0.46)   // where the tunnel leads: the keyhole
ctx.saveGState()
ctx.addPath(sp); ctx.clip()
// frosted body, brighter at the top
ctx.drawLinearGradient(grad([white(0.30), white(0.10), white(0.16)], [0, 0.55, 1]),
                       start: CGPoint(x: sr.midX, y: sr.maxY), end: CGPoint(x: sr.midX, y: sr.minY), options: [])
// light at the end of the tunnel
ctx.drawRadialGradient(grad([rgb(0x5EF0C8, 0.55), rgb(0x3FA9F5, 0.18), rgb(0x3FA9F5, 0)], [0, 0.45, 1]),
                       startCenter: focus, startRadius: 0, endCenter: focus, endRadius: 280, options: [])
// tunnel: nested shields shrinking toward the keyhole
let rings = 5
for i in 1...rings {
    let f = CGFloat(i) / CGFloat(rings + 1)
    let k = 1 - 0.82 * (1 - pow(1 - f, 1.9))
    ctx.addPath(scaled(sp, by: k, toward: focus))
    ctx.setStrokeColor(white(0.55 - 0.42 * f))
    ctx.setLineWidth(12 - 8 * f)
    ctx.setLineJoin(.round)
    ctx.strokePath()
}
ctx.restoreGState()

// Keyhole of light
let kh = CGMutablePath()
kh.addEllipse(in: CGRect(x: focus.x - 36, y: focus.y - 6, width: 72, height: 72))
kh.move(to: CGPoint(x: focus.x - 18, y: focus.y + 6))
kh.addLine(to: CGPoint(x: focus.x + 18, y: focus.y + 6))
kh.addLine(to: CGPoint(x: focus.x + 29, y: focus.y - 80))
kh.addQuadCurve(to: CGPoint(x: focus.x - 29, y: focus.y - 80), control: CGPoint(x: focus.x, y: focus.y - 89))
kh.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 40, color: rgb(0x5EF0C8, 1))
ctx.addPath(kh); ctx.setFillColor(rgb(0x8AF7D6)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(kh); ctx.clip()
ctx.drawLinearGradient(grad([white(0.85), rgb(0x8AF7D6, 0)], [0, 1]),
                       start: CGPoint(x: focus.x, y: focus.y + 56), end: CGPoint(x: focus.x, y: focus.y - 20), options: [])
ctx.restoreGState()

// Shield rim: bright at the top left, fading round
ctx.saveGState()
ctx.addPath(sp)
ctx.setLineWidth(10)
ctx.setLineJoin(.round)
ctx.replacePathWithStrokedPath(); ctx.clip()
ctx.drawLinearGradient(grad([white(0.90), white(0.18), white(0.45)], [0, 0.6, 1]),
                       start: CGPoint(x: sr.minX, y: sr.maxY), end: CGPoint(x: sr.maxX, y: sr.minY), options: [])
ctx.restoreGState()
// Specular sheen along the upper-left of the shield
ctx.saveGState()
ctx.addPath(sp); ctx.clip()
ctx.setLineCap(.round)
ctx.setLineWidth(18)
ctx.setStrokeColor(white(0.35))
ctx.move(to: CGPoint(x: sr.minX + 44, y: sr.maxY - 150))
ctx.addQuadCurve(to: CGPoint(x: sr.minX + 150, y: sr.maxY - 40), control: CGPoint(x: sr.minX + 46, y: sr.maxY - 46))
ctx.strokePath()
ctx.restoreGState()

// Hairline rim on the tile
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 185, cornerHeight: 185, transform: nil))
ctx.setStrokeColor(white(0.16)); ctx.setLineWidth(3); ctx.strokePath()

let img = ctx.makeImage()!
try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))

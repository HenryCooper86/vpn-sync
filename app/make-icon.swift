// Renders the 1024×1024 app icon: a frosted glass shield on a midnight tile with a glowing key
// inside (Lucide's key-round, the same icon family as the app). VPN + security.
// Usage: `swift make-icon.swift out.png` (run from app/, reads lucide/key-round.svg)
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

let focus = CGPoint(x: sr.midX, y: sr.minY + sr.height * 0.50)
ctx.saveGState()
ctx.addPath(sp); ctx.clip()
// frosted body, brighter at the top
ctx.drawLinearGradient(grad([white(0.30), white(0.10), white(0.16)], [0, 0.55, 1]),
                       start: CGPoint(x: sr.midX, y: sr.maxY), end: CGPoint(x: sr.midX, y: sr.minY), options: [])
// soft light behind the key
ctx.drawRadialGradient(grad([rgb(0x5EF0C8, 0.42), rgb(0x3FA9F5, 0.14), rgb(0x3FA9F5, 0)], [0, 0.5, 1]),
                       startCenter: focus, startRadius: 0, endCenter: focus, endRadius: 300, options: [])
ctx.restoreGState()

// The key: Lucide key-round, filled with a mint-to-cyan gradient, glowing
let keySize: CGFloat = 380
let keyRect = CGRect(x: focus.x - keySize / 2, y: focus.y - keySize / 2, width: keySize, height: keySize)
let keyImage: CGImage = {
    let px = Int(keySize * 2)
    let k = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                      space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let svg = NSImage(contentsOfFile: "lucide/key-round.svg")!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: k, flipped: false)
    svg.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    k.setBlendMode(.sourceIn)                       // keep the key's shape, replace its colour
    k.drawLinearGradient(grad([rgb(0xB8FFE9), rgb(0x5EF0C8), rgb(0x3FA9F5)], [0, 0.45, 1]),
                         start: CGPoint(x: CGFloat(px), y: CGFloat(px)), end: CGPoint(x: 0, y: 0), options: [])
    return k.makeImage()!
}()
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 36, color: rgb(0x5EF0C8, 0.95))
ctx.draw(keyImage, in: keyRect)
ctx.restoreGState()
ctx.draw(keyImage, in: keyRect)

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

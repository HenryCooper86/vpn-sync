// Renders the 1024×1024 app icon: a glass lens on the Aurora colour field, with signal arcs
// rippling out from a glowing core. Usage: `swift make-icon.swift out.png`
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

// macOS icon grid: 824×824 body centred in 1024 with a continuous-corner squircle.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

// Drop shadow under the tile
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: CGColor(colorSpace: cs, components: [0, 0, 0, 0.38])!)
ctx.addPath(squircle); ctx.setFillColor(rgb(0x0E2A3B)); ctx.fillPath()
ctx.restoreGState()

// Colour field: deep base, violet glow top-right, teal glow bottom-left
ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
ctx.drawLinearGradient(grad([rgb(0x123A50), rgb(0x0B2030)], [0, 1]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.drawRadialGradient(grad([rgb(0x7B61FF, 0.85), rgb(0x7B61FF, 0)], [0, 1]),
                       startCenter: CGPoint(x: 860, y: 880), startRadius: 0,
                       endCenter: CGPoint(x: 860, y: 880), endRadius: 560, options: [])
ctx.drawRadialGradient(grad([rgb(0x2EC4B6, 0.8), rgb(0x2EC4B6, 0)], [0, 1]),
                       startCenter: CGPoint(x: 170, y: 150), startRadius: 0,
                       endCenter: CGPoint(x: 170, y: 150), endRadius: 600, options: [])
// Top sheen on the tile
ctx.drawLinearGradient(grad([white(0.16), white(0)], [0, 1]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
ctx.restoreGState()

// Glass lens
let lc = CGPoint(x: 512, y: 500)
let lr: CGFloat = 278
let lens = CGRect(x: lc.x - lr, y: lc.y - lr, width: lr * 2, height: lr * 2)
// soft shadow under the lens
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: CGColor(colorSpace: cs, components: [0, 0, 0, 0.35])!)
ctx.addEllipse(in: lens); ctx.setFillColor(white(0.10)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addEllipse(in: lens); ctx.clip()
// body: frosted, brighter at the top
ctx.drawLinearGradient(grad([white(0.30), white(0.08), white(0.14)], [0, 0.55, 1]),
                       start: CGPoint(x: lc.x, y: lc.y + lr), end: CGPoint(x: lc.x, y: lc.y - lr), options: [])
// The tunnel: rings shrinking and drifting toward the far end, where the core glows
let core = CGPoint(x: lc.x + 78, y: lc.y + 66)
ctx.drawRadialGradient(grad([rgb(0x34D399, 0.65), rgb(0x2EC4B6, 0.22), rgb(0x2EC4B6, 0)], [0, 0.4, 1]),
                       startCenter: core, startRadius: 0, endCenter: core, endRadius: 260, options: [])
let ringCount = 7
for i in 0..<ringCount {
    let f = CGFloat(i) / CGFloat(ringCount)               // 0 = mouth, → far end
    let ease = 1 - pow(1 - f, 2.6)
    let r = lr * (0.93 - 0.86 * ease)
    let c = CGPoint(x: lc.x + (core.x - lc.x) * ease, y: lc.y + (core.y - lc.y) * ease)
    ctx.setStrokeColor(white(0.55 - 0.40 * f))
    ctx.setLineWidth(14 - 9 * f)
    ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    ctx.strokePath()
}
ctx.restoreGState()

// The core: a glowing signal-green light at the end of the tunnel
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 40, color: rgb(0x34D399, 1))
ctx.addEllipse(in: CGRect(x: core.x - 30, y: core.y - 30, width: 60, height: 60))
ctx.setFillColor(rgb(0x6CF5C8)); ctx.fillPath()
ctx.restoreGState()
ctx.addEllipse(in: CGRect(x: core.x - 13, y: core.y - 3, width: 16, height: 13))
ctx.setFillColor(white(0.8)); ctx.fillPath()

// Lens rim: bright at the top left, fading round the edge
ctx.saveGState()
ctx.addEllipse(in: lens.insetBy(dx: 3, dy: 3))
ctx.setLineWidth(6)
ctx.replacePathWithStrokedPath(); ctx.clip()
ctx.drawLinearGradient(grad([white(0.85), white(0.15), white(0.45)], [0, 0.6, 1]),
                       start: CGPoint(x: lc.x - lr, y: lc.y + lr), end: CGPoint(x: lc.x + lr, y: lc.y - lr), options: [])
ctx.restoreGState()
// Specular crescent along the upper-left rim, like light on real glass
ctx.saveGState()
ctx.setLineCap(.round)
ctx.setLineWidth(16)
ctx.setStrokeColor(white(0.55))
ctx.addArc(center: lc, radius: lr - 26, startAngle: .pi * 0.62, endAngle: .pi * 0.92, clockwise: false)
ctx.strokePath()
ctx.setLineWidth(8)
ctx.setStrokeColor(white(0.30))
ctx.addArc(center: lc, radius: lr - 26, startAngle: .pi * 0.40, endAngle: .pi * 0.55, clockwise: false)
ctx.strokePath()
ctx.restoreGState()

// Hairline rim on the tile
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 185, cornerHeight: 185, transform: nil))
ctx.setStrokeColor(white(0.18)); ctx.setLineWidth(3); ctx.strokePath()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))

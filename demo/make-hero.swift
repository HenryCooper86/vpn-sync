// Composes the README's hero image: the Mac window with the iPhone in front of it.
// Usage: swift demo/make-hero.swift mac.png iphone.png out.png
import AppKit

let a = CommandLine.arguments
guard a.count >= 4, let mac = NSImage(contentsOfFile: a[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let phone = NSImage(contentsOfFile: a[2])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("usage: swift make-hero.swift mac.png iphone.png out.png"); exit(1)
}
let W = 1560.0, H = 1240.0
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high

// background: a deep blue-violet wash, like the app's backdrop
let bg = CGGradient(colorsSpace: cs, colors: [CGColor(red: 0.10, green: 0.13, blue: 0.27, alpha: 1),
                                             CGColor(red: 0.22, green: 0.16, blue: 0.40, alpha: 1),
                                             CGColor(red: 0.08, green: 0.20, blue: 0.30, alpha: 1)] as CFArray,
                    locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])
for (x, y, r, c) in [(420.0, 900.0, 520.0, CGColor(red: 0.35, green: 0.45, blue: 1, alpha: 0.28)),
                     (1450.0, 300.0, 480.0, CGColor(red: 0.75, green: 0.35, blue: 1, alpha: 0.22))] {
    let g = CGGradient(colorsSpace: cs, colors: [c, CGColor(red: 0, green: 0, blue: 0, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: CGPoint(x: x, y: y), startRadius: 0, endCenter: CGPoint(x: x, y: y), endRadius: r, options: [])
}

func place(_ img: CGImage, height h: Double, x: Double, y: Double, radius: Double, shadow: Double) -> CGRect {
    let w = h * Double(img.width) / Double(img.height)
    let r = CGRect(x: x, y: y, width: w, height: h)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: shadow, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.5))
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(CGColor(gray: 0.1, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)); ctx.clip()
    ctx.draw(img, in: r)
    ctx.restoreGState()
    return r
}

// the Mac window on the left, the phone overlapping its right edge, in a thin bezel; centred
let mh = 1080.0, mw = mh * Double(mac.width) / Double(mac.height)
let ph = 960.0, pw = ph * Double(phone.width) / Double(phone.height)
let overlap = 150.0
let left = (W - (mw + pw - overlap)) / 2
let px = left + mw - overlap, py = 60.0
_ = place(mac, height: mh, x: left, y: 100, radius: 22, shadow: 60)
let bezel = CGRect(x: px - 14, y: py - 14, width: pw + 28, height: ph + 28)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -24), blur: 70, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
ctx.addPath(CGPath(roundedRect: bezel, cornerWidth: 70, cornerHeight: 70, transform: nil))
ctx.setFillColor(CGColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1)); ctx.fillPath()
ctx.restoreGState()
_ = place(phone, height: ph, x: px, y: py, radius: 58, shadow: 0)

try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: a[3]))
print("wrote \(a[3])")

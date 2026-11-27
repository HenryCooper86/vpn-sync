// Makes the iPhone app icon from your own picture, like the Mac app does: app/logo.local.png
// (kept out of git) → ios/VPNSyncPhone/Assets.xcassets/AppIconLocal.appiconset (also kept out
// of git). Then put  VPNSYNC_APP_ICON = AppIconLocal  in ios/Local.xcconfig.
// Usage (from ios/): swift make-local-icon.swift
import AppKit

let src = "../app/logo.local.png"
let dir = "VPNSyncPhone/Assets.xcassets/AppIconLocal.appiconset"
guard let pic = NSImage(contentsOfFile: src), let cg = pic.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("no picture at app/logo.local.png"); exit(1)
}
let S = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.interpolationQuality = .high
// fill the square, cropping the longer side (iOS rounds the corners itself)
let w = CGFloat(cg.width), h = CGFloat(cg.height), k = max(CGFloat(S) / w, CGFloat(S) / h)
ctx.draw(cg, in: CGRect(x: CGFloat(S) / 2 - w * k / 2, y: CGFloat(S) / 2 - h * k / 2, width: w * k, height: h * k))
// the same soft top highlight as the Mac icon
let g = CGGradient(colorsSpace: cs, colors: [CGColor(gray: 1, alpha: 0.16), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(g, start: CGPoint(x: 512, y: 1024), end: CGPoint(x: 512, y: 760), options: [])
try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: dir + "/icon-1024.png"))
try! """
{
  "images" : [ { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ],
  "info" : { "author" : "xcode", "version" : 1 }
}
""".write(toFile: dir + "/Contents.json", atomically: true, encoding: .utf8)
print("wrote \(dir); set VPNSYNC_APP_ICON = AppIconLocal in ios/Local.xcconfig")

// vpn-sync-demo: stands in for the vpn-sync command so the Mac app can run on made-up data
// (for screenshots, or to try the app without a server). See demo/run-mac-demo.sh.
//   vpn-sync-demo setup DIR            make a demo home in DIR (configs, Desktop profiles, this command)
//   vpn-sync-demo watch SERVER [--interval N] | status SERVER | usage SERVER --raw | …
import Foundation
import AppKit
import CoreImage

let args = Array(CommandLine.arguments.dropFirst())
let out = FileHandle.standardOutput
func say(_ s: String) { out.write(Data((s + "\n").utf8)) }

func qrPNG(_ text: String) -> Data? {
    guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    f.setValue(Data(text.utf8), forKey: "inputMessage")
    f.setValue("M", forKey: "inputCorrectionLevel")
    guard let img = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
          let cg = CIContext().createCGImage(img, from: img.extent) else { return nil }
    return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
}

func setup(_ dir: String) throws {
    let fm = FileManager.default
    let home = URL(fileURLWithPath: dir)
    let cfg = home.appendingPathComponent(".config/vpn-sync"), bin = home.appendingPathComponent(".local/bin")
    try fm.createDirectory(at: cfg, withIntermediateDirectories: true)
    try fm.createDirectory(at: bin, withIntermediateDirectories: true)
    // the offline country table, if this Mac has one (so flags show)
    let realGeo = fm.homeDirectoryForCurrentUser.appendingPathComponent(".config/vpn-sync/geo")
    let geo = cfg.appendingPathComponent("geo")
    if fm.fileExists(atPath: realGeo.path), !fm.fileExists(atPath: geo.path) { try fm.createSymbolicLink(at: geo, withDestinationURL: realGeo) }
    var known = ""
    for s in DemoData.servers {
        var conf = "HOST=\(s.ip)\nSSH_USER=ubuntu\nSSH_KEY=\(cfg.path)/keys/demo.pem\nSSH_PORT=22\nHOST_ALIAS=\(s.name.lowercased())\n"
        if let j = s.jump { conf += "JUMP=\(j)\nPRIVATE_IP=172.31.0.\(20 + s.name.count)\n" }
        conf += "DEST_PARENT=\(home.path)/Desktop\n"
        try conf.write(to: cfg.appendingPathComponent("\(s.name).conf"), atomically: true, encoding: .utf8)
        try s.ip.write(to: cfg.appendingPathComponent("\(s.name).last-ip"), atomically: true, encoding: .utf8)
        known += "\(s.name.lowercased()) ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDemoDemoDemoDemoDemoDemoDemoDemoDemoDemo\n"
        let folder = home.appendingPathComponent("Desktop/\(s.name)-\(s.ip)")
        for sub in ["OpenVPN", "WireGuard", "IKEv2"] where sub != "IKEv2" || s.ipsec {
            try fm.createDirectory(at: folder.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        for d in s.devices {
            for p in DemoData.profiles(d.name, server: s.name) {
                let ext = (p.file as NSString).pathExtension
                let sub = ext == "conf" ? "WireGuard" : ext == "ovpn" ? "OpenVPN" : "IKEv2"
                let url = folder.appendingPathComponent("\(sub)/\(p.file)")
                try p.text.write(to: url, atomically: true, encoding: .utf8)
                if ext == "conf", let png = qrPNG(p.text) {
                    try png.write(to: folder.appendingPathComponent("WireGuard/\(d.name)-wireguard-qr.png"))
                }
            }
        }
    }
    try known.write(to: cfg.appendingPathComponent("known_hosts"), atomically: true, encoding: .utf8)
    let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let cli = bin.appendingPathComponent("vpn-sync")
    try? fm.removeItem(at: cli)
    try fm.copyItem(at: me, to: cli)
    say("demo home ready: \(home.path)")
}

func server(after i: Int) -> String? { args.count > i ? args[i] : nil }

switch args.first ?? "" {
case "setup":
    do { try setup(server(after: 1) ?? "demo-home") } catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
case "watch":
    guard let s = server(after: 1), DemoData.server(s) != nil else { exit(1) }
    var interval: UInt32 = 3
    if let i = args.firstIndex(of: "--interval"), args.count > i + 1, let n = UInt32(args[i + 1]) { interval = max(1, n) }
    say("WATCHING\t\(s)\t\(interval)")
    var n = 0
    while true {
        for line in DemoData.snapshot(s, full: n % 10 == 0) { say(line) }
        n += 1
        sleep(interval)
    }
case "status":
    guard let s = server(after: 1) else { exit(1) }
    for line in DemoData.snapshot(s) { say(line) }
case "usage", "limits":
    guard let s = server(after: 1) else { exit(1) }
    for line in DemoData.usage(s) { say(line) }
case "aws":
    say("KEY=none")
case "server":
    if server(after: 1) == "list" { for s in DemoData.servers { say("\(s.name)\t\(s.ip)") } }
default:
    // a sync or check: report the server as up to date
    let names = args.filter { a in DemoData.server(a) != nil }
    for s in names.isEmpty ? DemoData.servers.map(\.name) : names {
        guard let d = DemoData.server(s) else { continue }
        say("== \(s)")
        say("  trying \(d.ip)    ok")
        say("  server: up to date: all configs use \(d.ip)")
        say("  profiles: \(d.devices.count) OpenVPN, \(d.devices.count) WireGuard\(d.ipsec ? ", \(d.devices.count) IKEv2" : "")")
    }
}

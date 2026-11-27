// Shared by the Mac and iPhone apps (Foundation only).
// Made-up servers, devices and traffic for screenshots and trying the apps without a server:
// the same lines vpn-status and vpn-usage print, computed from the clock so speeds move
// smoothly and some devices connect and disconnect. Names are invented; server addresses are
// from the documentation range (198.51.100.0/24) and device addresses are GeoIP test addresses.
import Foundation

enum DemoData {
    struct Device {
        let name: String
        let vpn: String            // OpenVPN, WireGuard, IKEv2
        let ip: String             // where it connects from
        let platform: String?      // what an OpenVPN client reports
        let app: String?
        let down: Double           // typical download, bytes/s
        let up: Double
        let phase: Double
        /// online in this many of every 6 slots of `slot` seconds (6 = always, 0 = never)
        let presence: Int
        let monthMB: Double        // data before today, this month
    }
    struct Server {
        let name: String
        let ip: String
        let ipsec: Bool
        let jump: String?
        let devices: [Device]
        let limits: [(name: String, daily: Int64, monthly: Int64, pause: Bool)]
        let paused: [(name: String, reason: String)]
    }

    static let servers: [Server] = [
        Server(name: "Tokyo", ip: "198.51.100.24", ipsec: true, jump: nil, devices: [
            Device(name: "macbook-pro", vpn: "WireGuard", ip: "89.160.20.112", platform: nil, app: nil, down: 2_400_000, up: 310_000, phase: 0.0, presence: 6, monthMB: 41_000),
            Device(name: "alex-iphone", vpn: "IKEv2", ip: "81.2.69.142", platform: nil, app: nil, down: 640_000, up: 90_000, phase: 1.3, presence: 6, monthMB: 12_800),
            Device(name: "pixel-8", vpn: "OpenVPN", ip: "216.160.83.56", platform: "android", app: "OpenVPN Connect 3.4.2", down: 380_000, up: 60_000, phase: 2.1, presence: 6, monthMB: 6_900),
            Device(name: "living-room-tv", vpn: "WireGuard", ip: "2.125.160.216", platform: nil, app: nil, down: 3_100_000, up: 45_000, phase: 0.7, presence: 4, monthMB: 58_000),
            Device(name: "ipad", vpn: "WireGuard", ip: "81.2.69.160", platform: nil, app: nil, down: 150_000, up: 20_000, phase: 3.0, presence: 0, monthMB: 2_100),
            Device(name: "work-laptop", vpn: "OpenVPN", ip: "89.160.20.128", platform: "win", app: "OpenVPN Connect 3.5.0", down: 0, up: 0, phase: 0, presence: 0, monthMB: 20_300),
            Device(name: "guest", vpn: "WireGuard", ip: "216.160.83.61", platform: nil, app: nil, down: 90_000, up: 12_000, phase: 4.2, presence: 2, monthMB: 650),
        ], limits: [("work-laptop", 0, 20 * 1_073_741_824, true), ("guest", 1_073_741_824, 0, false)],
           paused: [("work-laptop", "monthly")]),
        Server(name: "Frankfurt", ip: "198.51.100.77", ipsec: false, jump: nil, devices: [
            Device(name: "office-pc", vpn: "OpenVPN", ip: "89.160.20.115", platform: "win", app: "OpenVPN Connect 3.5.0", down: 820_000, up: 240_000, phase: 0.4, presence: 6, monthMB: 22_400),
            Device(name: "nas", vpn: "WireGuard", ip: "2.125.160.218", platform: nil, app: nil, down: 120_000, up: 1_400_000, phase: 1.9, presence: 6, monthMB: 96_000),
            Device(name: "router", vpn: "WireGuard", ip: "81.2.69.150", platform: nil, app: nil, down: 0, up: 0, phase: 0, presence: 0, monthMB: 0),
        ], limits: [], paused: []),
        Server(name: "Oregon", ip: "198.51.100.140", ipsec: false, jump: "Tokyo", devices: [
            Device(name: "dev-box", vpn: "WireGuard", ip: "216.160.83.58", platform: nil, app: nil, down: 510_000, up: 160_000, phase: 2.6, presence: 6, monthMB: 8_300),
            Device(name: "kids-tablet", vpn: "WireGuard", ip: "216.160.83.62", platform: nil, app: nil, down: 900_000, up: 40_000, phase: 1.1, presence: 5, monthMB: 6_550),
        ], limits: [("kids-tablet", 0, 8 * 1_073_741_824, true)], paused: []),
    ]

    static func server(_ name: String) -> Server? { servers.first { $0.name == name } }

    /// Counters start at midnight (UTC), so they only reset once a day.
    private static func origin(_ t: Double) -> Double { floor(t / 86_400) * 86_400 }

    /// Seconds a device has been online up to `t` (on a timeline where it's online `presence`
    /// of every 6 slots), so its counters stand still while it's offline.
    static func onlineClock(_ d: Device, _ t: Double) -> Double {
        if d.presence >= 6 { return t }
        if d.presence <= 0 { return origin(t) }
        let cycle = slot * 6, on = Double(d.presence) * slot
        let k = floor(t / cycle), r = t - k * cycle
        return k * on + min(r, on)
    }

    /// How long each presence slot lasts: short, so connects and disconnects show up often.
    static let slot = 50.0

    static func online(_ d: Device, at t: Double) -> Bool {
        guard d.presence > 0 else { return false }
        if d.presence >= 6 { return true }
        let n = Int(t / slot) % 6
        return n < d.presence
    }

    /// Speed now (bytes/s): a slow wave plus a faster one, never below a trickle.
    static func rate(_ base: Double, _ phase: Double, at t: Double) -> Double {
        guard base > 0 else { return 0 }
        // 0.65 - 0.35 - 0.25 > 0: always positive, so the counter below only ever grows
        return base * (0.65 + 0.35 * sin(t / 37 + phase) + 0.25 * sin(t / 9.3 + phase * 2))
    }

    /// Bytes since `origin` for rate(base, phase): integral of the wave above (approximated by
    /// summing whole seconds, which is plenty smooth at 3-second snapshots).
    static func counter(_ base: Double, _ phase: Double, at t: Double, from o: Double? = nil) -> Int64 {
        guard base > 0 else { return 0 }
        let o = o ?? origin(t)
        let a = base * 0.65, b = base * 0.35, c = base * 0.25
        let f = { (x: Double) in a * x - b * 37 * cos(x / 37 + phase) - c * 9.3 * cos(x / 9.3 + phase * 2) }
        return Int64(max(0, f(t) - f(o)))
    }

    /// A device's byte counter (from the server's view: up = received, down = sent), counting
    /// only while it's online.
    static func deviceCounter(_ d: Device, up: Bool, at t: Double) -> Int64 {
        counter(up ? d.up : d.down, d.phase, at: onlineClock(d, t), from: onlineClock(d, origin(t)))
    }

    /// A made-up source port for a demo device.
    static func demoPort(_ i: Int) -> Int { 49_152 + (i * 7_919) % 16_000 }

    static func vpnIP(_ s: Server, _ i: Int, _ d: Device) -> String {
        switch d.vpn {
        case "OpenVPN": return "10.8.0.\(i + 2)"
        case "IKEv2": return "192.168.43.\(i + 10)"
        default: return "10.7.0.\(i + 2)"
        }
    }

    /// One vpn-status snapshot (with TOTALS/DAY/DEVINFO/usage when `full`).
    static func snapshot(_ name: String, at now: Date = Date(), full: Bool = true) -> [String] {
        guard let s = server(name) else { return ["END"] }
        let t = now.timeIntervalSince1970, ti = Int(t)
        let up = ti - 12 * 86_400 - 3_700
        var out = ["SNAPSHOT\t\(ti)",
                   "SERVICE\topenvpn\tactive\t\(up)", "SERVICE\twireguard\tactive\t\(up)",
                   "SERVICE\tipsec\t\(s.ipsec ? "active\t\(up + 40)" : "missing\t0")"]
        let fileTime = ti - ti % 10
        out.append("OVPNTIME\t\(fileTime)")
        for (i, d) in s.devices.enumerated() {
            let on = online(d, at: t)
            let rx = deviceCounter(d, up: true, at: t), tx = deviceCounter(d, up: false, at: t)
            switch d.vpn {
            case "OpenVPN" where on:
                let ft = Double(fileTime)
                out.append("OVPN\t\(d.name)\t\(d.ip)\t\(vpnIP(s, i, d))\t\(deviceCounter(d, up: true, at: ft))\t\(deviceCounter(d, up: false, at: ft))\t\(ti - 5_400 - i * 600)\t\(demoPort(i))")
            case "WireGuard":
                // offline peers keep their last handshake (minutes or days ago)
                let hs = on ? ti - 20 - i * 7 : (d.presence > 0 ? ti - 200 - i * 30 : ti - 3 * 86_400 - i * 3_600)
                out.append("WG\t\(d.name)\t\(on ? d.ip : "-")\t\(vpnIP(s, i, d))\t\(rx)\t\(tx)\t\(hs)\t\(on ? String(demoPort(i)) : "-")")
            case "IKEv2" where on:
                out.append("IKE\t\(d.name)\t\(d.ip)\t\(vpnIP(s, i, d))\t\(rx)\t\(tx)\t\(ti - 2_700)\t4500")
            default: break
            }
        }
        if full {
            out += ["PORT\topenvpn\ttcp\t443", "PORT\twireguard\tudp\t51820"]
            if s.ipsec { out += ["PORT\tipsec\tudp\t500", "PORT\tipsec\tudp\t4500"] }
            out.append("PORT\tssh\ttcp\t22")
            out += usage(name, at: now)
            let today = s.devices.reduce(0.0) { $0 + Double(deviceCounter($1, up: false, at: t) + deviceCounter($1, up: true, at: t)) } + 7.2e9
            let month = today + s.devices.reduce(0.0) { $0 + $1.monthMB * 1_048_576 }
            out.append("TOTALS\tens5\t\(Int64(today * 0.52))\t\(Int64(today * 0.48))\t\(Int64(month * 0.52))\t\(Int64(month * 0.48))")
            let cal = Calendar.current
            for k in stride(from: 29, through: 0, by: -1) {
                guard let day = cal.date(byAdding: .day, value: -k, to: now) else { continue }
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
                // a typical day: every device's average speed over the hours it's usually on
                let typical = s.devices.reduce(0.0) { $0 + ($1.down + $1.up) * 0.65 * Double($1.presence) / 6 * 86_400 * 0.45 }
                let wave = 0.8 + 0.3 * sin(Double(k) / 2.3 + Double(name.count)) + (cal.isDateInWeekend(day) ? 0.35 : 0)
                let total = k == 0 ? today : wave * typical
                out.append("DAY\t\(f.string(from: day))\t\(Int64(total * 0.53))\t\(Int64(total * 0.47))")
            }
            for d in s.devices { if let p = d.platform, let a = d.app { out.append("DEVINFO\t\(d.name)\t\(p)\t\(a)") } }
        }
        out.append("END")
        return out
    }

    /// The vpn-usage report: today = a base plus a slice of the live counters (so it grows, but
    /// at a believable pace all day), month = today + monthMB.
    static func usage(_ name: String, at now: Date = Date()) -> [String] {
        guard let s = server(name) else { return [] }
        let t = now.timeIntervalSince1970
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        var out = ["USAGEAT\t\(Int(t))\t\(f.string(from: now))"]
        for d in s.devices where d.monthMB > 0 || d.presence > 0 {
            let base = d.monthMB * 1_048_576 / 22
            let down = Int64(base * 0.9) + deviceCounter(d, up: false, at: t) / 12
            let up = Int64(base * 0.1) + deviceCounter(d, up: true, at: t) / 12
            let mDown = down + Int64(d.monthMB * 1_048_576 * 0.9), mUp = up + Int64(d.monthMB * 1_048_576 * 0.1)
            out.append("USAGE\t\(d.name)\t\(down)\t\(up)\t\(mDown)\t\(mUp)")
        }
        for l in s.limits { out.append("LIMIT\t\(l.name)\t\(l.daily)\t\(l.monthly)\t\(l.pause ? "pause" : "alert")") }
        for p in s.paused { out.append("PAUSED\t\(p.name)\t\(p.reason)\t\(f.string(from: now))") }
        return out
    }

    /// vpn-export-profiles --list
    static func deviceList(_ name: String) -> [String] {
        guard let s = server(name) else { return [] }
        return s.devices.map { "DEVICE\t\($0.name)\t1\t1\t\(s.ipsec ? 1 : 0)" }
    }

    /// Fake profile files for a device (no real keys).
    static func profiles(_ device: String, server name: String) -> [(file: String, text: String)] {
        guard let s = server(name), let i = s.devices.firstIndex(where: { $0.name == device }) else { return [] }
        func key(_ seed: String) -> String {
            var h: UInt64 = 1469598103934665603
            for b in (seed + device + name).utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
            var bytes: [UInt8] = []
            for _ in 0..<32 { h = h &* 6364136223846793005 &+ 1442695040888963407; bytes.append(UInt8(truncatingIfNeeded: h >> 33)) }
            return Data(bytes).base64EncodedString()
        }
        let d = s.devices[i]
        var out: [(String, String)] = [
            ("\(device).conf", """
            [Interface]
            Address = 10.7.0.\(i + 2)/24, fddd:2c4:2c4:2c4::\(i + 2)/64
            DNS = 1.1.1.1, 1.0.0.1
            PrivateKey = \(key("wg-priv"))

            [Peer]
            PublicKey = \(key("wg-server"))
            PresharedKey = \(key("wg-psk"))
            AllowedIPs = 0.0.0.0/0, ::/0
            Endpoint = \(s.ip):443
            PersistentKeepalive = 25

            """),
            ("\(device).ovpn", """
            client
            dev tun
            proto tcp
            remote \(s.ip) 443
            resolv-retry infinite
            nobind
            persist-key
            persist-tun
            remote-cert-tls server
            cipher AES-256-GCM
            # demo profile for \(d.name): certificates and keys left out

            """),
        ]
        if s.ipsec {
            out.append(("\(device).mobileconfig", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!-- demo IKEv2 profile for \(device) on \(s.ip) -->\n<plist version=\"1.0\"><dict/></plist>\n"))
            out.append(("\(device).sswan", "{\"uuid\":\"demo\",\"name\":\"\(s.ip)\",\"type\":\"ikev2-cert\",\"remote\":{\"addr\":\"\(s.ip)\"}}\n"))
            out.append(("\(device).p12", "demo"))
        }
        return out
    }
}

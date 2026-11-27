// One server, live: a `vpn-status --watch 3` stream over SSH while the app is open, turned
// into who's online on which VPN, speeds, services, usage and limits, and an activity log.
import SwiftUI

/// A device on the server, from its profiles (vpn-export-profiles --list).
struct DeviceInfo: Identifiable, Hashable {
    let name: String
    var openvpn = false, wireguard = false, ikev2 = false
    var id: String { name }
}

/// What a device is (from what its OpenVPN client reported, else its name) for the icon.
enum DeviceKind {
    case phone, tablet, laptop, desktop, tv, unknown
    static func of(_ name: String, platform: String?) -> DeviceKind {
        switch (platform ?? "").lowercased() {
        case "ios": return name.lowercased().contains("ipad") ? .tablet : .phone
        case "android": return .phone
        case "mac", "win", "windows": return .laptop
        case "linux": return .desktop
        default: break
        }
        let n = name.lowercased()
        if n.contains("tv") || n.contains("apple-tv") { return .tv }
        if n.contains("ipad") || n.contains("tab") { return .tablet }
        if n.contains("phone") || n.contains("iphone") || n.contains("android") || n.contains("pixel") { return .phone }
        if n.contains("mac") || n.contains("laptop") || n.contains("book") { return .laptop }
        if n.contains("pc") || n.contains("desktop") || n.contains("imac") { return .desktop }
        return .unknown
    }
    var symbol: String {
        switch self {
        case .phone: return "iphone"
        case .tablet: return "ipad"
        case .laptop: return "laptopcomputer"
        case .desktop: return "desktopcomputer"
        case .tv: return "tv"
        case .unknown: return "questionmark.circle"
        }
    }
}

@MainActor
final class ServerLive: ObservableObject, Identifiable {
    enum Link: Equatable { case off, connecting, live, retrying(String) }

    let name: String
    private weak var store: Store?
    nonisolated var id: String { name }

    @Published private(set) var link: Link = .off
    @Published private(set) var lastSnapshot: Date?
    @Published private(set) var services: [String: ServiceState] = [:]
    @Published private(set) var ovpn: [String: OVPNConn] = [:]
    @Published private(set) var wg: [String: WGPeer] = [:]
    @Published private(set) var ike: [String: IKEConn] = [:]
    @Published private(set) var rates: [String: Rate] = [:]
    @Published private(set) var history: [TrafficPoint] = []          // all devices, last 15 minutes
    @Published private(set) var events: [LiveEvent] = []
    @Published private(set) var usage: UsageState?
    @Published private(set) var usageEvents: [UsageEvent] = []
    @Published private(set) var totals: ServerTotals?
    @Published private(set) var days: [DayTraffic] = []
    @Published private(set) var devInfo: [String: (platform: String, app: String)] = [:]
    @Published private(set) var devices: [DeviceInfo] = []
    /// What the server listens on (PORT lines, every ~30 s)
    @Published private(set) var ports: [ServerPort] = []

    private var task: Task<Void, Never>?
    private var parser = SnapshotParser()
    private var prevCounters: [String: (rx: Int64, tx: Int64, time: Int)] = [:]
    private var ovpnRates: [String: Rate] = [:]
    private var prevOVPNFileTime = 0
    private var ovpnOverride: [String: (connected: Bool, time: Date, ip: String)] = [:]
    private var first = true

    init(name: String, store: Store) { self.name = name; self.store = store }

    // MARK: derived

    func wgOnline(_ n: String) -> Bool {
        guard let hs = wg[n]?.handshake else { return false }
        return (lastSnapshot ?? Date()).timeIntervalSince(hs) < wgOnlineWindow
    }
    var onlineNames: Set<String> { Set(ovpn.keys).union(wg.keys.filter { wgOnline($0) }).union(ike.keys) }
    func isOnline(_ n: String) -> Bool { onlineNames.contains(n) }

    /// Every device: its profiles, anyone connected, anyone with usage or a limit.
    var allDevices: [DeviceInfo] {
        var byName = Dictionary(uniqueKeysWithValues: devices.map { ($0.name, $0) })
        let extra = onlineNames.union(usage?.usage.keys.map { $0 } ?? []).union(usage?.limits.keys.map { $0 } ?? [])
        for n in extra where byName[n] == nil { byName[n] = DeviceInfo(name: n) }
        return byName.values.sorted {
            let a = isOnline($0.name), b = isOnline($1.name)
            if a != b { return a }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func kind(_ n: String) -> DeviceKind { DeviceKind.of(n, platform: devInfo[n]?.platform) }

    /// "WireGuard from 203.0.113.5", "OpenVPN and IKEv2 from …", or nil when offline.
    func via(_ n: String) -> String? {
        var vpns: [String] = []
        if ovpn[n] != nil { vpns.append("OpenVPN") }
        if wgOnline(n) { vpns.append("WireGuard") }
        if ike[n] != nil { vpns.append("IKEv2") }
        guard !vpns.isEmpty else { return nil }
        let from = ovpn[n].map { addressWithPort($0.realIP, $0.port) }
            ?? ike[n].flatMap { $0.realIP == "-" ? nil : addressWithPort($0.realIP, $0.port) }
            ?? wg[n]?.endpoint.map { addressWithPort($0, wg[n]?.port) }
        return vpns.joined(separator: " and ") + (from.map { " from \($0)" } ?? "")
    }

    /// Each VPN a device is connected on now: the server's port and the device's address and port.
    func connections(_ n: String) -> [(vpn: String, server: String?, from: String, vpnIP: String?)] {
        var out: [(String, String?, String, String?)] = []
        func from(_ ip: String?, _ port: Int?) -> String {
            guard let ip, ip != "-" else { return "unknown address" }
            return addressWithPort(ip, port)
        }
        if let o = ovpn[n] { out.append(("OpenVPN", ports.text("openvpn"), from(o.realIP, o.port), o.vpnIP.isEmpty ? nil : o.vpnIP)) }
        if wgOnline(n), let w = wg[n] { out.append(("WireGuard", ports.text("wireguard"), from(w.endpoint, w.port), w.vpnIP)) }
        if let k = ike[n] { out.append(("IKEv2", ports.text("ipsec"), from(k.realIP, k.port), k.vpnIP == "-" ? nil : k.vpnIP)) }
        return out
    }

    /// When a device was last seen, for offline devices.
    func lastSeen(_ n: String) -> Date? {
        let e = events.first { $0.device == n && !$0.connected }?.time
        let hs = wg[n]?.handshake
        return [e, hs].compactMap { $0 }.max()
    }

    var limitAttention: (paused: Int, near: Int) {
        guard let u = usage else { return (0, 0) }
        let near = u.limits.filter { n, l in
            u.paused[n] == nil && (l.tightest(u.usage[n] ?? DeviceUsage())?.fraction ?? 0) >= (usageWarnFraction ?? .infinity)
        }.count
        return (u.paused.count, near)
    }

    var hasIPsec: Bool { (services["ipsec"]?.state).map { $0 != "missing" } ?? false }

    // MARK: running

    func start() {
        guard task == nil, store?.locked == false else { return }
        task = Task { await self.loop() }
    }

    func stop() {
        task?.cancel(); task = nil
        if link != .off { link = .off }
    }

    func restart() { stop(); first = true; start() }

    private func loop() async {
        if store?.demo == true { await demoLoop(); return }
        var delay: UInt64 = 2
        while !Task.isCancelled {
            guard let store else { return }
            link = .connecting
            do {
                let conn = try await store.connection(name)
                // the device list comes alongside the live stream, not before it
                Task { await self.refreshDevices() }
                parser = SnapshotParser()
                for try await line in conn.lines(store.sudo(name) + "/usr/local/sbin/vpn-status --watch 3") {
                    if let snap = parser.feed(line) {
                        apply(snap)
                        delay = 2
                    }
                }
                if Task.isCancelled { return }
                link = .retrying("The live view stopped.")
            } catch {
                if Task.isCancelled { return }
                store.disconnect(name)
                link = .retrying(error.localizedDescription)
                // stopped in Lightsail, or back with a new IP (taken from Lightsail)?
                if let i = await store.refreshInstance(name), i.isDown {
                    link = .retrying("The server is \(i.label).")
                    delay = 30
                }
            }
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            delay = min(delay * 2, 30)
        }
    }

    /// Demo: a snapshot from DemoData every 3 seconds, like vpn-status --watch 3.
    private func demoLoop() async {
        link = .connecting
        await refreshDevices()
        var n = 0
        while !Task.isCancelled {
            var p = SnapshotParser()
            for line in DemoData.snapshot(name, full: n % 10 == 0) { if let s = p.feed(line) { apply(s) } }
            n += 1
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    /// The device list (profiles on the server).
    func refreshDevices() async {
        guard let out = try? await store?.tool(name, "/usr/local/sbin/vpn-export-profiles --list", timeout: 30) else { return }
        devices = out.split(separator: "\n").compactMap { l in
            let f = l.split(separator: "\t").map(String.init)
            guard f.count >= 5, f[0] == "DEVICE" else { return nil }
            return DeviceInfo(name: f[1], openvpn: f[2] == "1", wireguard: f[3] == "1", ikev2: f[4] == "1")
        }
    }

    /// The usage report right now (after a limit or pause change).
    func refreshUsage() async {
        guard let out = try? await store?.tool(name, "/usr/local/sbin/vpn-usage report", timeout: 30),
              let u = UsageState.parse(out) else { return }
        setUsage(u)
    }

    private func setUsage(_ u: UsageState) {
        if let old = usage, old != u {
            let new = UsageEvent.changes(from: old, to: u)
            if !new.isEmpty { usageEvents = Array((new.reversed() + usageEvents).prefix(200)) }
        }
        usage = u
    }

    private func addEvent(_ e: LiveEvent) {
        events.insert(e, at: 0)
        if events.count > 300 { events.removeLast(events.count - 300) }
    }

    private func apply(_ s: ServerSnapshot) {
        let now = s.time
        link = .live
        lastSnapshot = now
        services = s.services
        if !s.ports.isEmpty, s.ports != ports { ports = s.ports }

        // OpenVPN: the status file is up to a minute old; its log events are instant
        for e in s.ovpnEvents {
            if let o = ovpnOverride[e.name], o.connected == e.connected, abs(o.time.timeIntervalSince(e.time)) < 5 { continue }
            ovpnOverride[e.name] = (e.connected, e.time, e.ip)
            addEvent(LiveEvent(time: e.time, device: e.name, vpn: "OpenVPN", connected: e.connected, ip: e.ip))
        }
        var o = s.ovpn
        let fileTime = Date(timeIntervalSince1970: TimeInterval(s.ovpnFileTime))
        for (n, v) in ovpnOverride where v.time >= fileTime {
            if v.connected { if o[n] == nil { o[n] = OVPNConn(realIP: v.ip, vpnIP: "", rx: 0, tx: 0, since: v.time) } }
            else { o[n] = nil }
        }

        // WireGuard (handshake age) and IKEv2 (tunnels): connects and disconnects by comparison
        let wasWG = Set(wg.keys.filter { wgOnline($0) }), wasIKE = Set(ike.keys)
        wg = s.wg
        let isWG = Set(wg.keys.filter { wgOnline($0) }), isIKE = Set(s.ike.keys)
        if !first {
            for n in isWG.subtracting(wasWG).sorted() { addEvent(LiveEvent(time: now, device: n, vpn: "WireGuard", connected: true, ip: s.wg[n]?.endpoint ?? "-")) }
            for n in wasWG.subtracting(isWG).sorted() { addEvent(LiveEvent(time: now, device: n, vpn: "WireGuard", connected: false, ip: wg[n]?.endpoint ?? "-")) }
            for n in isIKE.subtracting(wasIKE).sorted() { addEvent(LiveEvent(time: now, device: n, vpn: "IKEv2", connected: true, ip: s.ike[n]?.realIP ?? "-")) }
            for n in wasIKE.subtracting(isIKE).sorted() { addEvent(LiveEvent(time: now, device: n, vpn: "IKEv2", connected: false, ip: ike[n]?.realIP ?? "-")) }
        }
        ike = s.ike
        ovpn = o

        // speeds: WireGuard and IKEv2 counters are live; OpenVPN's move when its file is rewritten
        let t = Int(now.timeIntervalSince1970)
        func rate(_ key: String, rx: Int64, tx: Int64, time: Int) -> Rate? {
            defer { prevCounters[key] = (rx, tx, time) }
            guard let p = prevCounters[key], time > p.time, rx >= p.rx, tx >= p.tx else { return nil }
            let dt = Double(time - p.time)
            return Rate(down: Double(tx - p.tx) / dt, up: Double(rx - p.rx) / dt)
        }
        var r: [String: Rate] = [:]
        func add(_ n: String, _ x: Rate?) {
            guard let x else { return }
            r[n] = Rate(down: (r[n]?.down ?? 0) + x.down, up: (r[n]?.up ?? 0) + x.up)
        }
        for (n, w) in s.wg where isWG.contains(n) { add(n, rate("wg:\(n)", rx: w.rx, tx: w.tx, time: t)) }
        for (n, k) in s.ike { add(n, rate("ike:\(n)", rx: k.rx, tx: k.tx, time: t)) }
        if s.ovpnFileTime != prevOVPNFileTime {
            ovpnRates = [:]
            for (n, c) in s.ovpn { if let x = rate("ovpn:\(n)", rx: c.rx, tx: c.tx, time: s.ovpnFileTime) { ovpnRates[n] = x } }
            prevOVPNFileTime = s.ovpnFileTime
        }
        for (n, x) in ovpnRates where o[n] != nil { add(n, x) }
        rates = r

        let down = r.values.reduce(0) { $0 + $1.down }, up = r.values.reduce(0) { $0 + $1.up }
        history.append(TrafficPoint(time: now, down: down, up: up, online: onlineNames.count))
        if let i = history.firstIndex(where: { $0.time >= now.addingTimeInterval(-900) }), i > 0 { history.removeFirst(i) }

        if let u = s.usage { setUsage(u) }
        if let tt = s.totals { totals = tt }
        if !s.days.isEmpty { days = s.days.sorted { $0.day < $1.day } }
        for (n, v) in s.devInfo { devInfo[n] = v }
        first = false
        store?.objectWillChange.send()      // the home screen's totals cover every server
    }
}

// Live monitoring. One ServerWatcher per server reads `vpn-sync watch <server>` (a single SSH
// session streaming a snapshot every few seconds) and keeps per-device connection state,
// transfer rates, service state and a connect/disconnect log. Events become notifications.
import SwiftUI
import AppKit
import UserNotifications

enum LiveLink: Equatable { case off, connecting, live, retrying }

struct OVPNConn: Equatable { var realIP: String; var vpnIP: String; var rx: Int64; var tx: Int64; var since: Date }
struct WGPeer: Equatable { var endpoint: String?; var vpnIP: String; var rx: Int64; var tx: Int64; var handshake: Date? }
/// Bytes per second as seen from the device: down = server→device, up = device→server.
struct Rate: Equatable { var down: Double; var up: Double }
struct ServiceState: Equatable { var state: String; var since: Date? }   // state: active, inactive, failed, missing…
struct LiveEvent: Identifiable, Equatable {
    let id = UUID()
    let time: Date
    let device: String
    let vpn: String        // "OpenVPN" / "WireGuard"
    let connected: Bool
    let ip: String
}

/// A service action waiting for confirmation. vpn: "openvpn", "wireguard", "all" or "reboot".
struct ServiceAction: Identifiable, Equatable {
    let server: String
    let vpn: String
    let action: String     // start, stop, restart, reboot
    var id: String { "\(server)/\(vpn)/\(action)" }
    var vpnLabel: String { vpn == "openvpn" ? "OpenVPN" : vpn == "wireguard" ? "WireGuard" : "both VPNs" }
}

/// A WireGuard peer counts as connected while its last handshake is this recent
/// (clients send keepalives, so connected peers re-handshake every 2 minutes).
let wgOnlineWindow: TimeInterval = 180
let watchInterval = 3

// MARK: - Watcher

@MainActor
final class ServerWatcher {
    let server: String
    weak var model: Model?

    private(set) var link: LiveLink = .off { didSet { changed() } }
    private(set) var ovpnLive: [String: OVPNConn] = [:]
    private(set) var wgLive: [String: WGPeer] = [:]
    private(set) var rates: [String: Rate] = [:]
    private(set) var services: [String: ServiceState] = [:]
    private(set) var events: [LiveEvent] = []
    private(set) var lastSnapshot: Date?

    // Traffic statistics (see TrafficStats below; today's figures are saved per day)
    private(set) var history: [TrafficPoint] = []          // total speed, last hour
    private(set) var stats = TrafficStats()
    private(set) var serverTotals: ServerTotals?
    private var prevBytes: [String: (rx: Int64, tx: Int64)] = [:]
    private var snapshotsSinceSave = 0

    private var process: Process?
    private var lineBuffer = ""
    private var snapOVPN: [String: OVPNConn] = [:]
    private var snapWG: [String: WGPeer] = [:]
    private var snapServices: [String: ServiceState] = [:]
    private var snapTime = 0
    private var ovpnFileTime = 0
    private var prevOVPNFileTime = 0
    private var ovpnOverride: [String: (connected: Bool, time: Int, ip: String)] = [:]
    private var prevCounters: [String: (rx: Int64, tx: Int64, time: Int)] = [:]
    private var firstSnapshot = true
    private var failures = 0
    private var retryTask: Task<Void, Never>?

    var running: Bool { process != nil || retryTask != nil }

    init(server: String, model: Model) {
        self.server = server
        self.model = model
        self.stats = TrafficStats.load(server: server)
    }

    func wgOnline(_ name: String) -> Bool {
        guard let hs = wgLive[name]?.handshake else { return false }
        return (lastSnapshot ?? Date()).timeIntervalSince(hs) < wgOnlineWindow
    }
    func isOnline(_ name: String) -> Bool { ovpnLive[name] != nil || wgOnline(name) }

    /// Every server's changes refresh the UI: the menu bar shows all servers.
    private func changed() { model?.objectWillChange.send() }

    /// Devices connected right now, by name: how each is connected and how fast.
    var onlineDevices: [(name: String, via: String, rate: Rate?)] {
        let names = Set(ovpnLive.keys).union(wgLive.keys.filter { wgOnline($0) }).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        return names.map { n in
            let o = ovpnLive[n], w = wgOnline(n) ? wgLive[n] : nil
            let via: String
            switch (o, w) {
            case let (o?, nil): via = "OpenVPN from \(o.realIP)"
            case let (nil, w?): via = "WireGuard from \(w.endpoint ?? "an unknown address")"
            case let (o?, _?): via = "OpenVPN and WireGuard from \(o.realIP)"
            default: via = ""
            }
            return (n, via, rates[n])
        }
    }

    // MARK: lifecycle

    func start() {
        guard process == nil, FileManager.default.isExecutableFile(atPath: cliURL.path) else { return }
        retryTask?.cancel(); retryTask = nil
        resetState()
        link = .connecting
        let p = Process()
        p.executableURL = cliURL
        p.arguments = ["watch", server, "--interval", String(watchInterval)]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self, weak p] h in
            let d = h.availableData
            guard !d.isEmpty, let p else { return }
            let s = String(decoding: d, as: UTF8.self)
            Task { @MainActor in self?.consume(s, from: p) }
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in self?.ended(proc) }
        }
        do { try p.run(); process = p } catch { link = .off }
    }

    func stop() {
        stats.save(server: server)
        retryTask?.cancel(); retryTask = nil
        if let p = process {
            process = nil
            if p.isRunning { p.terminate() }
        }
        link = .off
    }

    private func resetState() {
        ovpnLive = [:]; wgLive = [:]; rates = [:]; services = [:]; lastSnapshot = nil
        snapOVPN = [:]; snapWG = [:]; snapServices = [:]; ovpnOverride = [:]; prevCounters = [:]
        ovpnFileTime = 0; prevOVPNFileTime = 0; lineBuffer = ""; firstSnapshot = true
    }

    private func ended(_ proc: Process) {
        guard proc === process else { return }   // stopped on purpose, or replaced
        process = nil
        guard let m = model, m.monitoring, m.servers.contains(server) else { link = .off; return }
        // Dropped (network, IP change, reboot…): try again, backing off up to a minute.
        failures += 1
        // Second failure in a row: maybe a new IP after a stop/start. Look it up and resync.
        if failures == 2 || failures % 10 == 0 {
            let s = server
            Task { @MainActor [weak m] in await m?.recover(s) }
        }
        link = .retrying
        let delay = UInt64(min(60, 5 * failures)) * 1_000_000_000
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            if let m = self.model, m.monitoring, m.servers.contains(self.server) { self.start() }
        }
    }

    // MARK: parsing

    private func consume(_ chunk: String, from p: Process) {
        guard p === process else { return }
        lineBuffer += chunk
        while let nl = lineBuffer.firstIndex(of: "\n") {
            let line = String(lineBuffer[..<nl])
            lineBuffer = String(lineBuffer[lineBuffer.index(after: nl)...])
            handle(line)
        }
    }

    private func handle(_ line: String) {
        let f = line.components(separatedBy: "\t")
        switch f.first ?? "" {
        case "WATCHING":
            link = .live
        case "SNAPSHOT":
            snapTime = Int(f[safe: 1] ?? "") ?? Int(Date().timeIntervalSince1970)
            snapOVPN = [:]; snapWG = [:]; snapServices = [:]
        case "OVPNTIME":
            ovpnFileTime = Int(f[safe: 1] ?? "") ?? 0
        case "TOTALS" where f.count >= 6:
            serverTotals = ServerTotals(iface: f[1], todayRx: Int64(f[2]) ?? 0, todayTx: Int64(f[3]) ?? 0,
                                        monthRx: Int64(f[4]) ?? 0, monthTx: Int64(f[5]) ?? 0)
        case "SERVICE" where f.count >= 4:
            let since = Int(f[3]) ?? 0
            snapServices[f[1]] = ServiceState(state: f[2], since: since > 0 ? Date(timeIntervalSince1970: TimeInterval(since)) : nil)
        case "OVPN" where f.count >= 7:
            snapOVPN[f[1]] = OVPNConn(realIP: f[2], vpnIP: f[3], rx: Int64(f[4]) ?? 0, tx: Int64(f[5]) ?? 0,
                                      since: Date(timeIntervalSince1970: TimeInterval(Int(f[6]) ?? 0)))
        case "WG" where f.count >= 7:
            let hs = Int(f[6]) ?? 0
            snapWG[f[1]] = WGPeer(endpoint: f[2] == "-" ? nil : f[2], vpnIP: f[3], rx: Int64(f[4]) ?? 0,
                                  tx: Int64(f[5]) ?? 0, handshake: hs > 0 ? Date(timeIntervalSince1970: TimeInterval(hs)) : nil)
        case "EVENT" where f.count >= 6:
            let t = Int(f[1]) ?? snapTime
            let connected = f[4] == "connected"
            let name = f[3], ip = f[5]
            if let o = ovpnOverride[name], o.connected == connected, abs(o.time - t) < 5 { break }  // duplicate log line
            ovpnOverride[name] = (connected, t, ip)
            addEvent(LiveEvent(time: Date(timeIntervalSince1970: TimeInterval(t)), device: name, vpn: "OpenVPN",
                               connected: connected, ip: ip))
        case "END":
            commitSnapshot()
        default:
            break
        }
    }

    private func commitSnapshot() {
        failures = 0
        let now = Date(timeIntervalSince1970: TimeInterval(snapTime))
        // OpenVPN: the status file is up to 60 s old; newer log events win.
        var ovpn = snapOVPN
        for (name, o) in ovpnOverride where o.time >= ovpnFileTime {
            if o.connected {
                if ovpn[name] == nil {
                    ovpn[name] = OVPNConn(realIP: o.ip, vpnIP: "", rx: 0, tx: 0, since: Date(timeIntervalSince1970: TimeInterval(o.time)))
                }
            } else {
                ovpn[name] = nil
            }
        }
        // WireGuard: connect/disconnect from handshake age
        let wasWG = Set(wgLive.keys.filter { wgOnline($0) })
        lastSnapshot = now
        wgLive = snapWG
        let isWG = Set(snapWG.keys.filter { wgOnline($0) })
        if !firstSnapshot {
            for n in isWG.subtracting(wasWG).sorted() {
                addEvent(LiveEvent(time: now, device: n, vpn: "WireGuard", connected: true, ip: snapWG[n]?.endpoint ?? "-"))
            }
            for n in wasWG.subtracting(isWG).sorted() {
                addEvent(LiveEvent(time: now, device: n, vpn: "WireGuard", connected: false, ip: snapWG[n]?.endpoint ?? "-"))
            }
        }
        ovpnLive = ovpn
        services = snapServices

        // Rates. WireGuard counters are live; OpenVPN's only move when its status file is rewritten.
        var newRates: [String: Rate] = [:]
        func rate(_ key: String, rx: Int64, tx: Int64, time: Int) -> Rate? {
            defer { prevCounters[key] = (rx, tx, time) }
            guard let p = prevCounters[key], time > p.time, rx >= p.rx, tx >= p.tx else { return nil }
            let dt = Double(time - p.time)
            return Rate(down: Double(tx - p.tx) / dt, up: Double(rx - p.rx) / dt)
        }
        for (n, w) in snapWG where isWG.contains(n) {
            if let r = rate("wg:\(n)", rx: w.rx, tx: w.tx, time: snapTime) { newRates[n] = r }
        }
        for (n, o) in snapOVPN {
            if ovpnFileTime != prevOVPNFileTime || prevCounters["ovpn:\(n)"] == nil {
                if let r = rate("ovpn:\(n)", rx: o.rx, tx: o.tx, time: ovpnFileTime) {
                    newRates[n] = Rate(down: (newRates[n]?.down ?? 0) + r.down, up: (newRates[n]?.up ?? 0) + r.up)
                }
            } else if let r = rates[n], ovpn[n] != nil {
                newRates[n] = Rate(down: (newRates[n]?.down ?? 0) + r.down, up: (newRates[n]?.up ?? 0) + r.up)
            }
        }
        prevOVPNFileTime = ovpnFileTime
        rates = newRates
        accumulate(now: now)
        firstSnapshot = false
        changed()
        if model?.server == server { writeDebugState() }
    }

    private func addEvent(_ e: LiveEvent) {
        if e.connected { stats.rollDay(); stats.connections += 1 }
        events.insert(e, at: 0)
        if events.count > 300 { events.removeLast(events.count - 300) }
        model?.liveEvent(e, server: server)
        changed()
    }

    /// Adds this snapshot's byte counts to today's totals and the speed history.
    private func accumulate(now: Date) {
        stats.rollDay()
        func add(_ key: String, device: String, proto: String, rx: Int64, tx: Int64) {
            defer { prevBytes[key] = (rx, tx) }
            guard let p = prevBytes[key] else { return }          // first sighting: don't count history
            // a counter that went down means a new session: count from zero
            let dRx = rx >= p.rx ? rx - p.rx : rx
            let dTx = tx >= p.tx ? tx - p.tx : tx
            guard dRx > 0 || dTx > 0 else { return }
            stats.add(device: device, proto: proto, down: dTx, up: dRx)   // server tx = device download
        }
        for (n, w) in snapWG { add("wg:\(n)", device: n, proto: "WireGuard", rx: w.rx, tx: w.tx) }
        for (n, o) in snapOVPN { add("ovpn:\(n)", device: n, proto: "OpenVPN", rx: o.rx, tx: o.tx) }

        let down = rates.values.reduce(0) { $0 + $1.down }
        let up = rates.values.reduce(0) { $0 + $1.up }
        history.append(TrafficPoint(time: now, down: down, up: up))
        let cutoff = now.addingTimeInterval(-3600)
        if let i = history.firstIndex(where: { $0.time >= cutoff }), i > 0 { history.removeFirst(i) }
        stats.peakDown = max(stats.peakDown, down)
        stats.peakUp = max(stats.peakUp, up)
        let online = Set(ovpnLive.keys).union(wgLive.keys.filter { wgOnline($0) }).count
        stats.maxOnline = max(stats.maxOnline, online)

        snapshotsSinceSave += 1
        if snapshotsSinceSave >= 20 { snapshotsSinceSave = 0; stats.save(server: server) }
    }

    /// Test hook: with VPNSYNC_DEBUG_DIR set, write the selected server's live state after every snapshot.
    private func writeDebugState() {
        guard let dir = ProcessInfo.processInfo.environment["VPNSYNC_DEBUG_DIR"] else { return }
        var out = "server=\(server) link=\(link) snapshot=\(snapTime) online=\(Set(ovpnLive.keys).union(wgLive.keys.filter { wgOnline($0) }).count)\n"
        for (k, s) in services.sorted(by: { $0.key < $1.key }) { out += "SERVICE \(k) \(s.state)\n" }
        let names = Set(ovpnLive.keys).union(wgLive.keys).sorted()
        for n in names {
            let r = rates[n].map { "down=\(Int($0.down)) up=\(Int($0.up))" } ?? "-"
            out += "\(n)\tonline=\(isOnline(n))\tovpn=\(ovpnLive[n]?.realIP ?? "-")\twg=\(wgOnline(n) ? (wgLive[n]?.endpoint ?? "?") : "-")\trate=\(r)\n"
        }
        for e in events.prefix(10) { out += "EVENT \(Int(e.time.timeIntervalSince1970)) \(e.device) \(e.vpn) \(e.connected ? "connected" : "disconnected") \(e.ip)\n" }
        out += "NOTIFY \(model?.notify ?? false) auth=\(Notifier.shared.authStatus)\n"
        try? out.write(toFile: dir + "/live-state.txt", atomically: true, encoding: .utf8)
    }
}

// MARK: - Notifications

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private(set) var authStatus = "unknown"

    func setup() {
        UNUserNotificationCenter.current().delegate = self
        refreshStatus()
    }

    func refreshStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let text: String
            switch s.authorizationStatus {
            case .authorized, .provisional, .ephemeral: text = "authorized"
            case .denied: text = "denied"
            case .notDetermined: text = "notDetermined"
            @unknown default: text = "unknown"
            }
            Task { @MainActor in Notifier.shared.authStatus = text }
        }
    }

    /// Asks macOS for permission the first time (the user answers in the system prompt).
    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { @MainActor in Notifier.shared.refreshStatus() }
        }
    }

    /// A general notice (IP changed, server unreachable…). A newer one with the same id replaces it.
    func postInfo(id: String, title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.threadIdentifier = id.components(separatedBy: "/").first ?? id
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    func post(_ e: LiveEvent, server: String) {
        let c = UNMutableNotificationContent()
        c.title = "\(e.device) \(e.connected ? "connected" : "disconnected")"
        c.subtitle = server
        c.body = e.vpn + (e.ip == "-" ? "" : (e.connected ? " from " : " · ") + e.ip)
        c.threadIdentifier = server
        if e.connected { c.sound = .default }
        // One notification per device: a newer one replaces the older one.
        let req = UNNotificationRequest(identifier: "\(server)/\(e.device)", content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

// MARK: - Model glue

extension Model {
    var live: ServerWatcher? { watchers[server] }
    var liveState: LiveLink { live?.link ?? .off }
    var ovpnLive: [String: OVPNConn] { live?.ovpnLive ?? [:] }
    var wgLive: [String: WGPeer] { live?.wgLive ?? [:] }
    var rates: [String: Rate] { live?.rates ?? [:] }
    var events: [LiveEvent] { live?.events ?? [] }
    var lastSnapshot: Date? { live?.lastSnapshot }
    var services: [String: ServiceState] { live?.services ?? [:] }

    func isOnline(_ name: String) -> Bool { live?.isOnline(name) ?? false }
    func wgOnline(_ name: String) -> Bool { live?.wgOnline(name) ?? false }
    var onlineCount: Int { allDeviceNames.filter { isOnline($0) }.count }
    /// Profile devices plus any device only seen live (e.g. created outside VPN Sync).
    var allDeviceNames: [String] {
        var names = devices.map(\.name)
        for n in Set(ovpnLive.keys).union(wgLive.keys) where !names.contains(n) { names.append(n) }
        return names
    }
    /// Devices online on any server, for the menu-free summary.
    var onlineEverywhere: Int {
        watchers.values.reduce(0) { sum, w in
            sum + Set(w.ovpnLive.keys).union(w.wgLive.keys.filter { w.wgOnline($0) }).count
        }
    }

    /// Keeps exactly one running watcher per configured server while monitoring is on.
    func syncWatchers() {
        for (name, w) in watchers where !servers.contains(name) {
            w.stop(); watchers[name] = nil
        }
        guard monitoring else { return }
        for s in servers {
            let w = watchers[s] ?? ServerWatcher(server: s, model: self)
            watchers[s] = w
            if !w.running { w.start() }
        }
        objectWillChange.send()
    }

    func startMonitoring() { syncWatchers() }

    func stopMonitoring() {
        for w in watchers.values { w.stop() }
        objectWillChange.send()
    }

    func restartWatcher(_ name: String) {
        guard monitoring, let w = watchers[name] else { return }
        w.stop(); w.start()
    }

    func setMonitoring(_ on: Bool) {
        monitoring = on
        if on { syncWatchers() } else { stopMonitoring(); watchers = [:]; objectWillChange.send() }
    }

    func setNotify(_ on: Bool) {
        notify = on
        if on { Notifier.shared.requestPermission() }
    }

    func liveEvent(_ e: LiveEvent, server: String) {
        if notify { Notifier.shared.post(e, server: server) }
    }

    // MARK: services

    /// Runs a confirmed service action.
    func runService(_ a: ServiceAction) async {
        let args = a.action == "reboot" ? ["reboot", a.server] : ["service", a.server, a.vpn, a.action]
        let label = a.action == "reboot" ? "Rebooting \(a.server)…"
            : "\(a.action == "stop" ? "Stopping" : a.action == "start" ? "Starting" : "Restarting") \(a.vpnLabel)…"
        let (code, out) = await cli(args, label: label)
        if code == 0 {
            notices = [a.action == "reboot" ? "\(a.server) is rebooting. Live monitoring reconnects when it's back."
                       : "\(a.vpnLabel) on \(a.server): \(a.action == "stop" ? "stopped" : a.action == "start" ? "started" : "restarted")."]
            status = .upToDate
        } else {
            status = .failed("\(a.vpnLabel) \(a.action) failed: \(lastLines(out, 2))")
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Formatting and views

/// A speed in bytes or bits per second, following the MB/s / Mbit/s choice in the Traffic tab.
func formatRate(_ bytesPerSec: Double) -> String {
    if UserDefaults.standard.string(forKey: "rateUnit") == "bits" {
        let b = bytesPerSec * 8
        switch b {
        case ..<1_000: return "\(Int(b)) bit/s"
        case ..<1_000_000: return String(format: "%.0f kbit/s", b / 1_000)
        case ..<1_000_000_000: return String(format: b < 10_000_000 ? "%.1f Mbit/s" : "%.0f Mbit/s", b / 1_000_000)
        default: return String(format: "%.2f Gbit/s", b / 1_000_000_000)
        }
    }
    if bytesPerSec < 1024 { return "\(Int(bytesPerSec)) B/s" }
    let f = ByteCountFormatter(); f.countStyle = .binary; f.allowedUnits = [.useKB, .useMB, .useGB]
    return f.string(fromByteCount: Int64(bytesPerSec)) + "/s"
}

struct LiveDot: View {
    let online: Bool
    var body: some View {
        Circle()
            .fill(online ? Color.green : Color.secondary.opacity(0.35))
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(online ? Color.green.opacity(0.35) : .clear, lineWidth: 4))
            .help(online ? "Connected" : "Not connected")
    }
}

/// One line describing a device's live connection.
struct LiveLine: View {
    @EnvironmentObject var m: Model
    let name: String
    var body: some View {
        if let text = summary {
            Text(text).font(.caption).foregroundStyle(m.isOnline(name) ? .primary : .secondary)
                .lineLimit(1).truncationMode(.tail)
        }
    }

    private var summary: String? {
        guard m.lastSnapshot != nil else { return nil }
        var parts: [String] = []
        if let o = m.ovpnLive[name] {
            parts.append("On OpenVPN from \(o.realIP) since \(o.since.formatted(date: .omitted, time: .shortened))")
        }
        if m.wgOnline(name), let w = m.wgLive[name] {
            parts.append("\(parts.isEmpty ? "On " : "and ")WireGuard from \(w.endpoint ?? "an unknown address")")
        }
        if !parts.isEmpty { return parts.joined(separator: ", ") }
        if let hs = m.wgLive[name]?.handshake {
            return "Last seen \(hs.formatted(.relative(presentation: .named)))"
        }
        if let e = m.events.first(where: { $0.device == name && !$0.connected }) {
            return "Disconnected \(e.time.formatted(.relative(presentation: .named)))"
        }
        return "Not connected"
    }
}

struct LiveToggle: View {
    @EnvironmentObject var m: Model
    @Environment(\.theme) private var t
    var body: some View {
        GlassGroup(spacing: 6) {
            HStack(spacing: 6) {
                Button { m.setMonitoring(!m.monitoring) } label: {
                    HStack(spacing: 6) {
                        Circle().fill(color).frame(width: 8, height: 8)
                            .shadow(color: m.liveState == .live ? color.opacity(0.9) : .clear, radius: 4)
                        Text(label).font(.system(.callout, design: .rounded).weight(.medium))
                    }
                }
                .glassButton()
                .help(m.monitoring ? "Live monitoring of all servers is on. Click to stop." : "Show who is connected, live")
                Button { m.setNotify(!m.notify) } label: {
                    LucideIcon(m.notify ? "bell" : "bell-off")
                }
                .glassButton()
                .disabled(!m.monitoring)
                .help(m.notify ? "Notifications are on for every server. Click to turn off."
                               : "Notifications are off. Click to get a banner when a device connects or disconnects.")
                .accessibilityLabel(m.notify ? "Turn notifications off" : "Turn notifications on")
            }
        }
    }
    private var color: Color {
        switch m.liveState {
        case .live: return t.online
        case .connecting, .retrying: return .orange
        case .off: return .secondary
        }
    }
    private var label: String {
        switch m.liveState {
        case .live: return "Live"
        case .connecting: return "Connecting"
        case .retrying: return "Reconnecting"
        case .off: return m.monitoring ? "Live" : "Live off"
        }
    }
}

/// OpenVPN / WireGuard service state with start, stop, restart, and a server reboot.
struct ServicesBar: View {
    @EnvironmentObject var m: Model
    @Environment(\.theme) private var t
    var body: some View {
        HStack(spacing: 10) {
            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    serviceMenu("openvpn", "OpenVPN")
                    serviceMenu("wireguard", "WireGuard")
                }
            }
            Spacer()
            Menu {
                Button("Restart Both VPNs…") { m.confirmService = ServiceAction(server: m.server, vpn: "all", action: "restart") }
                Button("Stop Both VPNs…") { m.confirmService = ServiceAction(server: m.server, vpn: "all", action: "stop") }
                Button("Start Both VPNs") { Task { await m.runService(ServiceAction(server: m.server, vpn: "all", action: "start")) } }
                Divider()
                Button("Reboot Server…") { m.confirmService = ServiceAction(server: m.server, vpn: "reboot", action: "reboot") }
            } label: {
                Label("Power", lucide: "power").font(.system(.callout, design: .rounded).weight(.medium))
            }
            .fullLabelMenu()
            .padding(.horizontal, 12).padding(.vertical, 7)
            .glassCapsule()
            .help("Start, stop or restart the VPNs, or reboot the server")
        }
        .disabled(m.busy || m.server.isEmpty)
    }

    @ViewBuilder private func serviceMenu(_ vpn: String, _ label: String) -> some View {
        let s = m.services[vpn]
        if s?.state != "missing" {
            Menu {
                if s?.state == "active" {
                    Button("Restart \(label)…") { m.confirmService = ServiceAction(server: m.server, vpn: vpn, action: "restart") }
                    Button("Stop \(label)…") { m.confirmService = ServiceAction(server: m.server, vpn: vpn, action: "stop") }
                } else {
                    Button("Start \(label)") { Task { await m.runService(ServiceAction(server: m.server, vpn: vpn, action: "start")) } }
                    Button("Restart \(label)…") { m.confirmService = ServiceAction(server: m.server, vpn: vpn, action: "restart") }
                }
            } label: {
                HStack(spacing: 7) {
                    Circle().fill(dotColor(s)).frame(width: 8, height: 8)
                        .shadow(color: s?.state == "active" ? t.online.opacity(0.8) : .clear, radius: 3)
                    Text(label).font(.system(.callout, design: .rounded).weight(.semibold))
                    Text(stateText(s)).font(.system(.callout, design: .rounded)).foregroundStyle(.secondary)
                }
            }
            .fullLabelMenu()
            .padding(.horizontal, 12).padding(.vertical, 7)
            .glassCapsule(tint: s?.state == "failed" ? .red : nil)
            .help(s?.since.map { "\(label) running since \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "\(label) service")
        }
    }

    private func dotColor(_ s: ServiceState?) -> Color {
        switch s?.state {
        case "active": return t.online
        case "failed": return .red
        case nil: return .secondary
        default: return .orange
        }
    }
    private func stateText(_ s: ServiceState?) -> String {
        switch s?.state {
        case "active": return "running"
        case "inactive": return "stopped"
        case "failed": return "failed"
        case nil: return m.monitoring ? "checking" : "unknown"
        case let x?: return x
        }
    }
}

struct ActivityView: View {
    @EnvironmentObject var m: Model
    @Environment(\.theme) private var t
    var tall = false
    var body: some View {
        if m.events.isEmpty {
            Text(m.monitoring ? "Connects and disconnects show up here while VPN Sync is running." : "Turn on Live to see connects and disconnects.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(m.events) { e in
                        HStack(spacing: 10) {
                            Text(e.time.formatted(date: .omitted, time: .standard))
                                .font(.system(.caption, design: .rounded)).monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .leading)
                            Circle().fill(e.connected ? t.online : Color.secondary.opacity(0.6)).frame(width: 7, height: 7)
                            Text(e.device).font(.system(.callout, design: .rounded).weight(.semibold))
                            Text(e.connected ? "connected" : "disconnected").font(.callout)
                            Text("on \(e.vpn)\(e.ip == "-" ? "" : " from \(e.ip)")").font(.callout).foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: tall ? .infinity : 104)
        }
    }
}

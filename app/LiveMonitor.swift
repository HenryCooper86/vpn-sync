// Live monitoring. One ServerWatcher per server reads `vpn-sync watch <server>` (a single SSH
// session streaming a snapshot every few seconds) and keeps per-device connection state,
// transfer rates, service state and a connect/disconnect log. Events become notifications.
import SwiftUI
import AppKit
import UserNotifications
import Charts

enum LiveLink: Equatable { case off, connecting, live, retrying }

// MARK: - Watcher

@MainActor
final class ServerWatcher {
    let server: String
    weak var model: Model?

    private(set) var link: LiveLink = .off { didSet { changed() } }
    private(set) var ovpnLive: [String: OVPNConn] = [:]
    private(set) var wgLive: [String: WGPeer] = [:]
    private(set) var ikeLive: [String: IKEConn] = [:]
    private(set) var rates: [String: Rate] = [:]
    private(set) var services: [String: ServiceState] = [:]
    /// What the server listens on (PORT lines, every ~30 s); kept across reconnects.
    private(set) var ports: [ServerPort] = []
    private(set) var events: [LiveEvent] = []
    private(set) var lastSnapshot: Date?

    // Traffic statistics (see TrafficStats below; today's figures are saved per day)
    private(set) var history: [TrafficPoint] = []          // total speed, last hour
    private(set) var stats = TrafficStats()
    private(set) var serverTotals: ServerTotals?
    private(set) var serverDaily: [String: DayTraffic] = [:]          // last 30 days, by date
    private(set) var deviceHistory: [String: [TrafficPoint]] = [:]    // per device, last 15 minutes
    /// What each OpenVPN client reported about itself (platform, app), from DEVINFO lines.
    private(set) var devInfo: [String: (platform: String, app: String)] = [:]
    private var prevBytes: [String: (rx: Int64, tx: Int64)] = [:]
    private var snapshotsSinceSave = 0

    private var process: Process?
    private var lineBuffer = ""
    private var snapOVPN: [String: OVPNConn] = [:]
    private var snapWG: [String: WGPeer] = [:]
    private var snapIKE: [String: IKEConn] = [:]
    private var snapServices: [String: ServiceState] = [:]
    private var snapPorts: [ServerPort] = []
    private var snapTime = 0
    private var snapUsage: UsageState?
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
    func isOnline(_ name: String) -> Bool { ovpnLive[name] != nil || wgOnline(name) || ikeLive[name] != nil }
    /// Everyone connected now, on any VPN.
    var onlineNames: Set<String> { Set(ovpnLive.keys).union(wgLive.keys.filter { wgOnline($0) }).union(ikeLive.keys) }

    /// Every server's changes refresh the UI: the menu bar shows all servers.
    private func changed() { model?.objectWillChange.send() }

    /// Devices connected right now, by name: how each is connected and how fast.
    var onlineDevices: [(name: String, via: String, rate: Rate?)] {
        let names = onlineNames.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return names.map { n in
            let o = ovpnLive[n], w = wgOnline(n) ? wgLive[n] : nil, k = ikeLive[n]
            var vpns: [String] = []
            if o != nil { vpns.append("OpenVPN") }
            if w != nil { vpns.append("WireGuard") }
            if k != nil { vpns.append("IKEv2") }
            // the first connection's address, with the device's own port when the server reports it
            let first: (ip: String, port: Int?)? = o.map { ($0.realIP, $0.port) }
                ?? k.flatMap { $0.realIP == "-" ? nil : ($0.realIP, $0.port) }
                ?? w.flatMap { p in p.endpoint.map { ($0, p.port) } }
            let list: String
            switch vpns.count {
            case 1: list = vpns[0]
            case 2: list = String(localized: "\(vpns[0]) and \(vpns[1])")
            case 3: list = String(localized: "\(vpns[0]), \(vpns[1]) and \(vpns[2])")
            default: list = vpns.joined(separator: listSep)
            }
            let from = first.map { f in (GeoDB.shared.country(f.ip).map { flagEmoji($0) + " " } ?? "") + addressWithPort(f.ip, f.port) }
            let via = String(localized: "\(list) from \(from ?? unknownAddressText())")
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
        ovpnLive = [:]; wgLive = [:]; ikeLive = [:]; rates = [:]; services = [:]; lastSnapshot = nil
        snapOVPN = [:]; snapWG = [:]; snapIKE = [:]; snapServices = [:]; ovpnOverride = [:]; prevCounters = [:]
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
            snapOVPN = [:]; snapWG = [:]; snapIKE = [:]; snapServices = [:]; snapPorts = []
        case "PORT" where f.count >= 4:
            if let p = Int(f[3]) { snapPorts.append(ServerPort(vpn: f[1], proto: f[2], port: p)) }
        case "USAGEAT":
            snapUsage = UsageState()
            _ = snapUsage?.apply(f)
        case "USAGE", "LIMIT", "PAUSED":
            _ = snapUsage?.apply(f)
        case "OVPNTIME":
            ovpnFileTime = Int(f[safe: 1] ?? "") ?? 0
        case "DEVINFO" where f.count >= 4:
            devInfo[f[1]] = (f[2], f[3])
        case "DAY" where f.count >= 4:
            serverDaily[f[1]] = DayTraffic(day: f[1], rx: Int64(f[2]) ?? 0, tx: Int64(f[3]) ?? 0)
        case "TOTALS" where f.count >= 6:
            serverTotals = ServerTotals(iface: f[1], todayRx: Int64(f[2]) ?? 0, todayTx: Int64(f[3]) ?? 0,
                                        monthRx: Int64(f[4]) ?? 0, monthTx: Int64(f[5]) ?? 0)
        case "SERVICE" where f.count >= 4:
            let since = Int(f[3]) ?? 0
            snapServices[f[1]] = ServiceState(state: f[2], since: since > 0 ? Date(timeIntervalSince1970: TimeInterval(since)) : nil)
        case "OVPN" where f.count >= 7:
            snapOVPN[f[1]] = OVPNConn(realIP: f[2], vpnIP: f[3], rx: Int64(f[4]) ?? 0, tx: Int64(f[5]) ?? 0,
                                      since: Date(timeIntervalSince1970: TimeInterval(Int(f[6]) ?? 0)), port: portField(f))
        case "WG" where f.count >= 7:
            let hs = Int(f[6]) ?? 0
            snapWG[f[1]] = WGPeer(endpoint: f[2] == "-" ? nil : f[2], vpnIP: f[3], rx: Int64(f[4]) ?? 0,
                                  tx: Int64(f[5]) ?? 0, handshake: hs > 0 ? Date(timeIntervalSince1970: TimeInterval(hs)) : nil,
                                  port: portField(f))
        case "IKE" where f.count >= 7:
            snapIKE[f[1]] = IKEConn(realIP: f[2], vpnIP: f[3], rx: Int64(f[4]) ?? 0, tx: Int64(f[5]) ?? 0,
                                    since: Date(timeIntervalSince1970: TimeInterval(Int(f[6]) ?? 0)), port: portField(f))
        case "EVENT" where f.count >= 6:
            let t = Int(f[1]) ?? snapTime
            let connected = f[4] == "connected"
            let name = f[3], ip = f[5]
            if let o = ovpnOverride[name], o.connected == connected, abs(o.time - t) < 5 { break }  // duplicate log line
            ovpnOverride[name] = (connected, t, ip)
            addEvent(LiveEvent(time: Date(timeIntervalSince1970: TimeInterval(t)), device: name, vpn: "OpenVPN",
                               connected: connected, ip: ip))
        case "END":
            if let u = snapUsage { snapUsage = nil; model?.setUsage(u, server: server) }
            if !snapPorts.isEmpty, snapPorts != ports { ports = snapPorts }
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
        // IKEv2: connect/disconnect from who has a tunnel in this snapshot
        if !firstSnapshot {
            let was = Set(ikeLive.keys), now2 = Set(snapIKE.keys)
            for n in now2.subtracting(was).sorted() {
                addEvent(LiveEvent(time: now, device: n, vpn: "IKEv2", connected: true, ip: snapIKE[n]?.realIP ?? "-"))
            }
            for n in was.subtracting(now2).sorted() {
                addEvent(LiveEvent(time: now, device: n, vpn: "IKEv2", connected: false, ip: ikeLive[n]?.realIP ?? "-"))
            }
        }
        ikeLive = snapIKE
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
        for (n, k) in snapIKE {
            if let r = rate("ike:\(n)", rx: k.rx, tx: k.tx, time: snapTime) {
                newRates[n] = Rate(down: (newRates[n]?.down ?? 0) + r.down, up: (newRates[n]?.up ?? 0) + r.up)
            }
        }
        prevOVPNFileTime = ovpnFileTime
        rates = newRates
        accumulate(now: now)
        if firstSnapshot { injectSampleEventsIfRequested() }
        firstSnapshot = false
        changed()
        if model?.server == server { writeDebugState() }
    }

    /// Test hook (VPNSYNC_SAMPLE_EVENTS=1): fill the Activity list with sample events for a
    /// screenshot. They are not notified, counted or saved.
    func injectSampleEventsIfRequested() {
        guard ProcessInfo.processInfo.environment["VPNSYNC_SAMPLE_EVENTS"] != nil, events.isEmpty else { return }
        let now = Date()
        let online = Array(ovpnLive.keys) + wgLive.keys.filter { wgOnline($0) }
        let names = (online + ["tv", "laptop", "phone"]).prefix(4)
        var out: [LiveEvent] = []
        for (i, minutesAgo) in [2, 5, 9, 14, 18, 23, 31, 37, 44, 52].enumerated() {
            let n = names[names.startIndex + i % names.count]
            out.append(LiveEvent(time: now.addingTimeInterval(Double(-minutesAgo * 60)), device: n,
                                 vpn: i % 2 == 0 ? "OpenVPN" : "WireGuard", connected: i % 3 != 1, ip: "203.0.113.\(10 + i)"))
        }
        events = out
        changed()
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
        for (n, k) in snapIKE { add("ike:\(n)", device: n, proto: "IKEv2", rx: k.rx, tx: k.tx) }

        let down = rates.values.reduce(0) { $0 + $1.down }
        let up = rates.values.reduce(0) { $0 + $1.up }
        let onlineNames = self.onlineNames
        let online = onlineNames.count
        history.append(TrafficPoint(time: now, down: down, up: up, online: online))
        let cutoff = now.addingTimeInterval(-3600)
        if let i = history.firstIndex(where: { $0.time >= cutoff }), i > 0 { history.removeFirst(i) }
        // per-device speed, last 15 minutes (online devices; 0 when connected but idle)
        let devCutoff = now.addingTimeInterval(-900)
        for n in onlineNames.union(deviceHistory.keys) {
            var h = deviceHistory[n] ?? []
            let r = rates[n]
            h.append(TrafficPoint(time: now, down: r?.down ?? 0, up: r?.up ?? 0))
            if let i = h.firstIndex(where: { $0.time >= devCutoff }), i > 0 { h.removeFirst(i) }
            deviceHistory[n] = h.allSatisfy({ $0.down == 0 && $0.up == 0 }) && !onlineNames.contains(n) ? nil : h
        }
        stats.peakDown = max(stats.peakDown, down)
        stats.peakUp = max(stats.peakUp, up)
        stats.maxOnline = max(stats.maxOnline, online)

        snapshotsSinceSave += 1
        if snapshotsSinceSave >= 20 { snapshotsSinceSave = 0; stats.save(server: server) }
    }

    /// Test hook: with VPNSYNC_DEBUG_DIR set, write the selected server's live state after every snapshot.
    private func writeDebugState() {
        guard let dir = ProcessInfo.processInfo.environment["VPNSYNC_DEBUG_DIR"] else { return }
        var out = "server=\(server) link=\(link) snapshot=\(snapTime) online=\(onlineNames.count)\n"
        for (k, s) in services.sorted(by: { $0.key < $1.key }) { out += "SERVICE \(k) \(s.state)\n" }
        let names = Set(ovpnLive.keys).union(wgLive.keys).union(ikeLive.keys).sorted()
        for n in names {
            let r = rates[n].map { "down=\(Int($0.down)) up=\(Int($0.up))" } ?? "-"
            out += "\(n)\tonline=\(isOnline(n))\tovpn=\(ovpnLive[n]?.realIP ?? "-")\twg=\(wgOnline(n) ? (wgLive[n]?.endpoint ?? "?") : "-")\tike=\(ikeLive[n].map { "\($0.realIP) \($0.vpnIP)" } ?? "-")\trate=\(r)\n"
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
        c.title = e.connected ? String(localized: "\(e.device) connected") : String(localized: "\(e.device) disconnected")
        c.subtitle = server
        c.body = e.ip == "-" ? e.vpn : (e.connected ? String(localized: "\(e.vpn) from \(e.ip)") : e.vpn + " · " + e.ip)
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
    var ikeLive: [String: IKEConn] { live?.ikeLive ?? [:] }
    var rates: [String: Rate] { live?.rates ?? [:] }
    var events: [LiveEvent] { live?.events ?? [] }
    var lastSnapshot: Date? { live?.lastSnapshot }
    var services: [String: ServiceState] { live?.services ?? [:] }
    var ports: [ServerPort] { live?.ports ?? [] }

    func isOnline(_ name: String) -> Bool { live?.isOnline(name) ?? false }
    func wgOnline(_ name: String) -> Bool { live?.wgOnline(name) ?? false }
    var onlineCount: Int { allDeviceNames.filter { isOnline($0) }.count }
    /// Profile devices plus any device only seen live (e.g. created outside VPN Sync).
    var allDeviceNames: [String] {
        var names = devices.map(\.name)
        for n in Set(ovpnLive.keys).union(wgLive.keys).union(ikeLive.keys) where !names.contains(n) { names.append(n) }
        return names
    }
    /// Devices online on any server, for the menu-free summary.
    var onlineEverywhere: Int {
        watchers.values.reduce(0) { sum, w in sum + w.onlineNames.count }
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
        if a.vpn == "instance" { await powerServer(a.server, start: a.action == "start"); return }
        let args = a.action == "reboot" ? ["reboot", a.server] : ["service", a.server, a.vpn, a.action]
        let label = a.action == "reboot" ? String(localized: "Rebooting \(a.server)…")
            : a.action == "stop" ? String(localized: "Stopping \(a.vpnLabel)…")
            : a.action == "start" ? String(localized: "Starting \(a.vpnLabel)…")
            : String(localized: "Restarting \(a.vpnLabel)…")
        let (code, out) = await cli(args, label: label)
        if code == 0 {
            notices = [a.action == "reboot" ? String(localized: "\(a.server) is rebooting. Live monitoring reconnects when it's back.")
                       : a.action == "stop" ? String(localized: "\(a.vpnLabel) on \(a.server): stopped.")
                       : a.action == "start" ? String(localized: "\(a.vpnLabel) on \(a.server): started.")
                       : String(localized: "\(a.vpnLabel) on \(a.server): restarted.")]
            status = .upToDate
        } else {
            let err = lastLines(out, 2)
            status = .failed(a.action == "stop" ? String(localized: "\(a.vpnLabel) stop failed: \(err)")
                             : a.action == "start" ? String(localized: "\(a.vpnLabel) start failed: \(err)")
                             : a.action == "restart" ? String(localized: "\(a.vpnLabel) restart failed: \(err)")
                             : a.action == "reboot" ? String(localized: "\(a.vpnLabel) reboot failed: \(err)")
                             : "\(a.vpnLabel) \(a.action) failed: \(err)")
        }
    }
}


// MARK: - Formatting and views

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
                .help(portsHelp)
        }
    }

    private var location: String? {
        if let o = m.ovpnLive[name] { return countryOf(o.realIP) }
        if let k = m.ikeLive[name], k.realIP != "-" { return countryOf(k.realIP) }
        if m.wgOnline(name), let ep = m.wgLive[name]?.endpoint { return countryOf(ep) }
        return nil
    }

    /// Each connection: the server port it uses and the device's own address and port.
    private var portsHelp: String {
        var lines: [String] = []
        let ports = m.ports
        func line(_ vpn: String, _ label: String, _ ip: String?, _ port: Int?) {
            let from = ip.flatMap { $0 == "-" ? nil : addressWithPort($0, port) } ?? unknownAddressText()
            let base = ports.text(vpn).map { String(localized: "\(label) to \($0) from \(from)") } ?? String(localized: "\(label) from \(from)")
            lines.append(base + (ip.flatMap(countryOf).map { " (\($0))" } ?? ""))
        }
        if let o = m.ovpnLive[name] { line("openvpn", "OpenVPN", o.realIP, o.port) }
        if m.wgOnline(name), let w = m.wgLive[name] { line("wireguard", "WireGuard", w.endpoint, w.port) }
        if let k = m.ikeLive[name] { line("ipsec", "IKEv2", k.realIP, k.port) }
        if lines.isEmpty, let loc = location { return String(localized: "Connecting from \(loc)") }
        return lines.joined(separator: "\n")
    }

    private func from(_ ip: String?, _ port: Int?) -> String {
        guard let ip, ip != "-" else { return unknownAddressText() }
        let flag = GeoDB.shared.country(ip).map { flagEmoji($0) + " " } ?? ""
        return flag + addressWithPort(ip, port)
    }

    private var summary: String? {
        guard m.lastSnapshot != nil else { return nil }
        var parts: [String] = []
        func conn(_ vpn: String, _ addr: String, since: Date?) -> String {
            if parts.isEmpty {
                if let since { return String(localized: "On \(vpn) from \(addr) since \(since.formatted(date: .omitted, time: .shortened))") }
                return String(localized: "On \(vpn) from \(addr)")
            }
            return String(localized: "and \(vpn) from \(addr)")
        }
        if let o = m.ovpnLive[name] {
            parts.append(conn("OpenVPN", from(o.realIP, o.port), since: o.since))
        }
        if m.wgOnline(name), let w = m.wgLive[name] {
            parts.append(conn("WireGuard", from(w.endpoint, w.port), since: nil))
        }
        if let k = m.ikeLive[name] {
            parts.append(conn("IKEv2", from(k.realIP, k.port), since: k.since))
        }
        if !parts.isEmpty { return parts.joined(separator: clauseSep) }
        if let hs = m.wgLive[name]?.handshake {
            return String(localized: "Last seen \(hs.formatted(.relative(presentation: .named)))")
        }
        if let e = m.events.first(where: { $0.device == name && !$0.connected }) {
            return String(localized: "Disconnected \(e.time.formatted(.relative(presentation: .named)))")
        }
        return String(localized: "Not connected")
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
        case .live: return String(localized: "Live")
        case .connecting: return String(localized: "Connecting")
        case .retrying: return String(localized: "Reconnecting")
        case .off: return m.monitoring ? String(localized: "Live") : String(localized: "Live off")
        }
    }
}

/// OpenVPN / WireGuard (and IPsec where installed) service state with start, stop, restart, and a server reboot.
struct ServicesBar: View {
    @EnvironmentObject var m: Model
    @Environment(\.theme) private var t
    var body: some View {
        // ports next to each service when the window is wide enough; otherwise in the Ports menu only
        ViewThatFits(in: .horizontal) {
            bar(ports: true, compactPorts: false)
            bar(ports: false, compactPorts: false)
            bar(ports: false, compactPorts: true)
        }
        .disabled(m.busy || m.server.isEmpty)
        .task(id: m.server) { await m.refreshInstanceState(m.server) }
    }

    private func bar(ports: Bool, compactPorts: Bool) -> some View {
        HStack(spacing: 10) {
            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    serviceMenu("openvpn", "OpenVPN", port: ports)
                    serviceMenu("wireguard", "WireGuard", port: ports)
                    // only where IPsec/IKEv2 is installed (older server tools don't report it)
                    if let s = m.services["ipsec"], s.state != "missing" { serviceMenu("ipsec", "IPsec", port: ports) }
                }
            }
            Spacer(minLength: 8)
            PortsMenu(compact: compactPorts)
            Menu {
                let all = hasIPsec ? "All VPNs" : "Both VPNs"
                Button("Restart \(all)…") { m.confirmService = ServiceAction(server: m.server, vpn: "all", action: "restart") }
                Button("Stop \(all)…") { m.confirmService = ServiceAction(server: m.server, vpn: "all", action: "stop") }
                Button("Start \(all)") { Task { await m.runService(ServiceAction(server: m.server, vpn: "all", action: "start")) } }
                Divider()
                Button("Reboot Server…") { m.confirmService = ServiceAction(server: m.server, vpn: "reboot", action: "reboot") }
                if m.isLightsail(m.server) {
                    let st = m.instanceStates[m.server]
                    Divider()
                    Button("Stop Server…") { m.confirmService = ServiceAction(server: m.server, vpn: "instance", action: "stop") }
                        .disabled(st?.isDown == true || st?.state == "pending")
                    Button("Start Server") { Task { await m.powerServer(m.server, start: true) } }
                        .disabled(st?.isRunning == true || st?.state == "pending" || st?.state == "stopping")
                }
            } label: {
                Label("Power", lucide: "power").font(.system(.callout, design: .rounded).weight(.medium))
            }
            .fullLabelMenu()
            .padding(.horizontal, 12).padding(.vertical, 7)
            .glassCapsule()
            .help(m.isLightsail(m.server) ? "Start, stop or restart the VPNs; reboot, stop or start the server"
                                          : "Start, stop or restart the VPNs, or reboot the server")
        }
    }

    private var hasIPsec: Bool { (m.services["ipsec"]?.state).map { $0 != "missing" } ?? false }

    @ViewBuilder private func serviceMenu(_ vpn: String, _ label: String, port: Bool) -> some View {
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
                    if port, let p = m.ports.text(vpn) {
                        Text(p).font(.system(.caption, design: .rounded).weight(.medium)).monospacedDigit()
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.secondary.opacity(0.12), in: Capsule())
                    }
                }
            }
            .fullLabelMenu()
            .padding(.horizontal, 12).padding(.vertical, 7)
            .glassCapsule(tint: s?.state == "failed" ? .red : nil)
            .help(serviceHelp(vpn, label, s))
        }
    }

    private func serviceHelp(_ vpn: String, _ label: String, _ s: ServiceState?) -> String {
        var t = s?.since.map { String(localized: "\(label) running since \($0.formatted(date: .abbreviated, time: .shortened))") } ?? String(localized: "\(label) service")
        if let p = m.ports.text(vpn) { t += "\n" + String(localized: "Listens on \(p); the server's firewall must allow it.") }
        return t
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
        case "active": return String(localized: "running", comment: "service state, lowercase")
        case "inactive": return String(localized: "stopped", comment: "service state, lowercase")
        case "failed": return String(localized: "failed", comment: "service state, lowercase")
        case nil: return m.monitoring ? String(localized: "checking", comment: "service state, lowercase") : String(localized: "unknown", comment: "service state, lowercase")
        case let x?: return x
        }
    }
}

struct ActivityView: View {
    @EnvironmentObject var m: Model
    @Environment(\.theme) private var t
    var tall = false

    /// A connect/disconnect or a limit event, merged into one list by time.
    private enum Item: Identifiable {
        case live(LiveEvent), usage(UsageEvent)
        var id: UUID { switch self { case .live(let e): return e.id; case .usage(let e): return e.id } }
        var time: Date { switch self { case .live(let e): return e.time; case .usage(let e): return e.time } }
    }
    private var items: [Item] {
        (m.events.map(Item.live) + m.limitEvents.map(Item.usage)).sorted { $0.time > $1.time }
    }

    var body: some View {
        if m.activityCount == 0 {
            Text(m.monitoring ? "Connects, disconnects and usage-limit alerts show up here while VPN Sync is running." : "Turn on Live to see connects, disconnects and usage-limit alerts.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if tall { lastHour }
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        let latest = latestEventIDs, latestLimit = latestLimitIDs
                        ForEach(items) { item in
                            switch item {
                            case .live(let e): liveRow(e, latest: latest.contains(e.id))
                            case .usage(let e): limitRow(e, latest: latestLimit.contains(e.id))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: tall ? .infinity : 104)
            }
        }
    }

    private func timeText(_ d: Date) -> some View {
        Text(d.formatted(date: .omitted, time: .standard))
            .font(.system(.caption, design: .rounded)).monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(width: 70, alignment: .leading)
    }

    private func liveRow(_ e: LiveEvent, latest: Bool) -> some View {
        HStack(spacing: 10) {
            timeText(e.time)
            Circle().fill(e.connected ? t.online : Color.secondary.opacity(0.6)).frame(width: 7, height: 7)
                .frame(width: 12)
            Text(e.device).font(.system(.callout, design: .rounded).weight(.semibold))
            Text(e.connected ? "connected" : "disconnected").font(.callout)
            Text(e.ip == "-" ? String(localized: "on \(e.vpn)") : String(localized: "on \(e.vpn) from \(withFlag(e.ip))")).font(.callout).foregroundStyle(.secondary)
                .help(countryOf(e.ip) ?? "")
            Spacer()
            // the device's speed now, on its newest event only, while it's online
            if latest && m.isOnline(e.device) {
                Sparkline(history: m.deviceHistory(e.device), name: e.device, width: 70, height: 20)
            }
        }
        .frame(minHeight: 20)
    }

    private func limitIcon(_ k: UsageEvent.Kind) -> (String, Color) {
        switch k {
        case .nearing: return ("gauge", .orange)
        case .reached: return ("gauge", .red)
        case .paused: return ("pause", .orange)
        case .resumed: return ("circle-check", t.online)
        case .limitSet, .limitRemoved: return ("gauge", .secondary)
        }
    }

    private func limitRow(_ e: UsageEvent, latest: Bool) -> some View {
        let (icon, color) = limitIcon(e.kind)
        return HStack(spacing: 10) {
            timeText(e.time)
            LucideIcon(icon, size: 11).foregroundStyle(color).frame(width: 12)
            Text(e.device).font(.system(.callout, design: .rounded).weight(.semibold))
            Text(e.text).font(.callout).lineLimit(1).layoutPriority(1)
            if !e.detail.isEmpty {
                Text(e.detail).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    .lineLimit(1).truncationMode(.tail)
                    .help(e.detail)
            }
            Spacer(minLength: 6)
            // pause/resume and the limit, on the device's newest limit event
            if latest {
                if let p = m.pauseInfo(e.device) { PausedBadge(info: p) }
                Menu {
                    LimitMenuItems(m: m, server: m.server, name: e.device)
                } label: { LucideIcon("ellipsis", size: 13).foregroundStyle(.secondary).frame(width: 18, height: 18) }
                    .fullLabelMenu()
                    .disabled(m.busy)
                    .accessibilityLabel("Limit options for \(e.device)")
                    .frame(width: 18, height: 18)
            }
        }
        .frame(minHeight: 20)
        .contextMenu { LimitMenuItems(m: m, server: m.server, name: e.device) }
    }

    /// Newest limit event per device.
    private var latestLimitIDs: Set<UUID> {
        var seen = Set<String>(), ids = Set<UUID>()
        for e in m.limitEvents where !seen.contains(e.device) { seen.insert(e.device); ids.insert(e.id) }
        return ids
    }

    /// Newest event per device (events are newest first).
    private var latestEventIDs: Set<UUID> {
        var seen = Set<String>(), ids = Set<UUID>()
        for e in m.events where !seen.contains(e.device) { seen.insert(e.device); ids.insert(e.id) }
        return ids
    }

    // MARK: last hour strip

    private struct Bucket: Identifiable { let minute: Date; let connects: Int; let disconnects: Int; var id: Date { minute } }

    private var buckets: [Bucket] {
        let cal = Calendar.current
        let now = Date()
        var c: [Date: (Int, Int)] = [:]
        for e in m.events where now.timeIntervalSince(e.time) <= 3600 {
            let minute = cal.dateInterval(of: .minute, for: e.time)?.start ?? e.time
            var v = c[minute] ?? (0, 0)
            if e.connected { v.0 += 1 } else { v.1 += 1 }
            c[minute] = v
        }
        return c.map { Bucket(minute: $0.key, connects: $0.value.0, disconnects: $0.value.1) }.sorted { $0.minute < $1.minute }
    }

    private var lastHour: some View {
        let b = buckets
        let connects = b.reduce(0) { $0 + $1.connects }, disconnects = b.reduce(0) { $0 + $1.disconnects }
        let top = max(b.map { max($0.connects, $0.disconnects) }.max() ?? 1, 1)
        let end = Date(), start = end.addingTimeInterval(-3600)
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Last hour").font(.system(.callout, design: .rounded).weight(.semibold))
                HStack(spacing: 10) {
                    legend(TrafficColor.online(t.dark), connects == 1 ? String(localized: "\(connects) connect") : String(localized: "\(connects) connects"))
                    legend(Color.secondary.opacity(0.6), disconnects == 1 ? String(localized: "\(disconnects) disconnect") : String(localized: "\(disconnects) disconnects"))
                }
            }
            .fixedSize()
            Chart {
                ForEach(b) { x in
                    if x.connects > 0 {
                        BarMark(x: .value("Minute", x.minute, unit: .minute), y: .value("Connects", x.connects))
                            .foregroundStyle(TrafficColor.online(t.dark))
                    }
                    if x.disconnects > 0 {
                        BarMark(x: .value("Minute", x.minute, unit: .minute), y: .value("Disconnects", -x.disconnects))
                            .foregroundStyle(Color.secondary.opacity(0.6))
                    }
                }
                RuleMark(y: .value("Zero", 0)).foregroundStyle(Color.primary.opacity(0.15)).lineStyle(StrokeStyle(lineWidth: 0.5))
            }
            .chartXScale(domain: start...end)
            .chartYScale(domain: -Double(top)...Double(top))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 30)
            .help("Connects (above) and disconnects (below) per minute, last hour")
            .accessibilityLabel("Last hour: \(connects) connects, \(disconnects) disconnects")
        }
        .padding(.bottom, 4)
    }

    private func legend(_ c: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(c).frame(width: 10, height: 4)
            Text(text).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

/// Every port the server listens on, and the address and port each connected device comes from.
struct PortsMenu: View {
    @EnvironmentObject var m: Model
    var compact = false
    var body: some View {
        Menu {
            Section("\(m.server) listens on") {
                if m.ports.isEmpty {
                    Text(m.monitoring ? "Waiting for the server…" : "Turn on Live to see them")
                } else {
                    ForEach(["openvpn", "wireguard", "ipsec", "ssh"], id: \.self) { vpn in
                        if let p = m.ports.text(vpn) { Text("\(portLabel(vpn))   \(p)") }
                    }
                }
            }
            Section("Connected devices") {
                let rows = deviceRows
                if rows.isEmpty { Text(m.lastSnapshot == nil ? "Not known yet" : "None connected") }
                ForEach(rows, id: \.self) { Text($0) }
            }
            if !m.ports.isEmpty {
                Divider()
                Button("Change Ports…") { m.portsTarget = PortsTarget(server: m.server) }
                    .disabled(!m.ports.contains { $0.vpn == "openvpn" || $0.vpn == "wireguard" })
                Button("Copy Ports") {
                    let text = ["openvpn", "wireguard", "ipsec", "ssh"].compactMap { v in m.ports.text(v).map { "\(portLabel(v)): \($0)" } }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text.joined(separator: "\n"), forType: .string)
                }
            }
        } label: {
            if compact { LucideIcon("shield").accessibilityLabel("Ports") }
            else { Label("Ports", lucide: "shield").font(.system(.callout, design: .rounded).weight(.medium)) }
        }
        .fullLabelMenu()
        .padding(.horizontal, 12).padding(.vertical, 7)
        .glassCapsule()
        .help("The ports \(m.server) listens on, and where each connected device comes from")
    }

    /// "laptop: WireGuard (UDP 443) from 203.0.113.5:51234"
    private var deviceRows: [String] {
        let ports = m.ports
        return m.allDeviceNames.filter { m.isOnline($0) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.flatMap { n -> [String] in
            var out: [String] = []
            func add(_ vpn: String, _ ip: String?, _ port: Int?) {
                let from = ip.flatMap { $0 == "-" ? nil : addressWithPort($0, port) } ?? unknownAddressText()
                out.append(ports.text(vpn).map { String(localized: "\(n): \(portLabel(vpn)) (\($0)) from \(from)") }
                           ?? String(localized: "\(n): \(portLabel(vpn)) from \(from)"))
            }
            if let o = m.ovpnLive[n] { add("openvpn", o.realIP, o.port) }
            if m.wgOnline(n), let w = m.wgLive[n] { add("wireguard", w.endpoint, w.port) }
            if let k = m.ikeLive[n] { add("ipsec", k.realIP, k.port) }
            return out
        }
    }
}

/// Placeholder for a device whose address the server did not report.
func unknownAddressText() -> String { String(localized: "an unknown address") }

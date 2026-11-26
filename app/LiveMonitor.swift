// Live monitoring: reads `vpn-sync watch <server>` (one SSH session streaming a snapshot every
// few seconds) and keeps per-device connection state, transfer rates and a connect/disconnect log.
import SwiftUI
import AppKit

enum LiveLink: Equatable { case off, connecting, live, retrying }

struct OVPNConn: Equatable { var realIP: String; var vpnIP: String; var rx: Int64; var tx: Int64; var since: Date }
struct WGPeer: Equatable { var endpoint: String?; var vpnIP: String; var rx: Int64; var tx: Int64; var handshake: Date? }
/// Bytes per second as seen from the device: down = server→device, up = device→server.
struct Rate: Equatable { var down: Double; var up: Double }
struct LiveEvent: Identifiable, Equatable {
    let id = UUID()
    let time: Date
    let device: String
    let vpn: String        // "OpenVPN" / "WireGuard"
    let connected: Bool
    let ip: String
}

/// A WireGuard peer counts as connected while its last handshake is this recent
/// (WireGuard re-handshakes every 2 minutes while traffic flows).
let wgOnlineWindow: TimeInterval = 180
let watchInterval = 3

extension Model {
    func isOnline(_ name: String) -> Bool { ovpnLive[name] != nil || wgOnline(name) }
    func wgOnline(_ name: String) -> Bool {
        guard let hs = wgLive[name]?.handshake else { return false }
        return (lastSnapshot ?? Date()).timeIntervalSince(hs) < wgOnlineWindow
    }
    var onlineCount: Int { allDeviceNames.filter { isOnline($0) }.count }
    /// Profile devices plus any device only seen live (e.g. created outside VPN Sync).
    var allDeviceNames: [String] {
        var names = devices.map(\.name)
        for n in Set(ovpnLive.keys).union(wgLive.keys) where !names.contains(n) { names.append(n) }
        return names
    }

    // MARK: lifecycle

    func startMonitoring() {
        guard !server.isEmpty, cliInstalled else { return }
        stopMonitoring()
        resetLive()
        watchServer = server
        liveState = .connecting
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
            Task { @MainActor in self?.watcherEnded(proc) }
        }
        do { try p.run(); watchProcess = p } catch { liveState = .off }
    }

    func stopMonitoring() {
        if let p = watchProcess {
            watchProcess = nil
            if p.isRunning { p.terminate() }
        }
        liveState = .off
    }

    func setMonitoring(_ on: Bool) {
        monitoring = on
        if on { startMonitoring() } else { stopMonitoring(); resetLive() }
    }

    private func resetLive() {
        ovpnLive = [:]; wgLive = [:]; rates = [:]; lastSnapshot = nil
        snapOVPN = [:]; snapWG = [:]; ovpnOverride = [:]; prevCounters = [:]
        ovpnFileTime = 0; prevOVPNFileTime = 0; lineBuffer = ""; firstSnapshot = true
    }

    private func watcherEnded(_ proc: Process) {
        guard proc === watchProcess else { return }   // stopped on purpose, or replaced
        watchProcess = nil
        guard monitoring, watchServer == server, status != .needsInstall else { liveState = .off; return }
        liveState = .retrying                          // dropped (network, IP change…): try again
        let s = server
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, self.monitoring, self.server == s, self.watchProcess == nil else { return }
            self.startMonitoring()
        }
    }

    // MARK: parsing

    private func consume(_ chunk: String, from p: Process) {
        guard p === watchProcess else { return }
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
            liveState = .live
        case "SNAPSHOT":
            snapTime = Int(f[safe: 1] ?? "") ?? Int(Date().timeIntervalSince1970)
            snapOVPN = [:]; snapWG = [:]
        case "OVPNTIME":
            ovpnFileTime = Int(f[safe: 1] ?? "") ?? 0
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
            for n in isWG.subtracting(wasWG) {
                addEvent(LiveEvent(time: now, device: n, vpn: "WireGuard", connected: true, ip: snapWG[n]?.endpoint ?? "-"))
            }
            for n in wasWG.subtracting(isWG) {
                addEvent(LiveEvent(time: now, device: n, vpn: "WireGuard", connected: false, ip: snapWG[n]?.endpoint ?? "-"))
            }
        }
        ovpnLive = ovpn

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
        firstSnapshot = false
        writeDebugState()
    }

    /// Test hook: with VPNSYNC_DEBUG_DIR set, write the live state after every snapshot.
    private func writeDebugState() {
        guard let dir = ProcessInfo.processInfo.environment["VPNSYNC_DEBUG_DIR"] else { return }
        var out = "server=\(server) link=\(liveState) snapshot=\(snapTime) online=\(onlineCount)\n"
        for n in allDeviceNames.sorted() {
            let r = rates[n].map { "down=\(Int($0.down)) up=\(Int($0.up))" } ?? "-"
            out += "\(n)\tonline=\(isOnline(n))\tovpn=\(ovpnLive[n]?.realIP ?? "-")\twg=\(wgOnline(n) ? (wgLive[n]?.endpoint ?? "?") : "-")\trate=\(r)\n"
        }
        for e in events.prefix(10) { out += "EVENT \(Int(e.time.timeIntervalSince1970)) \(e.device) \(e.vpn) \(e.connected ? "connected" : "disconnected") \(e.ip)\n" }
        try? out.write(toFile: dir + "/live-state.txt", atomically: true, encoding: .utf8)
    }

    private func addEvent(_ e: LiveEvent) {
        events.insert(e, at: 0)
        if events.count > 300 { events.removeLast(events.count - 300) }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Formatting and views

func formatRate(_ bytesPerSec: Double) -> String {
    if bytesPerSec < 1024 { return "\(Int(bytesPerSec)) B/s" }
    let f = ByteCountFormatter(); f.countStyle = .binary; f.allowedUnits = [.useKB, .useMB, .useGB]
    return f.string(fromByteCount: Int64(bytesPerSec)) + "/s"
}
func formatBytes(_ b: Int64) -> String {
    let f = ByteCountFormatter(); f.countStyle = .binary
    return f.string(fromByteCount: b)
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
        if m.liveState == .off && m.lastSnapshot == nil {
            EmptyView()
        } else if let text = summary {
            Text(text).font(.caption).foregroundStyle(m.isOnline(name) ? .primary : .secondary)
                .lineLimit(1).truncationMode(.tail)
        }
    }

    private var summary: String? {
        var parts: [String] = []
        if let o = m.ovpnLive[name] {
            parts.append("OpenVPN from \(o.realIP), since \(o.since.formatted(date: .omitted, time: .shortened))")
        }
        if m.wgOnline(name), let w = m.wgLive[name] {
            parts.append("WireGuard from \(w.endpoint ?? "?")")
        }
        if !parts.isEmpty {
            var s = "Online · " + parts.joined(separator: " · ")
            if let r = m.rates[name] { s += " · ↓ \(formatRate(r.down)) ↑ \(formatRate(r.up))" }
            return s
        }
        guard m.lastSnapshot != nil else { return nil }
        if let hs = m.wgLive[name]?.handshake {
            return "Offline · WireGuard last seen \(hs.formatted(.relative(presentation: .named)))"
        }
        if let e = m.events.first(where: { $0.device == name && !$0.connected }) {
            return "Offline · disconnected \(e.time.formatted(.relative(presentation: .named)))"
        }
        return "Offline"
    }
}

struct LiveToggle: View {
    @EnvironmentObject var m: Model
    var body: some View {
        Button { m.setMonitoring(!m.monitoring) } label: {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(label)
            }
        }
        .help(m.monitoring ? "Live monitoring is on: click to stop" : "Show who is connected, live")
    }
    private var color: Color {
        switch m.liveState {
        case .live: return .green
        case .connecting, .retrying: return .orange
        case .off: return .secondary
        }
    }
    private var label: String {
        switch m.liveState {
        case .live: return "Live · \(m.onlineCount) online"
        case .connecting: return "Connecting…"
        case .retrying: return "Reconnecting…"
        case .off: return m.monitoring ? "Live" : "Live: off"
        }
    }
}

struct ActivityView: View {
    @EnvironmentObject var m: Model
    var body: some View {
        if m.events.isEmpty {
            Text(m.monitoring ? "Connects and disconnects will appear here while VPN Sync is open." : "Turn on Live to see connects and disconnects.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(m.events) { e in
                        HStack(spacing: 8) {
                            Text(e.time.formatted(date: .omitted, time: .standard))
                                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            Image(systemName: e.connected ? "arrow.up.right.circle.fill" : "arrow.down.left.circle")
                                .foregroundStyle(e.connected ? Color.green : Color.secondary)
                            Text("\(e.device) \(e.connected ? "connected" : "disconnected")").font(.caption.weight(.medium))
                            Text("\(e.vpn)\(e.ip == "-" ? "" : " · \(e.ip)")").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 110)
        }
    }
}

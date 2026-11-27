// Shared by the Mac and iPhone apps (Foundation only).
// Reads the vpn-status stream (see server/bin/vpn-status) into one value per snapshot.
import Foundation

/// Everything one snapshot (up to its END line) said. Lines that only come every few snapshots
/// (TOTALS, DAY, DEVINFO, the usage report) are nil / empty when absent.
struct ServerSnapshot {
    var time = Date()
    var services: [String: ServiceState] = [:]
    var ovpn: [String: OVPNConn] = [:]
    var ovpnFileTime = 0                   // when OpenVPN last wrote its status file
    var wg: [String: WGPeer] = [:]
    var ike: [String: IKEConn] = [:]
    /// What the server listens on (empty in snapshots without PORT lines)
    var ports: [ServerPort] = []
    /// OpenVPN connects/disconnects from its log (instant, unlike the status file)
    var ovpnEvents: [(time: Date, name: String, connected: Bool, ip: String)] = []
    var totals: ServerTotals?
    var days: [DayTraffic] = []
    var devInfo: [String: (platform: String, app: String)] = [:]
    var usage: UsageState?
}

/// Feed it lines; it returns a snapshot at each END.
struct SnapshotParser {
    private var cur = ServerSnapshot()
    private var usage: UsageState?

    mutating func feed(_ line: String) -> ServerSnapshot? {
        let f = line.components(separatedBy: "\t")
        func i(_ k: Int) -> Int { Int(f[safe: k] ?? "") ?? 0 }
        func i64(_ k: Int) -> Int64 { Int64(f[safe: k] ?? "") ?? 0 }
        func date(_ k: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(i(k))) }
        switch f.first ?? "" {
        case "SNAPSHOT":
            cur = ServerSnapshot(); usage = nil
            cur.time = date(1)
        case "SERVICE" where f.count >= 4:
            cur.services[f[1]] = ServiceState(state: f[2], since: i(3) > 0 ? date(3) : nil)
        case "OVPNTIME":
            cur.ovpnFileTime = i(1)
        case "OVPN" where f.count >= 7:
            cur.ovpn[f[1]] = OVPNConn(realIP: f[2], vpnIP: f[3], rx: i64(4), tx: i64(5), since: date(6), port: portField(f))
        case "WG" where f.count >= 7:
            cur.wg[f[1]] = WGPeer(endpoint: f[2] == "-" ? nil : f[2], vpnIP: f[3], rx: i64(4), tx: i64(5),
                                  handshake: i(6) > 0 ? date(6) : nil, port: portField(f))
        case "IKE" where f.count >= 7:
            cur.ike[f[1]] = IKEConn(realIP: f[2], vpnIP: f[3], rx: i64(4), tx: i64(5), since: date(6), port: portField(f))
        case "PORT" where f.count >= 4:
            if let p = Int(f[3]) { cur.ports.append(ServerPort(vpn: f[1], proto: f[2], port: p)) }
        case "EVENT" where f.count >= 6:
            cur.ovpnEvents.append((date(1), f[3], f[4] == "connected", f[5]))
        case "TOTALS" where f.count >= 6:
            cur.totals = ServerTotals(iface: f[1], todayRx: i64(2), todayTx: i64(3), monthRx: i64(4), monthTx: i64(5))
        case "DAY" where f.count >= 4:
            cur.days.append(DayTraffic(day: f[1], rx: i64(2), tx: i64(3)))
        case "DEVINFO" where f.count >= 4:
            cur.devInfo[f[1]] = (f[2], f[3])
        case "USAGEAT":
            usage = UsageState(); _ = usage?.apply(f)
        case "USAGE", "LIMIT", "PAUSED":
            _ = usage?.apply(f)
        case "END":
            cur.usage = usage
            let done = cur
            cur = ServerSnapshot(); usage = nil
            return done
        default:
            break
        }
        return nil
    }
}

// Shared by the Mac and iPhone apps (Foundation only).
// What a server's live stream (vpn-status) describes: connections per VPN, speeds, services,
// connect/disconnect events and traffic over time.
import Foundation

/// `port` is the device's own (source) port, as the server sees it; nil from older server tools.
struct OVPNConn: Equatable { var realIP: String; var vpnIP: String; var rx: Int64; var tx: Int64; var since: Date; var port: Int? = nil }
struct WGPeer: Equatable { var endpoint: String?; var vpnIP: String; var rx: Int64; var tx: Int64; var handshake: Date?; var port: Int? = nil }
/// An IKEv2 device connected now (all its tunnels added up).
struct IKEConn: Equatable { var realIP: String; var vpnIP: String; var rx: Int64; var tx: Int64; var since: Date; var port: Int? = nil }

/// A port the server listens on (PORT lines). vpn: openvpn, wireguard, ipsec or ssh.
struct ServerPort: Hashable {
    var vpn: String
    var proto: String      // tcp or udp
    var port: Int
}

extension Array where Element == ServerPort {
    /// "TCP 443", "UDP 500, 4500", or nil when the server didn't say.
    func text(_ vpn: String) -> String? {
        let mine = filter { $0.vpn == vpn }
        guard !mine.isEmpty else { return nil }
        return Dictionary(grouping: mine, by: \.proto).sorted { $0.key < $1.key }
            .map { "\($0.key.uppercased()) " + $0.value.map { String($0.port) }.joined(separator: ", ") }
            .joined(separator: ", ")
    }
}

/// The name people know a PORT line's vpn by.
func portLabel(_ vpn: String) -> String {
    switch vpn {
    case "openvpn": return "OpenVPN"
    case "wireguard": return "WireGuard"
    case "ipsec": return "IKEv2"
    case "ssh": return "SSH"
    default: return vpn
    }
}

/// "203.0.113.5:51234", "[2001:db8::5]:51234", or the address alone without a port.
func addressWithPort(_ ip: String, _ port: Int?) -> String {
    guard let port else { return ip }
    return ip.contains(":") ? "[\(ip)]:\(port)" : "\(ip):\(port)"
}

/// The 8th field of an OVPN / WG / IKE line: the device's port, or nil ("-" or older tools).
func portField(_ f: [String]) -> Int? { f.count > 7 ? Int(f[7]) : nil }
/// Bytes per second as seen from the device: down = server→device, up = device→server.
struct Rate: Equatable { var down: Double; var up: Double }
struct ServiceState: Equatable { var state: String; var since: Date? }   // state: active, inactive, failed, missing…
struct LiveEvent: Identifiable, Equatable {
    let id = UUID()
    let time: Date
    let device: String
    let vpn: String        // "OpenVPN" / "WireGuard" / "IKEv2"
    let connected: Bool
    let ip: String
}

/// A service action waiting for confirmation. vpn: "openvpn", "wireguard", "ipsec", "all" or "reboot".
struct ServiceAction: Identifiable, Equatable {
    let server: String
    let vpn: String
    let action: String     // start, stop, restart, reboot
    var id: String { "\(server)/\(vpn)/\(action)" }
    var vpnLabel: String {
        switch vpn {
        case "openvpn": return "OpenVPN"
        case "wireguard": return "WireGuard"
        case "ipsec": return "IPsec"
        default: return "all VPNs"
        }
    }
}

/// A WireGuard peer counts as connected while its last handshake is this recent
/// (clients send keepalives, so connected peers re-handshake every 2 minutes).
let wgOnlineWindow: TimeInterval = 180
let watchInterval = 3

struct TrafficPoint: Identifiable, Equatable {
    let time: Date
    let down: Double      // bytes/s, all devices
    let up: Double
    var online: Int = 0   // devices connected at that moment
    var id: Date { time }
}

/// Server traffic for one day (vnstat; in = received, out = sent).
struct DayTraffic: Identifiable, Equatable {
    let day: String       // yyyy-mm-dd
    let rx: Int64
    let tx: Int64
    var id: String { day }
    var total: Int64 { rx + tx }
    var date: Date {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: day) ?? Date()
    }
}

struct ServerTotals: Equatable {
    let iface: String
    let todayRx: Int64, todayTx: Int64, monthRx: Int64, monthTx: Int64
}

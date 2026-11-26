// Offline IP-to-country lookup for device locations. The table (ip-location-db,
// geo-whois-asn-country, public domain) is downloaded by `vpn-sync geo update` to
// ~/.config/vpn-sync/geo/ipv4-num.csv; no IP address is ever sent anywhere.
import Foundation

final class GeoDB: @unchecked Sendable {
    static let shared = GeoDB()
    private let lock = NSLock()
    private var starts: [UInt32] = []
    private var ends: [UInt32] = []
    private var codes: [String] = []
    private(set) var loaded = false
    var file: URL { configDir.appendingPathComponent("geo/ipv4-num.csv") }
    var available: Bool { FileManager.default.fileExists(atPath: file.path) }

    /// Loads (or reloads) the table off the main thread; calls back on the main actor.
    func load(then done: @escaping @MainActor () -> Void = {}) {
        DispatchQueue.global(qos: .utility).async {
            var s: [UInt32] = [], e: [UInt32] = [], c: [String] = []
            if let text = try? String(contentsOf: self.file, encoding: .utf8) {
                s.reserveCapacity(300_000); e.reserveCapacity(300_000); c.reserveCapacity(300_000)
                for line in text.split(separator: "\n") {
                    let f = line.split(separator: ",")
                    guard f.count == 3, let a = UInt32(f[0]), let b = UInt32(f[1]) else { continue }
                    s.append(a); e.append(b); c.append(String(f[2]))
                }
            }
            self.lock.lock(); self.starts = s; self.ends = e; self.codes = c; self.loaded = !s.isEmpty; self.lock.unlock()
            Task { @MainActor in done() }
        }
    }

    /// Two-letter country code for a public IPv4 address (nil for private, VPN or unknown).
    func country(_ ip: String) -> String? {
        guard let n = GeoDB.number(ip), !GeoDB.isPrivate(n) else { return nil }
        lock.lock(); defer { lock.unlock() }
        var lo = 0, hi = starts.count - 1
        while lo <= hi {                       // last range whose start <= n
            let mid = (lo + hi) / 2
            if starts[mid] <= n { lo = mid + 1 } else { hi = mid - 1 }
        }
        guard hi >= 0, n <= ends[hi] else { return nil }
        let cc = codes[hi]
        return cc == "ZZ" ? nil : cc
    }

    static func number(_ ip: String) -> UInt32? {
        let p = ip.split(separator: ".")
        guard p.count == 4 else { return nil }
        var n: UInt32 = 0
        for x in p { guard let v = UInt32(x), v < 256 else { return nil }; n = n << 8 | v }
        return n
    }

    private static func isPrivate(_ n: UInt32) -> Bool {
        let a = n >> 24, b = (n >> 16) & 0xFF
        return a == 10 || a == 127 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
            || (a == 100 && (64...127).contains(b)) || (a == 169 && b == 254) || a == 0 || a >= 224
    }
}

/// "CN" → 🇨🇳
func flagEmoji(_ cc: String) -> String {
    cc.uppercased().unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }.map(String.init).joined()
}

/// "CN" → "China" (in the user's language)
func countryName(_ cc: String) -> String {
    Locale.current.localizedString(forRegionCode: cc) ?? cc
}

/// "🇨🇳 175.16.199.0" when the country is known, otherwise just the address.
func withFlag(_ ip: String) -> String {
    guard let cc = GeoDB.shared.country(ip) else { return ip }
    return "\(flagEmoji(cc)) \(ip)"
}

/// "China" for a tooltip, or nil.
func countryOf(_ ip: String) -> String? { GeoDB.shared.country(ip).map(countryName) }

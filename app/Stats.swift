// Traffic statistics: today's totals per device and protocol, peaks and counts (saved per day in
// ~/.config/vpn-sync/stats/<server>.json), plus the server's own totals from vnstat.
import Foundation

struct ByteCount: Codable, Equatable {
    var down: Int64 = 0
    var up: Int64 = 0
    var total: Int64 { down + up }
}

struct TrafficStats: Codable, Equatable {
    var day = TrafficStats.today()
    var devices: [String: ByteCount] = [:]
    var protocols: [String: ByteCount] = [:]
    var peakDown: Double = 0
    var peakUp: Double = 0
    var connections = 0
    var maxOnline = 0

    var total: ByteCount {
        devices.values.reduce(into: ByteCount()) { $0.down += $1.down; $0.up += $1.up }
    }

    static func today() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    /// Starts a fresh day at midnight.
    mutating func rollDay() {
        let d = TrafficStats.today()
        if d != day { self = TrafficStats(); day = d }
    }

    mutating func add(device: String, proto: String, down: Int64, up: Int64) {
        devices[device, default: ByteCount()].down += down
        devices[device, default: ByteCount()].up += up
        protocols[proto, default: ByteCount()].down += down
        protocols[proto, default: ByteCount()].up += up
    }

    private static func url(_ server: String) -> URL {
        configDir.appendingPathComponent("stats").appendingPathComponent("\(server).json")
    }

    static func load(server: String) -> TrafficStats {
        guard let data = try? Data(contentsOf: url(server)),
              let s = try? JSONDecoder().decode(TrafficStats.self, from: data), s.day == today() else { return TrafficStats() }
        return s
    }

    func save(server: String) {
        let u = TrafficStats.url(server)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: u, options: .atomic) }
    }
}

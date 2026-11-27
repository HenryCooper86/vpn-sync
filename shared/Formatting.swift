// Shared by the Mac and iPhone apps (Foundation only).
import Foundation

func formatBytes(_ b: Int64) -> String {
    if b == 0 { return "0 B" }                 // ByteCountFormatter says "Zero KB"
    let f = ByteCountFormatter(); f.countStyle = .binary
    return f.string(fromByteCount: b)
}

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

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Between items of a list of names shown to the user ("tv, laptop"): ", " in English, "、" in Chinese.
var listSep: String { String(localized: "list-separator", defaultValue: ", ", comment: "between items of a list of names, e.g. 'tv, laptop'") }
/// Between clauses of a summary ("1 paused, 2 near a limit"): ", " in English, "，" in Chinese.
var clauseSep: String { String(localized: "clause-separator", defaultValue: ", ", comment: "between clauses, e.g. '1 paused, 2 near a limit'") }

/// The platform an OpenVPN client reports (IV_PLAT), as people know it.
func clientPlatformName(_ p: String) -> String {
    switch p.lowercased() {
    case "win": return "Windows"
    case "mac": return "macOS"
    case "ios": return "iOS"
    case "android": return "Android"
    case "linux": return "Linux"
    default: return p
    }
}

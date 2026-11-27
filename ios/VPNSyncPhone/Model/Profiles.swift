// A device's profile files, fetched from its server (vpn-export-profiles --device NAME, a plain
// tar) into a private temporary folder, ready to share or show as a QR code.
import Foundation

struct ProfileFile: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var name: String { url.lastPathComponent }
    /// "WireGuard", "OpenVPN", "IKEv2 (iPhone, iPad, Mac)", …
    var label: String {
        switch url.pathExtension {
        case "conf": return "WireGuard"
        case "ovpn": return "OpenVPN"
        case "mobileconfig": return "IKEv2 for iPhone, iPad and Mac"
        case "sswan": return "IKEv2 for Android (strongSwan)"
        case "p12": return "IKEv2 for Windows"
        default: return url.pathExtension
        }
    }
    var symbol: String {
        switch url.pathExtension {
        case "conf": return "bolt.horizontal.circle"
        case "ovpn": return "lock.shield"
        case "mobileconfig": return "apple.logo"
        case "sswan": return "candybarphone"
        case "p12": return "pc"
        default: return "doc"
        }
    }
}

enum Profiles {
    /// Downloads one device's files. Old downloads are removed first.
    @MainActor
    static func fetch(_ device: String, server: String, store: Store) async throws -> [ProfileFile] {
        let r = try await store.run(server, "/usr/local/sbin/vpn-export-profiles --device \(device)", timeout: 60)
        guard r.code == 0 else { throw StoreError.failed(r.stderr.isEmpty ? "Couldn't get \(device)'s profiles." : r.stderr) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("profiles", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [ProfileFile] = []
        for (path, data) in try untar(r.stdout) where !path.hasSuffix("/") && !path.hasSuffix(".png") {
            let url = dir.appendingPathComponent((path as NSString).lastPathComponent)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            out.append(ProfileFile(url: url))
        }
        let order = ["conf", "ovpn", "mobileconfig", "sswan", "p12"]
        return out.sorted { (order.firstIndex(of: $0.url.pathExtension) ?? 9) < (order.firstIndex(of: $1.url.pathExtension) ?? 9) }
    }

    /// Deletes downloaded profiles (they hold private keys).
    static func clear() {
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("profiles"))
    }

    /// Minimal tar reader (ustar and GNU long names): regular files only.
    static func untar(_ d: Data) throws -> [(String, Data)] {
        var out: [(String, Data)] = []
        var i = d.startIndex
        var longName: String?
        func field(_ off: Int, _ len: Int) -> String {
            let b = d[(i + off)..<(i + off + len)]
            return String(decoding: b.prefix { $0 != 0 }, as: UTF8.self)
        }
        while i + 512 <= d.endIndex {
            if d[i..<(i + 512)].allSatisfy({ $0 == 0 }) { break }
            var name = field(0, 100)
            let prefix = field(345, 155)
            if !prefix.isEmpty && field(257, 5) == "ustar" { name = prefix + "/" + name }
            let size = Int(field(124, 12).trimmingCharacters(in: .whitespaces), radix: 8) ?? 0
            let type = d[i + 156]
            let start = i + 512, end = start + size
            guard end <= d.endIndex else { throw StoreError.failed("The profiles came back incomplete.") }
            let body = d.subdata(in: start..<end)
            switch type {
            case UInt8(ascii: "L"): longName = String(decoding: body.prefix { $0 != 0 }, as: UTF8.self)
            case UInt8(ascii: "0"), 0:
                out.append((longName ?? name, body)); longName = nil
            default: longName = nil      // directories, pax headers
            }
            i = start + ((size + 511) / 512) * 512
        }
        return out
    }
}

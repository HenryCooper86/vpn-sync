// The app's state: imported servers (settings in Application Support, private keys in the
// Keychain), one SSH connection per server (reused; through the jump server when needed),
// a live view per server, the Face ID lock and a few settings.
import SwiftUI
import LocalAuthentication
import Security

struct ServerConfig: Codable, Identifiable, Hashable {
    var name: String
    var host: String
    var user: String
    var port: Int
    var jump: String?
    var privateIP: String?
    var lastIP: String?
    var hostKey: String
    var region: String? = nil      // Lightsail, for Start/Stop Server
    var instance: String? = nil
    var id: String { name }
    /// Shown under the name: the address the phone connects to.
    var address: String { lastIP ?? host }
}

enum StoreError: LocalizedError {
    case unknownServer(String), noKey(String), failed(String)
    var errorDescription: String? {
        switch self {
        case .unknownServer(let s): return "No server named \(s)."
        case .noKey(let s): return "The key for \(s) is missing; import the servers again."
        case .failed(let m): return m
        }
    }
}

@MainActor
final class Store: ObservableObject {
    @Published var servers: [ServerConfig] = []
    @Published private(set) var live: [String: ServerLive] = [:]
    @Published var locked = false
    @Published var lockEnabled = UserDefaults.standard.object(forKey: "lockEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(lockEnabled, forKey: "lockEnabled") }
    }
    /// Early warning at this percentage of a limit (0 = off); shared code reads it as usageWarnAt.
    @Published var warnAt = usageWarnAt { didSet { UserDefaults.standard.set(warnAt, forKey: "usageWarnAt") } }
    /// A .vpnsync file waiting for its passphrase.
    @Published var pendingImport: Data?
    /// A one-line message at the bottom of the screen ("tv is paused.").
    @Published var toast: String?
    /// Lightsail instance state per server (when the export included a Lightsail key).
    @Published var instances: [String: LightsailInstance] = [:]

    private var connections: [String: SSHConnection] = [:]
    private var connecting: [String: Task<SSHConnection, Error>] = [:]

    /// Made-up servers and devices instead of SSH (launch argument -demo YES; for screenshots).
    let demo = UserDefaults.standard.bool(forKey: "demo")

    init() {
        if demo {
            servers = DemoData.servers.map {
                ServerConfig(name: $0.name, host: $0.ip, user: "ubuntu", port: 22, jump: $0.jump,
                             privateIP: $0.jump == nil ? nil : "172.31.0.20", lastIP: $0.ip, hostKey: "")
            }
        } else {
            load()
        }
        locked = lockEnabled && !servers.isEmpty && !demo
        for s in servers { live[s.name] = ServerLive(name: s.name, store: self) }
    }

    // MARK: persistence

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("servers.json")
    }

    private func load() {
        guard let d = try? Data(contentsOf: fileURL), let s = try? JSONDecoder().decode([ServerConfig].self, from: d) else { return }
        servers = s
    }

    private func save() {
        guard !demo else { return }
        if let d = try? JSONEncoder().encode(servers) {
            try? d.write(to: fileURL, options: [.atomic, .completeFileProtection])
        }
    }

    func server(_ name: String) -> ServerConfig? { servers.first { $0.name == name } }

    // MARK: import

    /// Opens an exported file; returns how many servers were added or updated.
    @discardableResult
    func importBundle(_ data: Data, passphrase: String) throws -> Int {
        let payload = try ServerBundle.open(data, passphrase: passphrase)
        for e in payload.servers {
            _ = try OpenSSHKey.ed25519(fromPEM: e.key)          // refuse keys the phone can't use
            try Keychain.setKey(e.key, for: e.name)
            let cfg = ServerConfig(name: e.name, host: e.host, user: e.user, port: e.port, jump: e.jump,
                                   privateIP: e.privateIP, lastIP: e.lastIP, hostKey: e.hostKey,
                                   region: e.region, instance: e.instance)
            disconnect(e.name)
            if let i = servers.firstIndex(where: { $0.name == e.name }) { servers[i] = cfg } else { servers.append(cfg) }
        }
        if let k = payload.aws { try Keychain.setAWS(k) }
        servers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        save()
        for s in servers where live[s.name] == nil { live[s.name] = ServerLive(name: s.name, store: self) }
        for s in payload.servers { live[s.name]?.restart() }
        return payload.servers.count
    }

    func remove(_ name: String) {
        live[name]?.stop(); live[name] = nil
        disconnect(name)
        servers.removeAll { $0.name == name }
        Keychain.deleteKey(for: name)
        save()
    }

    // MARK: connections

    /// The open connection to a server: through its jump server first when it has one (like the
    /// Mac: such servers usually don't answer SSH from outside), then its last known IP, then its
    /// configured host. A host key that doesn't match the pinned one stops right there.
    func connection(_ name: String) async throws -> SSHConnection {
        if let c = connections[name], c.isActive { return c }
        if let t = connecting[name] { return try await t.value }
        let t = Task { try await self.open(name) }
        connecting[name] = t
        defer { connecting[name] = nil }
        let c = try await t.value
        connections[name] = c
        return c
    }

    func disconnect(_ name: String) {
        connections[name]?.close(); connections[name] = nil
    }

    private func open(_ name: String) async throws -> SSHConnection {
        guard let s = server(name) else { throw StoreError.unknownServer(name) }
        guard let pem = Keychain.key(for: name) else { throw StoreError.noKey(name) }
        let key = try OpenSSHKey.ed25519(fromPEM: pem)
        var lastError: Error = SSHError.closed
        var hosts: [String] = []
        for h in [s.lastIP, s.host].compactMap({ $0 }) where !hosts.contains(h) { hosts.append(h) }
        if let j = s.jump, j != name, let ip = s.privateIP, server(j) != nil {
            do {
                let via = try await connection(j)
                return try await SSHConnection.connect(SSHEndpoint(host: ip, port: s.port, user: s.user, key: key, hostKey: s.hostKey), through: via)
            } catch SSHError.hostKeyMismatch {
                throw SSHError.hostKeyMismatch
            } catch { lastError = error }
        }
        for h in hosts {
            do {
                return try await SSHConnection.connect(SSHEndpoint(host: h, port: s.port, user: s.user, key: key, hostKey: s.hostKey))
            } catch SSHError.hostKeyMismatch {
                throw SSHError.hostKeyMismatch
            } catch { lastError = error }
        }
        throw lastError
    }

    /// Runs one of the server tools (as root via sudo unless the login is root). A dropped
    /// connection is reopened once.
    func run(_ name: String, _ command: String, stdin: Data? = nil, timeout: Int = 120) async throws -> CommandResult {
        if demo { return demoRun(name, command) }
        let line = sudo(name) + command
        do {
            return try await connection(name).run(line, stdin: stdin, timeout: .seconds(Int64(timeout)))
        } catch SSHError.hostKeyMismatch {
            throw SSHError.hostKeyMismatch
        } catch {
            disconnect(name)
            return try await connection(name).run(line, stdin: stdin, timeout: .seconds(Int64(timeout)))
        }
    }

    /// The server reported its current public IP: connect there next time.
    func noteIP(_ name: String, _ ip: String) {
        guard let i = servers.firstIndex(where: { $0.name == name }), servers[i].lastIP != ip else { return }
        servers[i].lastIP = ip
        save()
    }

    /// Demo answers: device list and usage from DemoData, everything else just succeeds.
    private func demoRun(_ name: String, _ command: String) -> CommandResult {
        var lines: [String] = []
        let ip = DemoData.server(name)?.ip ?? "198.51.100.1"
        if command.contains("vpn-export-profiles --list") { lines = DemoData.deviceList(name) }
        else if command.contains("vpn-usage report") { lines = DemoData.usage(name) }
        else if command.contains("vpn-endpoint-sync") { lines = ["up to date: all configs use \(ip)", "ENDPOINT=\(ip)"] }
        else if command.contains("vpn-export-profiles --hashes") {
            // the first device's WireGuard profile looks changed on every other check
            let flip = UserDefaults.standard.bool(forKey: "demoFlip"); UserDefaults.standard.set(!flip, forKey: "demoFlip")
            lines = DemoData.deviceList(name).enumerated().flatMap { i, l -> [String] in
                let n = l.split(separator: "\t").dropFirst().first.map(String.init) ?? "device"
                return ["FILE\t\(n)\topenvpn\to-\(n)",
                        "FILE\t\(n)\twireguard\t\(i == 0 && flip ? "changed" : "same")\(n)"]
            }
        }
        return CommandResult(code: 0, stdout: Data(lines.joined(separator: "\n").utf8), stderr: "")
    }

    // MARK: Lightsail (stop and start)

    var awsKey: AWSKey? { demo ? nil : Keychain.aws() }
    func canPower(_ name: String) -> Bool { server(name)?.region != nil && awsKey != nil }

    /// Asks Lightsail for the instance's state; a new public IP (after a stop and start without a
    /// static IP) becomes the address the phone connects to.
    @discardableResult
    func refreshInstance(_ name: String) async -> LightsailInstance? {
        guard let s = server(name), let region = s.region, let key = awsKey else { return nil }
        guard let i = try? await Lightsail.instance(s.instance ?? name, region: region, key: key) else { return nil }
        instances[name] = i
        if i.isRunning, let ip = i.ip, ip != s.lastIP, let idx = servers.firstIndex(where: { $0.name == name }) {
            servers[idx].lastIP = ip
            save()
            disconnect(name)
        }
        return i
    }

    /// Stops or starts the server's Lightsail instance; starting waits until it's running, then
    /// reconnects the live view.
    func power(_ name: String, start: Bool) async throws {
        guard let s = server(name), let region = s.region, let key = awsKey else { return }
        let inst = s.instance ?? name
        if start {
            try await Lightsail.start(inst, region: region, key: key)
            instances[name] = LightsailInstance(state: "pending", ip: nil, staticIP: instances[name]?.staticIP ?? false)
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if let i = await refreshInstance(name), i.isRunning { break }
            }
            try? await Task.sleep(nanoseconds: 20_000_000_000)    // the VPNs and SSH need a moment
            live[name]?.restart()
        } else {
            try await Lightsail.stop(inst, region: region, key: key)
            instances[name] = LightsailInstance(state: "stopping", ip: nil, staticIP: instances[name]?.staticIP ?? false)
            live[name]?.stop()
            disconnect(name)
            Task {
                for _ in 0..<24 {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if let i = await self.refreshInstance(name), i.state == "stopped" { break }
                }
            }
        }
    }

    func sudo(_ name: String) -> String { server(name)?.user == "root" ? "" : "sudo -n " }

    /// Runs a tool and turns a non-zero exit into an error with its last lines.
    func tool(_ name: String, _ command: String, timeout: Int = 120) async throws -> String {
        let r = try await run(name, command, timeout: timeout)
        guard r.code == 0 else {
            let msg = (r.stderr.isEmpty ? r.text : r.stderr).split(separator: "\n").suffix(2).joined(separator: " ")
            throw StoreError.failed(msg.isEmpty ? "The server said no (exit \(r.code))." : msg)
        }
        return r.text
    }

    // MARK: lifecycle and lock

    func becameActive() {
        if locked { unlock() }
        for l in live.values { l.start() }
    }

    func wentToBackground() {
        for l in live.values { l.stop() }
        for n in Array(connections.keys) { disconnect(n) }
        if lockEnabled && !servers.isEmpty { locked = true }
    }

    func unlock() {
        if demo { locked = false; return }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { locked = false; return }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your servers") { ok, _ in
            Task { @MainActor in if ok { self.locked = false; for l in self.live.values { l.start() } } }
        }
    }

    func show(_ message: String) {
        toast = message
        Task { try? await Task.sleep(nanoseconds: 3_500_000_000); if toast == message { toast = nil } }
    }

    // MARK: everything at once

    var onlineEverywhere: Int { live.values.reduce(0) { $0 + $1.onlineNames.count } }
    var limitAttention: (paused: Int, near: Int) {
        live.values.reduce((0, 0)) { acc, l in
            let a = l.limitAttention
            return (acc.0 + a.paused, acc.1 + a.near)
        }
    }
}

/// Private keys live in the Keychain, readable only on this device while it's unlocked.
enum Keychain {
    private static let service = "local.vpnsync.phone.key"

    static func setKey(_ pem: String, for server: String) throws {
        deleteKey(for: server)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: server, kSecValueData as String: Data(pem.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let st = SecItemAdd(q as CFDictionary, nil)
        guard st == errSecSuccess else { throw StoreError.failed("Couldn't save the key for \(server) (\(st)).") }
    }

    static func key(for server: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: server, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private static let awsService = "local.vpnsync.phone.aws"

    static func setAWS(_ k: AWSKey) throws {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: awsService,
                                   kSecAttrAccount as String: "lightsail"]
        SecItemDelete(base as CFDictionary)
        var q = base
        q[kSecValueData as String] = try JSONEncoder().encode(k)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let st = SecItemAdd(q as CFDictionary, nil)
        guard st == errSecSuccess else { throw StoreError.failed("Couldn't save the Lightsail key (\(st)).") }
    }

    static func aws() -> AWSKey? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: awsService,
                                kSecAttrAccount as String: "lightsail", kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(AWSKey.self, from: d)
    }

    static func deleteKey(for server: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: server]
        SecItemDelete(q as CFDictionary)
    }
}

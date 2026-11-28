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
        case .unknownServer(let s): return String(localized: "No server named \(s).")
        case .noKey(let s): return String(localized: "The key for \(s) is missing; import the servers again.")
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
    /// Stopping closes the server's VPN ports in the Lightsail firewall (SSH stays open) and
    /// starting opens them again. Returns what happened in the firewall, as sentences.
    @discardableResult
    func power(_ name: String, start: Bool) async throws -> [String] {
        guard let s = server(name), let region = s.region, let key = awsKey else { return [] }
        let inst = s.instance ?? name
        var notes: [String] = []
        if start {
            try await Lightsail.start(inst, region: region, key: key)
            instances[name] = LightsailInstance(state: "pending", ip: nil, staticIP: instances[name]?.staticIP ?? false)
            notes = await reopenPorts(name, instance: inst, region: region, key: key)
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if let i = await refreshInstance(name), i.isRunning { break }
            }
            try? await Task.sleep(nanoseconds: 20_000_000_000)    // the VPNs and SSH need a moment
            live[name]?.restart()
        } else {
            let plan = await portsToClose(name, instance: inst, region: region, key: key, notes: &notes)
            try await Lightsail.stop(inst, region: region, key: key)
            notes += await closePorts(plan, name, instance: inst, region: region, key: key)
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
        return notes
    }

    // MARK: Lightsail firewall

    private func closedKey(_ name: String) -> String { "closedPorts.\(name)" }
    /// The rules the last stop closed (on this phone), to open again on start.
    private func closedRules(_ name: String) -> [PortRule] {
        guard let d = UserDefaults.standard.data(forKey: closedKey(name)) else { return [] }
        return (try? JSONDecoder().decode([PortRule].self, from: d)) ?? []
    }
    private func saveClosed(_ rules: [PortRule], _ name: String) {
        if rules.isEmpty { UserDefaults.standard.removeObject(forKey: closedKey(name)) }
        else if let d = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(d, forKey: closedKey(name)) }
    }

    /// The server's VPN ports (not SSH): live, else the last ones it reported to this phone.
    private func vpnPorts(_ name: String) -> [ServerPort] {
        let p = live[name]?.ports ?? []
        return (p.isEmpty ? ServerLive.cachedPorts(name) : p).filter { $0.vpn != "ssh" }
    }

    /// The firewall rules for exactly one VPN port each; rules wider than that are left alone.
    private func portsToClose(_ name: String, instance: String, region: String, key: AWSKey, notes: inout [String]) async -> [PortRule] {
        let ports = vpnPorts(name)
        guard !ports.isEmpty else { return [] }
        do {
            let rules = try await Lightsail.portRules(instance, region: region, key: key)
            var plan: [PortRule] = []
            for p in ports { if let r = rules.first(where: { $0.isExactly(p) }), !plan.contains(r) { plan.append(r) } }
            return plan
        } catch {
            notes.append(String(localized: "The Lightsail firewall is left as it is: \(error.localizedDescription)"))
            return []
        }
    }

    private func closePorts(_ plan: [PortRule], _ name: String, instance: String, region: String, key: AWSKey) async -> [String] {
        guard !plan.isEmpty else { return [] }
        // remembered first: a rule closed but not remembered would stay closed after a start
        let saved = closedRules(name)
        saveClosed(saved + plan.filter { !saved.contains($0) }, name)
        var closed: [String] = [], failed: [String] = []
        for r in plan {
            do { try await Lightsail.close(r, instance: instance, region: region, key: key); closed.append(r.label) }
            catch { failed.append(r.label) }
        }
        var notes: [String] = []
        if !closed.isEmpty { notes.append(String(localized: "Its VPN ports are closed in the Lightsail firewall until it starts again: \(closed.joined(separator: ", ")). SSH stays open.")) }
        if !failed.isEmpty { notes.append(String(localized: "Couldn't close \(failed.joined(separator: ", ")) in the Lightsail firewall. Check the key's policy (VPN Sync on the Mac: Settings → Lightsail).")) }
        return notes
    }

    /// Opens what the last stop closed; stopped elsewhere (the Mac, the Lightsail console), it
    /// opens the ports the server last reported instead.
    private func reopenPorts(_ name: String, instance: String, region: String, key: AWSKey) async -> [String] {
        let saved = closedRules(name)
        guard let rules = try? await Lightsail.portRules(instance, region: region, key: key) else {
            return saved.isEmpty ? [] : [String(localized: "Couldn't open \(saved.map(\.label).joined(separator: ", ")) in the Lightsail firewall. Open them on the instance's Networking tab, or check the key's policy (VPN Sync on the Mac: Settings → Lightsail).")]
        }
        let want = saved.isEmpty
            ? vpnPorts(name).filter { p in !rules.contains { $0.covers(p) } }.map { PortRule.opening($0, like: rules) }
            : saved.filter { r in !rules.contains { $0.fromPort == r.fromPort && $0.toPort == r.toPort && $0.protocol == r.protocol } }
        var opened: [String] = [], left: [PortRule] = []
        for r in want {
            do { try await Lightsail.open(r, instance: instance, region: region, key: key); opened.append(r.label) }
            catch { left.append(r) }
        }
        if !saved.isEmpty { saveClosed(saved.filter { left.contains($0) }, name) }
        var notes: [String] = []
        if !opened.isEmpty { notes.append(String(localized: "Its VPN ports are open again in the Lightsail firewall: \(opened.joined(separator: ", ")).")) }
        if !left.isEmpty { notes.append(String(localized: "Couldn't open \(left.map(\.label).joined(separator: ", ")) in the Lightsail firewall. Open them on the instance's Networking tab, or check the key's policy (VPN Sync on the Mac: Settings → Lightsail).")) }
        return notes
    }

    func sudo(_ name: String) -> String { server(name)?.user == "root" ? "" : "sudo -n " }

    /// Runs a tool and turns a non-zero exit into an error with its last lines.
    func tool(_ name: String, _ command: String, timeout: Int = 120) async throws -> String {
        let r = try await run(name, command, timeout: timeout)
        guard r.code == 0 else {
            let msg = (r.stderr.isEmpty ? r.text : r.stderr).split(separator: "\n").suffix(2).joined(separator: " ")
            throw StoreError.failed(msg.isEmpty ? String(localized: "The server said no (exit \(r.code)).") : msg)
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
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: String(localized: "Unlock your servers")) { ok, _ in
            Task { @MainActor in if ok { self.locked = false; for l in self.live.values { l.start() } } }
        }
    }

    func show(_ message: String) {
        toast = message
        let seconds = max(3.5, Double(message.count) / 18)     // long enough to read
        Task { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)); if toast == message { toast = nil } }
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
        guard st == errSecSuccess else { throw StoreError.failed(String(localized: "Couldn't save the key for \(server) (\(st)).")) }
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
        guard st == errSecSuccess else { throw StoreError.failed(String(localized: "Couldn't save the Lightsail key (\(st)).")) }
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

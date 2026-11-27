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

    private var connections: [String: SSHConnection] = [:]
    private var connecting: [String: Task<SSHConnection, Error>] = [:]

    init() {
        load()
        locked = lockEnabled && !servers.isEmpty
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
                                   privateIP: e.privateIP, lastIP: e.lastIP, hostKey: e.hostKey)
            disconnect(e.name)
            if let i = servers.firstIndex(where: { $0.name == e.name }) { servers[i] = cfg } else { servers.append(cfg) }
        }
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

    /// The open connection to a server: last known IP, then its configured host, then through
    /// its jump server. A host key that doesn't match the pinned one stops right there.
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
        for h in hosts {
            do {
                return try await SSHConnection.connect(SSHEndpoint(host: h, port: s.port, user: s.user, key: key, hostKey: s.hostKey))
            } catch SSHError.hostKeyMismatch {
                throw SSHError.hostKeyMismatch
            } catch { lastError = error }
        }
        if let j = s.jump, j != name, let ip = s.privateIP, server(j) != nil {
            let via = try await connection(j)
            return try await SSHConnection.connect(SSHEndpoint(host: ip, port: s.port, user: s.user, key: key, hostKey: s.hostKey), through: via)
        }
        throw lastError
    }

    /// Runs one of the server tools (as root via sudo unless the login is root). A dropped
    /// connection is reopened once.
    func run(_ name: String, _ command: String, stdin: Data? = nil, timeout: Int = 120) async throws -> CommandResult {
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

    static func deleteKey(for server: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: server]
        SecItemDelete(q as CFDictionary)
    }
}

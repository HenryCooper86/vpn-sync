// Shared by the Mac and iPhone apps (Foundation, CryptoKit).
// AWS Signature Version 4 and the Lightsail calls VPN Sync uses: GetInstance (state and IP),
// StopInstance, StartInstance, and GetInstancePortStates / OpenInstancePublicPorts /
// CloseInstancePublicPorts (the firewall: a stopped server's VPN ports are closed).
import Foundation
import CryptoKit

struct AWSKey: Codable, Hashable {
    var keyID: String
    var secret: String
}

enum SigV4 {
    static func hex(_ d: some Sequence<UInt8>) -> String { d.map { String(format: "%02x", $0) }.joined() }
    static func sha256(_ d: Data) -> String { hex(SHA256.hash(data: d)) }
    static func hmac(_ key: Data, _ msg: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(msg.utf8), using: SymmetricKey(data: key)))
    }

    /// The Authorization header for a request. `headers` are the headers to sign (names are
    /// lower-cased here; include host and x-amz-date). `date` is yyyyMMdd'T'HHmmss'Z'.
    static func authorization(method: String, path: String, query: String, headers: [String: String],
                              body: Data, region: String, service: String, date: String, key: AWSKey) -> String {
        let h = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) })
        let names = h.keys.sorted()
        let signed = names.joined(separator: ";")
        let canonical = [method, path, query, names.map { "\($0):\(h[$0]!)\n" }.joined(), signed, sha256(body)].joined(separator: "\n")
        let day = String(date.prefix(8))
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let toSign = ["AWS4-HMAC-SHA256", date, scope, sha256(Data(canonical.utf8))].joined(separator: "\n")
        var k = hmac(Data("AWS4\(key.secret)".utf8), day)
        k = hmac(k, region); k = hmac(k, service); k = hmac(k, "aws4_request")
        let signature = hex(hmac(k, toSign))
        return "AWS4-HMAC-SHA256 Credential=\(key.keyID)/\(scope), SignedHeaders=\(signed), Signature=\(signature)"
    }

    static func amzDate(_ d: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: d)
    }
}

enum LightsailError: LocalizedError {
    case notAllowed(String), api(String)
    var errorDescription: String? {
        switch self {
        case .notAllowed(let perm):
            return String(localized: "This AWS key isn't allowed to call lightsail:\(perm). Add it to the key's policy (VPN Sync on the Mac: Settings → Lightsail).")
        case .api(let m): return "Lightsail: \(m)"
        }
    }
}

struct LightsailInstance: Equatable {
    var state: String          // running, stopped, stopping, pending
    var ip: String?
    var staticIP: Bool
    var isRunning: Bool { state == "running" }
    var isDown: Bool { state == "stopped" || state == "stopping" }
    var label: String {
        switch state {
        case "stopping": return String(localized: "stopping…")
        case "pending": return String(localized: "starting…")
        default: return state
        }
    }
}

enum Lightsail {
    private static func call(_ action: String, instance: String, region: String, key: AWSKey,
                             extra: [String: Any] = [:]) async throws -> [String: Any] {
        let host = "lightsail.\(region).amazonaws.com"
        let body = try JSONSerialization.data(withJSONObject: extra.merging(["instanceName": instance]) { a, _ in a })
        let date = SigV4.amzDate()
        let headers = ["content-type": "application/x-amz-json-1.1", "host": host, "x-amz-date": date,
                       "x-amz-target": "Lightsail_20161128.\(action)"]
        var req = URLRequest(url: URL(string: "https://\(host)/")!)
        req.httpMethod = "POST"; req.httpBody = body; req.timeoutInterval = 20
        for (k, v) in headers where k != "host" { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue(SigV4.authorization(method: "POST", path: "/", query: "", headers: headers, body: body,
                                         region: region, service: "lightsail", date: date, key: key),
                     forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 300 {
            let msg = (json["message"] ?? json["Message"]) as? String ?? "HTTP \(code)"
            if msg.contains("not authorized") || (json["__type"] as? String ?? "").contains("AccessDenied") {
                throw LightsailError.notAllowed(action)
            }
            throw LightsailError.api(msg)
        }
        return json
    }

    static func instance(_ name: String, region: String, key: AWSKey) async throws -> LightsailInstance {
        let j = try await call("GetInstance", instance: name, region: region, key: key)
        let i = j["instance"] as? [String: Any] ?? [:]
        let state = (i["state"] as? [String: Any])?["name"] as? String ?? "unknown"
        return LightsailInstance(state: state, ip: i["publicIpAddress"] as? String, staticIP: i["isStaticIp"] as? Bool ?? false)
    }

    static func stop(_ name: String, region: String, key: AWSKey) async throws {
        _ = try await call("StopInstance", instance: name, region: region, key: key)
    }

    static func start(_ name: String, region: String, key: AWSKey) async throws {
        _ = try await call("StartInstance", instance: name, region: region, key: key)
    }

    // MARK: firewall

    /// The open rules of the instance's public firewall.
    static func portRules(_ name: String, region: String, key: AWSKey) async throws -> [PortRule] {
        let j = try await call("GetInstancePortStates", instance: name, region: region, key: key)
        return (j["portStates"] as? [[String: Any]] ?? []).compactMap { r in
            guard (r["state"] as? String ?? "open") == "open", let f = r["fromPort"] as? Int, let t = r["toPort"] as? Int,
                  let p = r["protocol"] as? String else { return nil }
            return PortRule(fromPort: f, toPort: t, protocol: p, cidrs: r["cidrs"] as? [String],
                            ipv6Cidrs: r["ipv6Cidrs"] as? [String], cidrListAliases: r["cidrListAliases"] as? [String])
        }
    }

    static func open(_ rule: PortRule, instance: String, region: String, key: AWSKey) async throws {
        _ = try await call("OpenInstancePublicPorts", instance: instance, region: region, key: key, extra: ["portInfo": rule.json])
    }

    /// Removes the whole rule (every source).
    static func close(_ rule: PortRule, instance: String, region: String, key: AWSKey) async throws {
        _ = try await call("CloseInstancePublicPorts", instance: instance, region: region, key: key,
                           extra: ["portInfo": ["fromPort": rule.fromPort, "toPort": rule.toPort, "protocol": rule.protocol]])
    }
}

/// One rule of a Lightsail instance's firewall.
struct PortRule: Codable, Hashable {
    var fromPort: Int
    var toPort: Int
    var `protocol`: String           // tcp, udp, all, icmp
    var cidrs: [String]?
    var ipv6Cidrs: [String]?
    var cidrListAliases: [String]?

    var label: String { "\(`protocol`.uppercased()) \(fromPort == toPort ? String(fromPort) : "\(fromPort)-\(toPort)")" }
    var json: [String: Any] {
        var d: [String: Any] = ["fromPort": fromPort, "toPort": toPort, "protocol": `protocol`]
        if let cidrs, !cidrs.isEmpty { d["cidrs"] = cidrs }
        if let ipv6Cidrs, !ipv6Cidrs.isEmpty { d["ipv6Cidrs"] = ipv6Cidrs }
        if let cidrListAliases, !cidrListAliases.isEmpty { d["cidrListAliases"] = cidrListAliases }
        return d
    }
    func isExactly(_ p: ServerPort) -> Bool { `protocol` == p.proto && fromPort == p.port && toPort == p.port }
    func covers(_ p: ServerPort) -> Bool { (`protocol` == p.proto || `protocol` == "all") && fromPort <= p.port && p.port <= toPort }
    /// A rule for one port, open to the same kinds of sources as `others` (everyone, IPv4 and IPv6).
    static func opening(_ p: ServerPort, like others: [PortRule]) -> PortRule {
        let v6 = others.contains { !($0.ipv6Cidrs ?? []).isEmpty }
        return PortRule(fromPort: p.port, toPort: p.port, protocol: p.proto, cidrs: ["0.0.0.0/0"], ipv6Cidrs: v6 ? ["::/0"] : nil)
    }
}

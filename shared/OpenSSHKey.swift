// Shared by the Mac and iPhone apps (Foundation, CryptoKit).
// Reads an unencrypted OpenSSH Ed25519 private key ("-----BEGIN OPENSSH PRIVATE KEY-----"),
// which is what Lightsail and ssh-keygen -t ed25519 write. Other key types and keys with a
// passphrase are reported as unsupported rather than guessed at.
import Foundation
import CryptoKit

enum SSHKeyError: LocalizedError {
    case notOpenSSH, encrypted, notEd25519(String), malformed
    var errorDescription: String? {
        switch self {
        case .notOpenSSH: String(localized: "The key isn't in OpenSSH format.")
        case .encrypted: String(localized: "The key has a passphrase; use a key without one.")
        case .notEd25519(let t): String(localized: "Only Ed25519 keys are supported (this one is \(t)).")
        case .malformed: String(localized: "The key file is damaged.")
        }
    }
}

enum OpenSSHKey {
    static func ed25519(fromPEM text: String) throws -> Curve25519.Signing.PrivateKey {
        let body = text.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard text.contains("BEGIN OPENSSH PRIVATE KEY"), let data = Data(base64Encoded: body) else {
            throw SSHKeyError.notOpenSSH
        }
        var r = Reader(data)
        let magic = Array("openssh-key-v1".utf8) + [0]
        guard try r.bytes(magic.count) == Data(magic) else { throw SSHKeyError.notOpenSSH }
        let cipher = try r.string(), kdf = try r.string()
        _ = try r.data()                                   // kdf options
        guard cipher == "none", kdf == "none" else { throw SSHKeyError.encrypted }
        guard try r.uint32() == 1 else { throw SSHKeyError.malformed }
        _ = try r.data()                                   // public key blob
        var p = Reader(try r.data())                       // private section
        guard try p.uint32() == (try p.uint32()) else { throw SSHKeyError.malformed }   // check ints
        let type = try p.string()
        guard type == "ssh-ed25519" else { throw SSHKeyError.notEd25519(type) }
        _ = try p.data()                                   // public key (32)
        let secret = try p.data()                          // seed (32) + public key (32)
        guard secret.count == 64 else { throw SSHKeyError.malformed }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: secret.prefix(32))
    }

    private struct Reader {
        let d: Data
        var i: Int
        init(_ d: Data) { self.d = d; self.i = d.startIndex }
        mutating func bytes(_ n: Int) throws -> Data {
            guard n >= 0, i + n <= d.endIndex else { throw SSHKeyError.malformed }
            defer { i += n }
            return d.subdata(in: i..<(i + n))
        }
        mutating func uint32() throws -> UInt32 { try bytes(4).reduce(0) { $0 << 8 | UInt32($1) } }
        mutating func data() throws -> Data { try bytes(Int(uint32())) }
        mutating func string() throws -> String { String(decoding: try data(), as: UTF8.self) }
    }
}

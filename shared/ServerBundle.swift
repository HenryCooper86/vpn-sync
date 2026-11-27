// Shared by the Mac and iPhone apps (Foundation, CryptoKit, CommonCrypto).
// The file the Mac exports for the iPhone ("VPN Sync servers.vpnsync"): each server's address,
// SSH login, pinned host key and private key, encrypted with a passphrase the Mac shows once.
//
//   { "format": "vpnsync-servers", "version": 1, "kdf": "pbkdf2-sha256", "rounds": 600000,
//     "salt": base64(16 random bytes), "box": base64(AES-GCM sealed box, nonce+ciphertext+tag) }
//
// The sealed JSON is ServerBundle.Payload. The key is PBKDF2-SHA256(passphrase, salt, rounds).
import Foundation
import CryptoKit
import CommonCrypto

struct ExportedServer: Codable, Hashable {
    var name: String
    var host: String
    var user: String
    var port: Int
    var jump: String?          // another exported server's name
    var privateIP: String?     // this server's address as seen from the jump server
    var lastIP: String?
    var hostKey: String        // "ssh-ed25519 AAAA…"
    var key: String            // OpenSSH private key (PEM text)
}

enum ServerBundleError: LocalizedError {
    case notABundle, wrongPassphrase, newerVersion
    var errorDescription: String? {
        switch self {
        case .notABundle: return "This isn't a VPN Sync servers file."
        case .wrongPassphrase: return "That passphrase doesn't open this file."
        case .newerVersion: return "This file is from a newer VPN Sync; update the app."
        }
    }
}

enum ServerBundle {
    struct Payload: Codable { var exported: Date; var servers: [ExportedServer] }
    private struct Envelope: Codable { var format: String; var version: Int; var kdf: String; var rounds: Int; var salt: String; var box: String }

    static let rounds = 600_000

    static func seal(_ servers: [ExportedServer], passphrase: String) throws -> Data {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let plain = try enc.encode(Payload(exported: Date(), servers: servers))
        let box = try AES.GCM.seal(plain, using: key(passphrase, salt: salt, rounds: rounds))
        let env = Envelope(format: "vpnsync-servers", version: 1, kdf: "pbkdf2-sha256", rounds: rounds,
                           salt: salt.base64EncodedString(), box: box.combined!.base64EncodedString())
        let out = JSONEncoder(); out.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try out.encode(env)
    }

    static func open(_ data: Data, passphrase: String) throws -> Payload {
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data), env.format == "vpnsync-servers",
              env.kdf == "pbkdf2-sha256", let salt = Data(base64Encoded: env.salt), let box = Data(base64Encoded: env.box)
        else { throw ServerBundleError.notABundle }
        guard env.version <= 1 else { throw ServerBundleError.newerVersion }
        let plain: Data
        do {
            plain = try AES.GCM.open(try AES.GCM.SealedBox(combined: box), using: key(passphrase, salt: salt, rounds: env.rounds))
        } catch { throw ServerBundleError.wrongPassphrase }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try dec.decode(Payload.self, from: plain)
    }

    /// A passphrase people can type: 4 groups of 4 letters/digits without look-alikes (~80 bits).
    static func makePassphrase() -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var groups: [String] = []
        for _ in 0..<4 {
            var g = ""
            for _ in 0..<4 { g.append(chars[Int.random(in: 0..<chars.count, using: &secureRNG)]) }
            groups.append(g)
        }
        return groups.joined(separator: "-")
    }

    /// Passphrases are compared without case, spaces or dashes, so typing on a phone is forgiving.
    static func normalized(_ p: String) -> String {
        p.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func key(_ passphrase: String, salt: Data, rounds: Int) -> SymmetricKey {
        let pw = Array(normalized(passphrase).utf8)
        var out = [UInt8](repeating: 0, count: 32)
        salt.withUnsafeBytes { s in
            _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.map { Int8(bitPattern: $0) }, pw.count,
                                     s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds), &out, out.count)
        }
        return SymmetricKey(data: out)
    }

    private static var secureRNG = SecureRNG()
    private struct SecureRNG: RandomNumberGenerator {
        mutating func next() -> UInt64 {
            var v: UInt64 = 0
            _ = withUnsafeMutableBytes(of: &v) { SecRandomCopyBytes(kSecRandomDefault, 8, $0.baseAddress!) }
            return v
        }
    }
}

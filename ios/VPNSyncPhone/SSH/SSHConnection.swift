// A small SSH client on Apple's swift-nio-ssh: Ed25519 key login, a pinned host key, commands
// with their output (all at once or line by line), and connecting through a jump server
// (a direct-tcpip channel with a second SSH session inside it). Nothing else.
import Foundation
import CryptoKit
import NIOCore
import NIOPosix
import NIOSSH

struct SSHEndpoint {
    var host: String
    var port: Int = 22
    var user: String
    var key: Curve25519.Signing.PrivateKey
    var hostKey: String            // "ssh-ed25519 AAAA…", pinned
}

enum SSHError: LocalizedError {
    case hostKeyMismatch, badPinnedKey, authFailed, closed, timeout
    var errorDescription: String? {
        switch self {
        case .hostKeyMismatch: return "The server's host key doesn't match the one VPN Sync trusts. Not connecting."
        case .badPinnedKey: return "The trusted host key for this server is missing or damaged; export the servers from the Mac again."
        case .authFailed: return "The server didn't accept the key."
        case .closed: return "The connection closed."
        case .timeout: return "The server didn't answer in time."
        }
    }
}

struct CommandResult {
    var code: Int
    var stdout: Data
    var stderr: String
    var text: String { String(decoding: stdout, as: UTF8.self) }
}

final class SSHConnection: @unchecked Sendable {
    static let group = MultiThreadedEventLoopGroup.singleton

    private let channel: Channel           // a TCP socket, or a direct-tcpip channel through `jump`
    private let jump: SSHConnection?       // kept open while this connection lives
    private let checks: Checks

    private init(channel: Channel, jump: SSHConnection?, checks: Checks) {
        self.channel = channel; self.jump = jump; self.checks = checks
    }

    var isActive: Bool { channel.isActive && (jump?.isActive ?? true) }

    /// Closes this session only; a jump server's connection may be shared and stays open.
    func close() {
        channel.close(promise: nil)
    }

    // MARK: connecting

    /// What went wrong during the handshake, so errors say "host key" or "key not accepted"
    /// instead of "connection closed".
    final class Checks: @unchecked Sendable {
        var hostKeyMismatch = false
        var authExhausted = false
        func explain(_ error: Error) -> Error {
            if hostKeyMismatch { return SSHError.hostKeyMismatch }
            if authExhausted { return SSHError.authFailed }
            return error
        }
    }

    static func connect(_ e: SSHEndpoint, timeout: TimeAmount = .seconds(8)) async throws -> SSHConnection {
        let checks = Checks()
        let handler = try sshHandler(e, checks: checks)
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(timeout)
            .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .channelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    try ch.pipeline.syncOperations.addHandlers([handler(ch.allocator), ErrorSink()])
                }
            }
        do {
            let ch = try await bootstrap.connect(host: e.host, port: e.port).get()
            let c = SSHConnection(channel: ch, jump: nil, checks: checks)
            try await c.ready(timeout: timeout)
            return c
        } catch { throw checks.explain(error) }
    }

    /// Connects to `e` (a private address) through an open connection to a jump server.
    static func connect(_ e: SSHEndpoint, through jump: SSHConnection, timeout: TimeAmount = .seconds(8)) async throws -> SSHConnection {
        let checks = Checks()
        let handler = try sshHandler(e, checks: checks)
        let target = SSHChannelType.DirectTCPIP(targetHost: e.host, targetPort: e.port,
                                                originatorAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 22))
        do {
            let ch = try await jump.openChannel(.directTCPIP(target)) { ch in
                try ch.pipeline.syncOperations.addHandlers([DataToBuffer(), handler(ch.allocator), ErrorSink()])
            }
            let c = SSHConnection(channel: ch, jump: jump, checks: checks)
            try await c.ready(timeout: timeout)
            return c
        } catch { throw checks.explain(error) }
    }

    private static func sshHandler(_ e: SSHEndpoint, checks: Checks) throws -> (ByteBufferAllocator) -> NIOSSHHandler {
        guard let pinned = try? NIOSSHPublicKey(openSSHPublicKey: e.hostKey) else { throw SSHError.badPinnedKey }
        let key = NIOSSHPrivateKey(ed25519Key: e.key), user = e.user
        return { alloc in
            NIOSSHHandler(role: .client(.init(userAuthDelegate: KeyAuth(user: user, key: key, checks: checks),
                                              serverAuthDelegate: PinnedHostKey(expected: pinned, checks: checks))),
                          allocator: alloc, inboundChildChannelInitializer: nil)
        }
    }

    /// Waits until the session is authenticated (an exec of `true` succeeds).
    private func ready(timeout: TimeAmount) async throws {
        let r = try await run("true", timeout: timeout)
        if r.code != 0 { throw SSHError.authFailed }
    }

    // MARK: channels

    private func openChannel(_ type: SSHChannelType, _ setUp: @escaping (Channel) throws -> Void) async throws -> Channel {
        let promise = channel.eventLoop.makePromise(of: Channel.self)
        let ch = channel
        ch.eventLoop.execute {
            do {
                let ssh = try ch.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                ssh.createChannel(promise, channelType: type) { child, _ in
                    child.eventLoop.makeCompletedFuture { try setUp(child) }
                }
            } catch { promise.fail(error) }
        }
        return try await promise.futureResult.get()
    }

    /// Runs a command and returns everything it printed. `stdin` is sent and then closed.
    func run(_ command: String, stdin: Data? = nil, timeout: TimeAmount = .seconds(60)) async throws -> CommandResult {
        let collector = Collector()
        try await exec(command, stdin: stdin, timeout: timeout, onOut: { collector.out.append(contentsOf: $0) },
                       onErr: { collector.err.append(contentsOf: $0) }, onExit: { collector.code = $0 })
        return CommandResult(code: collector.code ?? -1, stdout: collector.out, stderr: String(decoding: collector.err, as: UTF8.self))
    }

    /// Runs a long command and yields its output line by line until it ends or the task is cancelled.
    func lines(_ command: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let splitter = LineSplitter()
            let task = Task {
                do {
                    try await self.exec(command, stdin: nil, timeout: nil, onOut: { bytes in
                        for line in splitter.feed(bytes) { cont.yield(line) }
                    }, onErr: { _ in }, onExit: { _ in })
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    private final class Collector: @unchecked Sendable { var out = Data(); var err = Data(); var code: Int? }

    private func exec(_ command: String, stdin: Data?, timeout: TimeAmount?,
                      onOut: @escaping (Data) -> Void, onErr: @escaping (Data) -> Void,
                      onExit: @escaping (Int) -> Void) async throws {
        let done = Once(channel.eventLoop.makePromise(of: Void.self))
        let handler = ExecHandler(onOut: onOut, onErr: onErr, onExit: onExit, done: done)
        let child: Channel
        do {
            child = try await openChannel(.session) { ch in
                try ch.pipeline.syncOperations.addHandler(handler)
            }
            try await child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).get()
            try await child.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)).get()
            if let stdin {
                var buf = child.allocator.buffer(capacity: stdin.count)
                buf.writeBytes(stdin)
                try await child.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buf))).get()
                try await child.close(mode: .output).get()
            }
        } catch {
            let el = channel.eventLoop
            el.execute { done.fail(error) }     // complete it on its loop, never leave it pending
            throw checks.explain(error)
        }
        var timer: Scheduled<Void>?
        if let timeout {
            timer = child.eventLoop.scheduleTask(in: timeout) {
                done.fail(SSHError.timeout); child.close(promise: nil)
            }
        }
        defer { timer?.cancel() }
        try await withTaskCancellationHandler {
            try await done.promise.futureResult.get()
        } onCancel: {
            child.close(promise: nil)
        }
    }
}

// MARK: - Handlers

/// A promise that may be completed from two places (the channel closing, a timeout); only the
/// first one counts. Used on the channel's event loop only.
final class Once: @unchecked Sendable {
    let promise: EventLoopPromise<Void>
    private var finished = false
    init(_ p: EventLoopPromise<Void>) { promise = p }
    func succeed() { if !finished { finished = true; promise.succeed(()) } }
    func fail(_ e: Error) { if !finished { finished = true; promise.fail(e) } }
}

private final class KeyAuth: NIOSSHClientUserAuthenticationDelegate {
    let user: String, key: NIOSSHPrivateKey, checks: SSHConnection.Checks
    var offered = false
    init(user: String, key: NIOSSHPrivateKey, checks: SSHConnection.Checks) { self.user = user; self.key = key; self.checks = checks }
    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard !offered, availableMethods.contains(.publicKey) else {
            checks.authExhausted = true
            nextChallengePromise.succeed(nil)
            return
        }
        offered = true
        nextChallengePromise.succeed(.init(username: user, serviceName: "", offer: .privateKey(.init(privateKey: key))))
    }
}

private final class PinnedHostKey: NIOSSHClientServerAuthenticationDelegate {
    let expected: NIOSSHPublicKey, checks: SSHConnection.Checks
    init(expected: NIOSSHPublicKey, checks: SSHConnection.Checks) { self.expected = expected; self.checks = checks }
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        if hostKey == expected {
            validationCompletePromise.succeed(())
        } else {
            checks.hostKeyMismatch = true
            validationCompletePromise.fail(SSHError.hostKeyMismatch)
        }
    }
}

/// One remote command: forwards stdout/stderr, records the exit status, completes `done` when
/// the channel closes.
private final class ExecHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    let onOut: (Data) -> Void, onErr: (Data) -> Void, onExit: (Int) -> Void
    let done: Once
    init(onOut: @escaping (Data) -> Void, onErr: @escaping (Data) -> Void, onExit: @escaping (Int) -> Void, done: Once) {
        self.onOut = onOut; self.onErr = onErr; self.onExit = onExit; self.done = done
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let d = unwrapInboundIn(data)
        guard case .byteBuffer(let buf) = d.data else { return }
        let bytes = Data(buf.readableBytesView)
        if d.type == .channel { onOut(bytes) } else if d.type == .stdErr { onErr(bytes) }
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let s = event as? SSHChannelRequestEvent.ExitStatus { onExit(s.exitStatus) }
        context.fireUserInboundEventTriggered(event)
    }
    func channelInactive(context: ChannelHandlerContext) {
        done.succeed()
        context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        done.fail(error)
        context.close(promise: nil)
    }
}

/// Lets an SSH session run over a direct-tcpip channel: SSH channel data in and out as bytes.
private final class DataToBuffer: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let d = unwrapInboundIn(data)
        guard d.type == .channel, case .byteBuffer(let buf) = d.data else { return }
        context.fireChannelRead(wrapInboundOut(buf))
    }
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(unwrapOutboundIn(data)))), promise: promise)
    }
}

/// Swallows errors at the end of the pipeline once they've been reported, and closes.
private final class ErrorSink: ChannelInboundHandler {
    typealias InboundIn = Any
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

/// Splits a byte stream into lines (UTF-8, "\n").
final class LineSplitter: @unchecked Sendable {
    private var pending = Data()
    func feed(_ bytes: Data) -> [String] {
        pending.append(bytes)
        var lines: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            lines.append(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...nl)
        }
        return lines
    }
}

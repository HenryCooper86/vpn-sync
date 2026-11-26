// VPN Sync — a small macOS front end for ~/.local/bin/vpn-sync.
// Build with ./build.sh (needs Xcode or the Command Line Tools).
import SwiftUI
import AppKit

// MARK: - Paths and helpers

let home = FileManager.default.homeDirectoryForCurrentUser
let configDir = home.appendingPathComponent(".config/vpn-sync")
let cliURL = home.appendingPathComponent(".local/bin/vpn-sync")
let desktopDir = home.appendingPathComponent("Desktop")

func isIPv4(_ s: String) -> Bool {
    let parts = s.split(separator: ".", omittingEmptySubsequences: false)
    return parts.count == 4 && parts.allSatisfy { p in
        !p.isEmpty && p.count <= 3 && p.allSatisfy(\.isNumber) && (Int(p) ?? 999) <= 255
    }
}

func isDirectory(_ url: URL) -> Bool {
    var dir: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
}

/// Why a device name can't be used, or nil if it's fine.
func nameProblem(_ name: String, existing: Set<String>) -> String? {
    if name.count > 15 { return "“\(name)” is longer than 15 characters." }
    if !name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) {
        return "“\(name)”: use only letters, numbers, - and _."
    }
    if existing.contains(name) { return "“\(name)” already exists." }
    return nil
}

/// Splits user input on commas, spaces and newlines.
func parseNames(_ text: String) -> [String] {
    text.components(separatedBy: CharacterSet(charactersIn: ", \n\t")).filter { !$0.isEmpty }
}

/// Reads KEY=value from a vpn-sync server config (shell syntax, simple values only).
func configValue(_ key: String, server: String) -> String? {
    let url = configDir.appendingPathComponent("\(server).conf")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    for line in text.split(separator: "\n") {
        let l = line.trimmingCharacters(in: .whitespaces)
        guard l.hasPrefix("\(key)=") else { continue }
        var v = String(l.dropFirst(key.count + 1))
        if let hash = v.range(of: " #") { v = String(v[..<hash.lowerBound]) }
        return v.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
    }
    return nil
}

/// Thread-safe output buffer for a running process.
final class OutputBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

// MARK: - Model

/// One device = an OpenVPN profile and/or a WireGuard profile with the same name.
struct Device: Identifiable, Hashable {
    let name: String
    var ovpn: URL?
    var wg: URL?
    var qr: URL?
    var id: String { name }
}

enum SyncStatus: Equatable {
    case idle, working(String), upToDate, needsSync, unreachable, needsInstall, failed(String)
}

@MainActor
final class Model: ObservableObject {
    @Published var servers: [String] = []
    @Published var server = ""
    @Published var status: SyncStatus = .idle
    @Published var serverIP: String?
    @Published var lastIP: String?
    @Published var lastSynced: Date?
    @Published var folder: URL?
    @Published var devices: [Device] = []
    @Published var log = ""
    @Published var manualIP = ""
    @Published var notices: [String] = []

    @Published var qrDevice: Device?
    @Published var showAddDevice = false
    @Published var showBatchAdd = false
    @Published var selecting = false
    @Published var selection: Set<String> = []
    @Published var confirmRemoval: [String]?
    var pendingQR: Device?

    // server management
    @Published var showServers = false
    @Published var showAddServer = false
    @Published var editServer: String?
    @Published var installServer: String?
    /// Output of the command currently (or last) running; shown live in sheets.
    @Published var opLog = ""

    // live monitoring (logic in LiveMonitor.swift)
    @Published var monitoring = UserDefaults.standard.object(forKey: "monitoring") as? Bool ?? true {
        didSet { UserDefaults.standard.set(monitoring, forKey: "monitoring") }
    }
    @Published var notify = UserDefaults.standard.object(forKey: "notify") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notify, forKey: "notify") }
    }
    /// One live watcher per server, so notifications cover every server, not just the selected one.
    var watchers: [String: ServerWatcher] = [:]
    @Published var confirmService: ServiceAction?
    /// The Desktop read is taking long: probably waiting for the user to allow access.
    @Published var desktopWaiting = false
    static weak var shared: Model?

    // live progress for add/remove
    private var progressVerb = ""
    private var progressTotal = 0
    private var progressDone = 0

    var busy: Bool { if case .working = status { return true }; return false }
    var cliInstalled: Bool { FileManager.default.isExecutableFile(atPath: cliURL.path) }
    var deviceNames: Set<String> { Set(devices.map(\.name)) }
    var consoleURL: URL? {
        guard let region = configValue("LIGHTSAIL_REGION", server: server), !region.isEmpty else { return nil }
        return URL(string: "https://\(region).console.aws.amazon.com/lightsail/webapp/home/instances")
    }

    init() {
        reloadServers(select: UserDefaults.standard.string(forKey: "selectedServer"))
        Model.shared = self
    }

    /// Re-reads the server configs; selects `select` if given, else keeps the current one.
    func reloadServers(select: String? = nil) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: configDir.path)) ?? []
        servers = files.filter { $0.hasSuffix(".conf") && !$0.hasPrefix(".") }
            .map { String($0.dropLast(5)) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let want = select ?? server
        server = servers.contains(want) ? want : (servers.first ?? "")
        UserDefaults.standard.set(server, forKey: "selectedServer")
        serverIP = nil
        selecting = false
        selection = []
        reload()
        syncWatchers()
    }

    func selectServer(_ name: String) {
        guard name != server || serverIP == nil else { return }
        reloadServers(select: name)
        status = .idle
        notices = []
        Task { await check() }
    }

    /// Refreshes server state and the device list, without waiting.
    func reload() { Task { await reloadAsync() } }

    /// Reads the Desktop folder off the main thread: macOS can hold that read until the user
    /// answers its "access files in your Desktop folder" prompt, and the app must not freeze.
    func reloadAsync() async {
        let srv = server
        let state = configDir.appendingPathComponent("\(srv).last-ip")
        lastIP = (try? String(contentsOf: state, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        lastSynced = (try? FileManager.default.attributesOfItem(atPath: state.path))?[.modificationDate] as? Date
        let ip = lastIP
        let waiting = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled { self?.desktopWaiting = true }
        }
        let (f, d) = await Task.detached(priority: .userInitiated) { () -> (URL?, [Device]) in
            let f = Model.findFolder(server: srv, lastIP: ip)
            return (f, Model.loadDevices(in: f))
        }.value
        waiting.cancel()
        desktopWaiting = false
        guard srv == server else { return }   // switched servers meanwhile
        folder = f
        devices = d
        selection = selection.intersection(deviceNames)
    }

    nonisolated private static func findFolder(server: String, lastIP: String?) -> URL? {
        if let ip = lastIP {
            let u = desktopDir.appendingPathComponent("\(server)-\(ip)")
            if isDirectory(u) { return u }
        }
        let prefix = "\(server)-"
        let items = (try? FileManager.default.contentsOfDirectory(
            at: desktopDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return items
            .filter { $0.lastPathComponent.hasPrefix(prefix)
                && isIPv4(String($0.lastPathComponent.dropFirst(prefix.count))) && isDirectory($0) }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
    }

    nonisolated private static func loadDevices(in folder: URL?) -> [Device] {
        guard let folder else { return [] }
        let fm = FileManager.default
        var byName: [String: Device] = [:]
        let ovpnDir = folder.appendingPathComponent("OpenVPN")
        for f in ((try? fm.contentsOfDirectory(at: ovpnDir, includingPropertiesForKeys: nil)) ?? [])
            where f.pathExtension == "ovpn" {
            let n = f.deletingPathExtension().lastPathComponent
            byName[n, default: Device(name: n)].ovpn = f
        }
        let wgDir = folder.appendingPathComponent("WireGuard")
        for f in ((try? fm.contentsOfDirectory(at: wgDir, includingPropertiesForKeys: nil)) ?? [])
            where f.pathExtension == "conf" {
            let n = f.deletingPathExtension().lastPathComponent
            let qr = wgDir.appendingPathComponent("\(n)-wireguard-qr.png")
            byName[n, default: Device(name: n)].wg = f
            if fm.fileExists(atPath: qr.path) { byName[n]?.qr = qr }
        }
        return byName.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: sync

    func check() async { await run(check: true) }
    func sync() async { await run(check: false) }

    private var ipArgs: [String] {
        let ip = manualIP.trimmingCharacters(in: .whitespaces)
        return isIPv4(ip) ? ["--ip", ip] : []
    }

    private func run(check: Bool) async {
        guard !busy, !server.isEmpty else { return }
        guard cliInstalled else { status = .failed("vpn-sync is not installed at \(cliURL.path)"); return }
        let ip = manualIP.trimmingCharacters(in: .whitespaces)
        if !ip.isEmpty && !isIPv4(ip) { status = .failed("“\(ip)” is not an IPv4 address"); return }
        status = .working(check ? "Checking…" : "Syncing…")
        notices = []
        let (code, output) = await runCLI((check ? ["--check"] : []) + ipArgs + [server])
        apply(output: output, code: code, check: check)
        await reloadAsync()
        if case .upToDate = status, !check { manualIP = "" }
    }

    // MARK: add / remove

    /// Adds (or removes) devices on both VPNs, then syncs. Returns an error message, or nil on success.
    func changeDevices(adding: Bool, _ names: [String]) async -> String? {
        guard !busy else { return "Another operation is still running. Try again in a moment." }
        guard cliInstalled else { return "vpn-sync is not installed at \(cliURL.path)" }
        guard !names.isEmpty else { return "No device names given." }
        progressVerb = adding ? "Adding" : "Removing"
        progressTotal = names.count
        progressDone = 0
        status = .working("\(progressVerb) \(names.count == 1 ? names[0] : "0 of \(names.count)")…")
        notices = []
        let (code, output) = await runCLI([adding ? "--add" : "--remove", names.joined(separator: ",")] + ipArgs + [server])
        progressTotal = 0
        apply(output: output, code: code, check: false)
        await reloadAsync()

        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let marker = adding ? "added device: " : "removed device: "
        let done = lines.filter { $0.hasPrefix(marker) }.map { String($0.dropFirst(marker.count)) }
        selection.subtract(done)
        if !done.isEmpty {
            notices.insert("\(adding ? "Added" : "Removed") \(done.joined(separator: ", ")).", at: 0)
        }
        if code == 0 && done.count == names.count {
            if adding && names.count == 1 { pendingQR = devices.first { $0.name == names[0] && $0.qr != nil } }
            return nil
        }
        if case .unreachable = status { return "Couldn't reach \(server). Press Sync Now first, or enter its IP." }
        let keys = ["already used", "invalid", "failed", "no device named", "listed twice"]
        let reasons = lines.filter { l in l.hasPrefix("server: ") && keys.contains { l.contains($0) } }
            .map { String($0.dropFirst(8)) }
        var msg = reasons.isEmpty ? "\(progressVerb) devices failed. See Details for the log." : reasons.joined(separator: "\n")
        if !done.isEmpty { msg += "\n\(adding ? "Added" : "Removed") anyway: \(done.joined(separator: ", "))" }
        status = .failed(msg)
        return msg
    }

    func removeDevices(_ names: [String]) async {
        if await changeDevices(adding: false, names) == nil {
            if selection.isEmpty { selecting = false }
        }
    }

    // MARK: output handling

    private func apply(output: String, code: Int32, check: Bool) {
        var ip: String?
        var needs = false
        var unreachable = false
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("current IP: ") { ip = String(line.dropFirst(12)) }
            if line.hasPrefix("server: up to date: all configs use ") { ip = line.components(separatedBy: " ").last }
            if line.hasPrefix("server: public IP is ") {
                ip = line.dropFirst(21).components(separatedBy: ";").first
                needs = true
            }
            if line.hasPrefix("would rename") || line.hasPrefix("would create") { needs = true }
            if line.hasPrefix("! could not reach") { unreachable = true }
            if line.contains("server tools aren't installed") { status = .needsInstall; return }
            if line.hasPrefix("OpenVPN Connect: updated") || line.hasPrefix("IP changed") || line.hasPrefix("renamed") {
                notices.append(line)
            }
        }
        if let ip, isIPv4(ip) { serverIP = ip }
        if code != 0 {
            status = unreachable ? .unreachable
                : .failed(output.split(separator: "\n").last.map(String.init) ?? "vpn-sync exited with \(code)")
            return
        }
        status = (check && needs) ? .needsSync : .upToDate
    }

    private func noteProgress(_ chunk: String) {
        guard progressTotal > 1 else { return }
        let marker = progressVerb == "Adding" ? "added device: " : "removed device: "
        progressDone += chunk.components(separatedBy: marker).count - 1
        status = .working("\(progressVerb) \(min(progressDone + 1, progressTotal)) of \(progressTotal)…")
    }

    /// Appends one line per command to ~/.config/vpn-sync/history.log.
    private func appendHistory(_ line: String) {
        let url = configDir.appendingPathComponent("history.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    func runCLI(_ args: [String]) async -> (Int32, String) {
        let cmd = "vpn-sync \(args.joined(separator: " "))"
        log += "$ \(cmd)\n"
        opLog = ""
        appendHistory("start \(cmd)")
        defer { appendHistory("end \(cmd)") }
        let buffer = OutputBuffer()
        let code: Int32 = await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = cliURL
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            p.environment = env
            p.standardInput = FileHandle.nullDevice   // no tty: vpn-sync never prompts
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                guard !d.isEmpty else { return }
                buffer.append(d)
                let s = String(decoding: d, as: UTF8.self)
                Task { @MainActor in self.log += s; self.opLog += s; self.noteProgress(s) }
            }
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                buffer.append(rest)
                let s = String(decoding: rest, as: UTF8.self)
                let status = proc.terminationStatus
                Task { @MainActor in
                    self.log += s
                    self.opLog += s
                    cont.resume(returning: status)
                }
            }
            do { try p.run() } catch {
                buffer.append(Data("could not start vpn-sync: \(error.localizedDescription)\n".utf8))
                cont.resume(returning: -1)
            }
        }
        log += "\n"
        return (code, buffer.string)
    }

    // MARK: files

    func importOnThisMac(_ url: URL) {
        let candidates: [String] = url.pathExtension == "ovpn"
            ? ["/Applications/OpenVPN Connect/OpenVPN Connect.app", "/Applications/OpenVPN Connect.app"]
            : ["/Applications/WireGuard.app"]
        if let app = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: app),
                                    configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Small views

struct StatusPill: View {
    let status: SyncStatus
    var body: some View {
        let (text, color, icon): (String, Color, String) = {
            switch status {
            case .idle: return ("Not checked", .secondary, "circle.dotted")
            case .working(let t): return (t, .blue, "arrow.triangle.2.circlepath")
            case .upToDate: return ("Up to date", .green, "checkmark.circle.fill")
            case .needsSync: return ("Sync needed", .orange, "exclamationmark.circle.fill")
            case .unreachable: return ("Unreachable", .red, "wifi.exclamationmark")
            case .needsInstall: return ("Setup needed", .orange, "wrench.and.screwdriver.fill")
            case .failed: return ("Error", .red, "xmark.octagon.fill")
            }
        }()
        Label(text, systemImage: icon)
            .font(.callout.weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.13), in: Capsule())
    }
}

struct DeviceRow: View {
    @EnvironmentObject var m: Model
    let device: Device

    var body: some View {
        HStack(spacing: 10) {
            if m.selecting {
                Toggle("", isOn: Binding(
                    get: { m.selection.contains(device.name) },
                    set: { on in if on { m.selection.insert(device.name) } else { m.selection.remove(device.name) } }))
                    .toggleStyle(.checkbox).labelsHidden()
            }
            if m.liveState != .off || m.lastSnapshot != nil {
                LiveDot(online: m.isOnline(device.name)).frame(width: 26)
            } else {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.title3).foregroundStyle(.secondary).frame(width: 26)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(device.name).font(.body.weight(.medium))
                    if device.ovpn != nil { Badge(text: "OpenVPN", color: .orange) }
                    if device.wg != nil { Badge(text: "WireGuard", color: .blue) }
                    if device.ovpn == nil && device.wg == nil { Badge(text: "no profile file", color: .secondary) }
                }
                LiveLine(name: device.name)
            }
            Spacer()
            if device.qr != nil && !m.selecting {
                Button { m.qrDevice = device } label: { Label("QR", systemImage: "qrcode") }
                    .help("Show the WireGuard QR code to scan on a phone or TV")
            }
            if !m.selecting {
                Menu {
                    if let u = device.ovpn { Button("Import OpenVPN Profile on This Mac") { m.importOnThisMac(u) } }
                    if let u = device.wg { Button("Import WireGuard Profile on This Mac") { m.importOnThisMac(u) } }
                    Divider()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([device.ovpn, device.wg].compactMap { $0 })
                    }
                    Divider()
                    Button("Remove Device…", role: .destructive) { m.confirmRemoval = [device.name] }
                        .disabled(m.busy)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            guard m.selecting else { return }
            if m.selection.contains(device.name) { m.selection.remove(device.name) } else { m.selection.insert(device.name) }
        }
    }
}

struct QRSheet: View {
    let device: Device
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 14) {
            Text("Scan with the WireGuard app").font(.headline)
            Text(device.name).font(.title2.bold())
            if let qr = device.qr, let img = NSImage(contentsOf: qr) {
                Image(nsImage: img)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 340, height: 340)
                    .padding(10)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8))
            }
            Text("In WireGuard tap + → Create from QR code.\nThis code contains the device's private key; don't share it.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(24)
    }
}

// MARK: - Sheets

struct AddDeviceSheet: View {
    @EnvironmentObject var m: Model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?
    @State private var working = false

    private var problem: String? { name.isEmpty ? nil : nameProblem(name, existing: m.deviceNames) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Device").font(.title2.bold())
            Text("Creates an OpenVPN and a WireGuard profile for one device on \(m.server), copies them to your Desktop and shows the QR code.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Device name, e.g. laptop", text: $name)
                .textFieldStyle(.roundedBorder)
                .disabled(working)
                .onSubmit(create)
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if working {
                    ProgressView().controlSize(.small)
                    Text("Creating… about 10 seconds").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(working || name.isEmpty || problem != nil)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func create() {
        guard !working, !name.isEmpty, problem == nil else { return }
        working = true
        error = nil
        Task {
            let err = await m.changeDevices(adding: true, [name])
            working = false
            if let err { error = err } else { dismiss() }
        }
    }
}

struct BatchAddSheet: View {
    @EnvironmentObject var m: Model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var prefix = "device"
    @State private var start = 1
    @State private var count = 5
    @State private var error: String?
    @State private var working = false

    private var names: [String] { parseNames(text) }
    private var problems: [String] {
        var seen = Set<String>(), out: [String] = []
        for n in names {
            if seen.contains(n) { out.append("“\(n)” is listed twice.") }
            seen.insert(n)
            if let p = nameProblem(n, existing: m.deviceNames) { out.append(p) }
        }
        if names.count > 50 { out.append("At most 50 devices at a time.") }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Batch Add Devices").font(.title2.bold())
            Text("One name per line (or separated by commas). Each device gets an OpenVPN and a WireGuard profile on \(m.server).")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                HStack(spacing: 8) {
                    Text("Generate").font(.callout)
                    TextField("prefix", text: $prefix).textFieldStyle(.roundedBorder).frame(width: 110)
                    Text("from").font(.callout)
                    TextField("", value: $start, format: .number).textFieldStyle(.roundedBorder).frame(width: 50)
                    Text("count").font(.callout)
                    Stepper(value: $count, in: 1...50) { Text("\(count)").monospacedDigit().frame(width: 24) }
                    Spacer()
                    Button("Fill") { fill() }.disabled(working || prefix.isEmpty)
                }
                .disabled(working)
                Text(previewOfGenerator).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(height: 150)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .disabled(working)

            Text(names.isEmpty ? "No names yet." : "\(names.count) device\(names.count == 1 ? "" : "s"): \(names.prefix(12).joined(separator: ", "))\(names.count > 12 ? ", …" : "")")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(problems.prefix(4).enumerated()), id: \.offset) { _, p in
                Text(p).font(.caption).foregroundStyle(.red)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }

            HStack {
                if working, case .working(let t) = m.status {
                    ProgressView().controlSize(.small)
                    Text("\(t) (~10 s each)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Button("Create \(names.count) Device\(names.count == 1 ? "" : "s")", action: create)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(working || names.isEmpty || !problems.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private var generated: [String] { (0..<count).map { "\(prefix)\(start + $0)" } }
    private var previewOfGenerator: String {
        let g = generated
        return g.count <= 3 ? g.joined(separator: ", ") : "\(g[0]), \(g[1]), … \(g[g.count - 1])"
    }

    private func fill() {
        let existing = names
        let add = generated.filter { !existing.contains($0) }
        text = (existing + add).joined(separator: "\n")
    }

    private func create() {
        guard !working, !names.isEmpty, problems.isEmpty else { return }
        working = true
        error = nil
        let list = names
        Task {
            let err = await m.changeDevices(adding: true, list)
            working = false
            if let err { error = err } else { dismiss() }
        }
    }
}

// MARK: - Main window

struct ContentView: View {
    @EnvironmentObject var m: Model
    @State private var showActivity = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            controls
            if !m.server.isEmpty { ServicesBar() }
            hints
            deviceToolbar
            devicesBox
            DisclosureGroup(isExpanded: $showActivity) { ActivityView() } label: {
                Text(m.events.isEmpty ? "Activity" : "Activity (\(m.events.count))")
            }
            DisclosureGroup("Details") {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(m.log.isEmpty ? "No output yet." : m.log)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("log")
                    }
                    .frame(height: 130)
                    .onChange(of: m.log) { proxy.scrollTo("log", anchor: .bottom) }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: 640)
        .task {
            if m.server.isEmpty { m.showAddServer = true; return }
            await m.check()
            if m.monitoring { m.startMonitoring() }
        }
        .sheet(item: $m.qrDevice) { QRSheet(device: $0) }
        .alert(serviceTitle, isPresented: Binding(
            get: { m.confirmService != nil },
            set: { if !$0 { m.confirmService = nil } }), presenting: m.confirmService) { a in
            Button(a.action == "reboot" ? "Reboot" : a.action == "stop" ? "Stop" : "Restart", role: .destructive) {
                Task { await m.runService(a) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { a in
            Text(serviceMessage(a))
        }
        .sheet(isPresented: $m.showServers) { ServerListSheet().environmentObject(m) }
        .sheet(isPresented: $m.showAddServer) { AddServerSheet().environmentObject(m) }
        .sheet(item: Binding(get: { m.editServer.map(ServerRef.init) }, set: { m.editServer = $0?.name })) {
            EditServerSheet(name: $0.name).environmentObject(m)
        }
        .sheet(item: Binding(get: { m.installServer.map(ServerRef.init) }, set: { m.installServer = $0?.name })) {
            InstallSheet(name: $0.name).environmentObject(m)
        }
        .alert(removalTitle, isPresented: Binding(
            get: { m.confirmRemoval != nil },
            set: { if !$0 { m.confirmRemoval = nil } }), presenting: m.confirmRemoval) { names in
            Button(names.count == 1 ? "Remove" : "Remove \(names.count) Devices", role: .destructive) {
                Task { await m.removeDevices(names) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { names in
            Text("\(names.joined(separator: ", ")) will stop working right away on both OpenVPN and WireGuard. Revoking the OpenVPN certificate can't be undone; the profile files are kept in a backup on the server.")
        }
    }

    private var serviceTitle: String {
        guard let a = m.confirmService else { return "" }
        if a.action == "reboot" { return "Reboot \(a.server)?" }
        return "\(a.action == "stop" ? "Stop" : "Restart") \(a.vpnLabel) on \(a.server)?"
    }

    private func serviceMessage(_ a: ServiceAction) -> String {
        let mac = "If this Mac is connected through it, it loses internet until the VPN is back (or you disconnect the VPN app)."
        switch a.action {
        case "reboot":
            return "Every device on \(a.server) is disconnected for about a minute while it restarts. The IP address stays the same. \(mac)"
        case "stop":
            return "Every device connected through \(a.vpnLabel) is disconnected and can't reconnect until you start it again. It also starts again automatically if the server reboots. \(mac)"
        default:
            return "Devices connected through \(a.vpnLabel) drop for a few seconds and then reconnect on their own."
        }
    }

    private var removalTitle: String {
        guard let names = m.confirmRemoval else { return "" }
        return names.count == 1 ? "Remove “\(names[0])”?" : "Remove \(names.count) devices?"
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "network.badge.shield.half.filled")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if m.servers.isEmpty {
                        Text("No servers yet").font(.title2.bold())
                    } else {
                        Menu {
                            ForEach(m.servers, id: \.self) { s in
                                Button { m.selectServer(s) } label: {
                                    if s == m.server { Label(s, systemImage: "checkmark") } else { Text(s) }
                                }
                            }
                            Divider()
                            Button("Add Server…") { m.showAddServer = true }
                            Button("Manage Servers…") { m.showServers = true }
                        } label: {
                            Text(m.server).font(.title2.bold())
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .disabled(m.busy)
                        .help("Switch server")
                    }
                    Button { m.showServers = true } label: { Image(systemName: "server.rack") }
                        .buttonStyle(.borderless)
                        .help("Manage servers")
                }
                HStack(spacing: 6) {
                    Text(m.serverIP ?? m.lastIP ?? "—")
                        .font(.system(.title3, design: .monospaced))
                        .textSelection(.enabled)
                    if let ip = m.serverIP ?? m.lastIP {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(ip, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).help("Copy IP")
                    }
                }
                if let d = m.lastSynced {
                    Text("Last synced \(d.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            StatusPill(status: m.status)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            TextField("Server IP (optional)", text: $m.manualIP)
                .textFieldStyle(.roundedBorder)
                .frame(width: 190)
                .onSubmit { Task { await m.sync() } }
                .help("Leave empty to find the server automatically, or paste the IP from the Lightsail console")
            Button { Task { await m.check() } } label: { Label("Check", systemImage: "magnifyingglass") }
                .disabled(m.busy)
            Button { Task { await m.sync() } } label: { Label("Sync Now", systemImage: "arrow.triangle.2.circlepath") }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(m.busy)
            if m.busy { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder private var hints: some View {
        switch m.status {
        case .unreachable:
            VStack(alignment: .leading, spacing: 6) {
                Text("Couldn't reach \(m.server). Its IP has probably changed.")
                    .font(.callout.weight(.semibold))
                Text("Paste its current public IPv4 (from your provider's console) into the box above and press Sync Now, or change its address under Edit Server. If this Mac is connected to \(m.server)'s VPN, disconnect it first.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    if let url = m.consoleURL { Link("Open Lightsail console", destination: url).font(.callout) }
                    Button("Edit Server…") { m.editServer = m.server }.controlSize(.small)
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        case .needsInstall:
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(m.server) isn't set up for VPN Sync yet.").font(.callout.weight(.semibold))
                    Text("Install the server tools, and OpenVPN/WireGuard if they're missing. Existing VPN setups are kept.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Set Up…") { m.installServer = m.server }.buttonStyle(.borderedProminent)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        case .needsSync:
            Text("The server's IP or profiles changed. Press Sync Now to update the profiles on your Desktop.")
                .font(.callout)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 4) {
                Text(msg).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                ForEach(m.notices, id: \.self) { Text($0).font(.callout) }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        default:
            if !m.notices.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(m.notices, id: \.self) { Text($0).font(.callout) }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    @ViewBuilder private var deviceToolbar: some View {
        HStack(spacing: 8) {
            if m.selecting {
                Text(m.selection.isEmpty ? "Select devices to remove" : "\(m.selection.count) selected")
                    .font(.callout.weight(.medium))
                Button(m.selection.count == m.devices.count ? "Select None" : "Select All") {
                    m.selection = m.selection.count == m.devices.count ? [] : m.deviceNames
                }
                .controlSize(.small)
                Spacer()
                Button("Cancel") { m.selecting = false; m.selection = [] }
                    .controlSize(.small)
                Button(role: .destructive) {
                    m.confirmRemoval = m.devices.map(\.name).filter { m.selection.contains($0) }
                } label: {
                    Label("Remove \(m.selection.count) Device\(m.selection.count == 1 ? "" : "s")…", systemImage: "trash")
                }
                .controlSize(.small)
                .tint(.red)
                .buttonStyle(.borderedProminent)
                .disabled(m.selection.isEmpty || m.busy)
            } else {
                Button { m.showAddDevice = true } label: { Label("Add Device", systemImage: "plus") }
                Button { m.showBatchAdd = true } label: { Label("Batch Add…", systemImage: "plus.square.on.square") }
                Button { m.selection = []; m.selecting = true } label: { Label("Batch Remove…", systemImage: "trash") }
                    .disabled(m.devices.isEmpty)
                Spacer()
                LiveToggle()
                if let f = m.folder {
                    Button { NSWorkspace.shared.open(f) } label: { Label("Open Folder", systemImage: "folder") }
                }
            }
        }
        .controlSize(.small)
        .disabled(m.server.isEmpty || (m.busy && !m.selecting))
    }

    /// Devices with profile files, plus devices only seen live; online ones first.
    private var rows: [Device] {
        let known = Set(m.devices.map(\.name))
        let extra = m.allDeviceNames.filter { !known.contains($0) }.map { Device(name: $0) }
        let all = m.devices + extra
        guard m.lastSnapshot != nil else { return all }
        return all.filter { m.isOnline($0.name) } + all.filter { !m.isOnline($0.name) }
    }

    private var devicesBox: some View {
        GroupBox {
            if m.desktopWaiting {
                VStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for permission to read your Desktop folder.").font(.callout.weight(.medium))
                    Text("Click Allow in the macOS prompt, or turn it on in System Settings → Privacy & Security → Files and Folders → VPN Sync.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else if m.devices.isEmpty {
                Text(m.folder == nil ? "No profiles on the Desktop yet. Press Sync Now." : "No devices yet. Press Add Device.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(rows) { d in
                            DeviceRow(device: d)
                            if d != rows.last { Divider() }
                        }
                    }
                    .padding(.horizontal, 6)
                }
            }
        } label: {
            HStack {
                Text(m.lastSnapshot == nil ? "Devices (\(rows.count))" : "Devices (\(rows.count), \(m.onlineCount) online)")
                    .font(.headline)
                if let f = m.folder {
                    Text("~/Desktop/\(f.lastPathComponent)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .sheet(isPresented: $m.showAddDevice, onDismiss: {
            if let p = m.pendingQR { m.pendingQR = nil; m.qrDevice = p }
        }) { AddDeviceSheet().environmentObject(m) }
        .sheet(isPresented: $m.showBatchAdd) { BatchAddSheet().environmentObject(m) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Stay running in the menu bar when the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Notifier.shared.setup()
            if Model.shared?.notify ?? true { Notifier.shared.requestPermission() }  // macOS asks only once
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Model.shared?.stopMonitoring() }   // don't leave the SSH watcher running
    }
}

@main
struct VPNSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = Model()
    var body: some Scene {
        // WindowGroup (not Window) so the window also appears when launched in the
        // background or reopened from the Dock; New Window is removed to keep one window.
        WindowGroup("VPN Sync", id: "main") {
            ContentView().environmentObject(model)
        }
        .defaultSize(width: 620, height: 700)
        .commands { CommandGroup(replacing: .newItem) {} }

        // Menu bar: devices online across all servers. Keeps monitoring and notifications
        // running after the window is closed; quit from here or with ⌘Q.
        MenuBarExtra {
            MenuBarPanel(m: model)
        } label: {
            MenuBarLabel(m: model)
        }
        .menuBarExtraStyle(.window)
    }
}

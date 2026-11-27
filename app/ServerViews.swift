// Server management: list, add (with host-key check), edit, remove, and set up/install.
import SwiftUI
import AppKit

struct ServerRef: Identifiable { let name: String; var id: String { name } }

/// Settings of one server, read from ~/.config/vpn-sync/<name>.conf.
struct ServerInfo {
    var host = "", user = "ubuntu", key = "", port = "22", jump = "", privateIP = "", region = "", lastIP = ""
    init() {}
    init(name: String) {
        host = configValue("HOST", server: name) ?? ""
        user = configValue("SSH_USER", server: name) ?? "ubuntu"
        key = configValue("SSH_KEY", server: name) ?? ""
        port = configValue("SSH_PORT", server: name) ?? "22"
        jump = configValue("JUMP", server: name) ?? ""
        privateIP = configValue("PRIVATE_IP", server: name) ?? ""
        region = configValue("LIGHTSAIL_REGION", server: name) ?? ""
        lastIP = ((try? String(contentsOf: configDir.appendingPathComponent("\(name).last-ip"), encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var address: String { lastIP.isEmpty ? host : lastIP }
}

func parseKV(_ text: String) -> [String: String] {
    var out: [String: String] = [:]
    for line in text.split(separator: "\n") {
        guard let eq = line.firstIndex(of: "="), line.first?.isUppercase == true else { continue }
        out[String(line[..<eq])] = String(line[line.index(after: eq)...])
    }
    return out
}

func lastLines(_ text: String, _ n: Int = 3) -> String {
    text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("trying ") }.suffix(n).joined(separator: "\n")
}

func isValidServerName(_ s: String) -> Bool {
    !s.isEmpty && s.count <= 40 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
}
func isValidHost(_ s: String) -> Bool {
    !s.isEmpty && s.count <= 253 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
}

func chooseKeyFile() -> String? {
    let panel = NSOpenPanel()
    panel.title = "Choose the server's private key"
    panel.message = "Pick the SSH private key for this server (for Lightsail: the default key .pem you downloaded)."
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    return panel.runModal() == .OK ? panel.url?.path : nil
}

extension Model {
    /// Runs a vpn-sync command for a sheet, waiting for any running operation first.
    func cli(_ args: [String], label: String) async -> (Int32, String) {
        for _ in 0..<240 where busy { try? await Task.sleep(nanoseconds: 250_000_000) }
        guard !busy else { return (-2, "Another operation is still running.") }
        status = .working(label)
        let r = await runCLI(args)
        if case .working = status { status = .idle }
        return r
    }
}

/// Live command output, for sheets.
struct OutputView: View {
    let text: String
    var height: CGFloat = 160
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? " " : text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .id("out")
            }
            .frame(height: height)
            .glassPanel(14)
            .onChange(of: text) { proxy.scrollTo("out", anchor: .bottom) }
        }
    }
}

struct FormRow<Content: View>: View {
    let label: String
    var hint: String? = nil
    @ViewBuilder let content: Content
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).frame(width: 120, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                content
                if let hint { Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }
}

// MARK: - Server list

struct ServerListSheet: View {
    @EnvironmentObject var m: Model
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var editing: ServerRef?
    @State private var installing: ServerRef?
    @State private var removing: ServerRef?
    @State private var error: String?
    @State private var renaming: String?
    @State private var newName = ""
    @State private var renameBusy = false
    @FocusState private var nameFocused: Bool

    private func renameProblem(_ old: String) -> String? {
        if newName.isEmpty { return "Enter a name." }
        if !isValidServerName(newName) { return "Use letters, numbers, - and _ (no spaces), up to 40." }
        if newName != old && m.servers.contains(newName) { return "“\(newName)” already exists." }
        return nil
    }

    /// The server's total speed over the last 15 minutes (all devices; download above the line,
    /// upload below) and how many devices are online, when live monitoring is on.
    @ViewBuilder private func serverActivity(_ name: String) -> some View {
        if let w = m.watchers[name], w.link == .live {
            let cutoff = (w.history.last?.time ?? Date()).addingTimeInterval(-900)
            HStack(spacing: 8) {
                Sparkline(history: w.history.filter { $0.time >= cutoff }, name: name, width: 64, height: 22)
                Text("\(w.onlineDevices.count) online")
                    .font(.system(.caption, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .leading)
            }
            .help("All devices on \(name), last 15 minutes")
        }
    }

    private func rename(_ old: String) {
        guard renameProblem(old) == nil, newName != old, !renameBusy else { return }
        renameBusy = true
        let to = newName
        Task {
            let (code, out) = await m.cli(["server", "rename", old, to], label: "Renaming \(old)…")
            renameBusy = false
            if code == 0 {
                renaming = nil; error = nil
                m.reloadServers(select: m.server == old ? to : nil)
            } else {
                error = "Not renamed: " + lastLines(out, 1).replacingOccurrences(of: "vpn-sync: ", with: "")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Servers").font(.system(size: 22, weight: .bold, design: .rounded))
            if m.servers.isEmpty {
                Text("No servers yet. Add one to get started.").foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(m.servers, id: \.self) { name in
                    let info = ServerInfo(name: name)
                    HStack(spacing: 10) {
                        LucideIcon(name == m.server ? "circle-check" : "server", size: 16)
                            .foregroundStyle(name == m.server ? Color.accentColor : .secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            if renaming == name {
                                HStack(spacing: 6) {
                                    TextField("New name", text: $newName)
                                        .textFieldStyle(.roundedBorder).frame(width: 200)
                                        .focused($nameFocused)
                                        .onSubmit { rename(name) }
                                    Button("Save") { rename(name) }
                                        .glassButton(prominent: true)
                                        .disabled(renameBusy || newName == name || renameProblem(name) != nil)
                                    Button("Cancel") { renaming = nil }.disabled(renameBusy)
                                }
                                Text(renameProblem(name) ?? "Its Desktop folder is renamed too.")
                                    .font(.caption)
                                    .foregroundStyle(renameProblem(name) == nil ? Color.secondary : Color.red)
                            } else {
                                HStack(spacing: 10) {
                                    Text(name).font(.system(.body, design: .rounded).weight(.semibold))
                                        .lineLimit(1).fixedSize()
                                    serverActivity(name)
                                }
                                Text("\(info.user)@\(info.address.isEmpty ? "?" : info.address)\(info.jump.isEmpty ? "" : ", through \(info.jump) at \(info.privateIP)")")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                                    .help("\(info.user)@\(info.address)\(info.jump.isEmpty ? "" : ", through \(info.jump) at \(info.privateIP)")")
                            }
                        }
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(-1)      // the buttons keep their width; a long address gives way
                        if renaming != name {
                            if name != m.server {
                                Button("Use") { m.selectServer(name); dismiss() }
                            }
                            Button("Rename…") { renaming = name; newName = name; error = nil; nameFocused = true }
                        }
                        Button("Edit…") { editing = ServerRef(name: name) }
                        Button("Set Up…") { installing = ServerRef(name: name) }
                            .help("Install or repair OpenVPN, WireGuard and the server tools")
                        Button { removing = ServerRef(name: name) } label: { LucideIcon("trash-2") }
                            .help("Remove from VPN Sync")
                    }
                    .controlSize(.small)
                    .padding(.vertical, 10).padding(.horizontal, 12)
                    .glassPanel(16)
                    .padding(.bottom, 8)
                }
            }
            .disabled(m.busy)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Button { adding = true } label: { Label("Add Server…", lucide: "plus") }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).glassButton(prominent: true)
            }
        }
        .padding(24)
        .frame(width: 650)
        .glassSheet()
        .sheet(isPresented: $adding) { AddServerSheet().environmentObject(m) }
        .sheet(item: $editing) { EditServerSheet(name: $0.name).environmentObject(m) }
        .sheet(item: $installing) { InstallSheet(name: $0.name).environmentObject(m) }
        .alert("Remove “\(removing?.name ?? "")” from VPN Sync?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { ref in
            Button("Remove", role: .destructive) {
                Task {
                    let (code, out) = await m.cli(["server", "remove", ref.name], label: "Removing server…")
                    error = code == 0 ? nil : lastLines(out)
                    m.reloadServers()
                    if !m.server.isEmpty { await m.check() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This only removes it from this Mac: its settings, the copy of its key and its pinned host key. The server keeps running and its Desktop folder is kept.")
        }
    }
}

// MARK: - Add server

struct AddServerSheet: View {
    @EnvironmentObject var m: Model
    @Environment(\.dismiss) private var dismiss

    enum Step { case details, verify, setup }
    @State private var step: Step = .details
    @State private var name = ""
    @State private var host = ""
    @State private var user = "ubuntu"
    @State private var port = "22"
    @State private var keyPath = ""
    @State private var useJump = false
    @State private var jump = ""
    @State private var privateIP = ""
    @State private var region = ""
    @State private var hostKey = ""
    @State private var fingerprint = ""
    @State private var error: String?
    @State private var working = false

    private var problem: String? {
        if !name.isEmpty && !isValidServerName(name) { return "Name: use letters, numbers, - and _ (no spaces)." }
        if m.servers.contains(name) { return "A server named “\(name)” already exists." }
        if !host.isEmpty && !isValidHost(host) { return "Address: an IP address or hostname." }
        if Int(port).map({ !(1...65535).contains($0) }) ?? true { return "SSH port must be 1–65535." }
        if useJump && !privateIP.isEmpty && !isIPv4(privateIP) { return "Private IP must be an IPv4 address." }
        return nil
    }
    private var ready: Bool {
        !name.isEmpty && !host.isEmpty && !user.isEmpty && !keyPath.isEmpty && problem == nil
            && (!useJump || (!jump.isEmpty && isIPv4(privateIP)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(step == .setup ? "Set Up \(name)" : "Add Server").font(.system(size: 22, weight: .bold, design: .rounded))
            switch step {
            case .details: details
            case .verify: verify
            case .setup: InstallPanel(name: name, onDone: { dismiss() })
            }
        }
        .padding(24)
        .frame(width: 600)
        .glassSheet()
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Any Ubuntu, Debian, AlmaLinux, Rocky, CentOS or Fedora server you can SSH into with a key. Fresh servers get OpenVPN and WireGuard installed in the next step.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            FormRow(label: "Name", hint: "Shown in VPN Sync and used for the Desktop folder, e.g. Tokyo-1.") {
                TextField("MyServer", text: $name).textFieldStyle(.roundedBorder)
            }
            FormRow(label: "Address", hint: "The server's public IP or hostname.") {
                TextField("203.0.113.10", text: $host).textFieldStyle(.roundedBorder)
            }
            FormRow(label: "SSH user", hint: "ubuntu on Lightsail/EC2 Ubuntu, admin on Debian, root on most other VPS.") {
                HStack {
                    TextField("ubuntu", text: $user).textFieldStyle(.roundedBorder).frame(width: 160)
                    Text("Port").foregroundStyle(.secondary)
                    TextField("22", text: $port).textFieldStyle(.roundedBorder).frame(width: 60)
                }
            }
            FormRow(label: "Private key", hint: "Lightsail: Account → SSH keys → download the default key for the region (.pem). A copy is kept in ~/.config/vpn-sync/keys.") {
                HStack {
                    Text(keyPath.isEmpty ? "No key chosen" : (keyPath as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(keyPath.isEmpty ? .secondary : .primary)
                    Spacer()
                    Button("Choose…") { if let p = chooseKeyFile() { keyPath = p } }
                }
            }
            FormRow(label: "Lightsail region", hint: "Optional, e.g. ap-northeast-1. Adds a console link when the server can't be reached.") {
                TextField("optional", text: $region).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            if !m.servers.isEmpty {
                FormRow(label: "", hint: useJump ? "Use when SSH is closed to the internet but this server shares a private network with another one (e.g. Lightsail servers in the same region)." : nil) {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Connect through another server", isOn: $useJump)
                        if useJump {
                            HStack {
                                Picker("Via", selection: $jump) {
                                    Text("Choose…").tag("")
                                    ForEach(m.servers, id: \.self) { Text($0).tag($0) }
                                }
                                .frame(width: 220)
                                TextField("private IP, e.g. 172.26.0.10", text: $privateIP)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                }
            }
            if let problem { Text(problem).font(.callout).foregroundStyle(.red) }
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if working { ProgressView().controlSize(.small); Text("Contacting server…").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Button("Next") { Task { await fetchHostKey() } }
                    .keyboardShortcut(.defaultAction).glassButton(prominent: true)
                    .disabled(!ready || working)
            }
        }
    }

    private var verify: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Check the server's identity").font(.headline)
            Text("This is the fingerprint of \(useJump ? privateIP : host)'s SSH host key. VPN Sync will only ever talk to a server with this key. On a server you just created it's normally fine to accept; to be sure, compare it with the output of `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on the server.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(fingerprint)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassPanel(14)
            if !m.opLog.isEmpty && working { OutputView(text: m.opLog, height: 90) }
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if working { ProgressView().controlSize(.small); Text("Adding and logging in…").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Back") { step = .details; error = nil }.disabled(working)
                Button("Trust and Add") { Task { await addServer() } }
                    .keyboardShortcut(.defaultAction).glassButton(prominent: true).disabled(working)
            }
        }
    }

    private func fetchHostKey() async {
        working = true; error = nil
        defer { working = false }
        var args = ["server", "hostkey", "--port", port]
        if useJump { args += ["--jump", jump, "--private-ip", privateIP] } else { args += ["--host", host] }
        let (code, out) = await m.cli(args, label: "Contacting \(host)…")
        let kv = parseKV(out)
        guard code == 0, let hk = kv["HOSTKEY"], let fp = kv["FINGERPRINT"] else {
            error = "Couldn't get the server's SSH key. \(lastLines(out, 2))\nCheck the address and that port \(port) is open in the server's firewall."
            return
        }
        hostKey = hk; fingerprint = fp; step = .verify
    }

    private func addServer() async {
        working = true; error = nil
        defer { working = false }
        var args = ["server", "add", name, "--host", host, "--user", user, "--port", port,
                    "--key", keyPath, "--hostkey-line", hostKey]
        if useJump { args += ["--jump", jump, "--private-ip", privateIP] }
        if !region.isEmpty { args += ["--region", region] }
        let (code, out) = await m.cli(args, label: "Adding \(name)…")
        let saved = FileManager.default.fileExists(atPath: configDir.appendingPathComponent("\(name).conf").path)
        if !saved {
            error = "Not added: \(lastLines(out, 2))"
            return
        }
        m.reloadServers(select: name)
        if code != 0 {
            error = "Saved, but logging in failed: \(lastLines(out, 2)). Fix it with Edit… in Servers."
            return
        }
        step = .setup
    }
}

// MARK: - Edit server

struct EditServerSheet: View {
    let name: String
    @EnvironmentObject var m: Model
    @Environment(\.dismiss) private var dismiss
    @State private var info = ServerInfo()
    @State private var newKey = ""
    @State private var useJump = false
    @State private var error: String?
    @State private var note: String?
    @State private var working = false
    @State private var newHostKey = ""
    @State private var newFingerprint = ""

    private var problem: String? {
        if !isValidHost(info.host) { return "Address: an IP address or hostname." }
        if info.user.isEmpty { return "SSH user is required." }
        if Int(info.port).map({ !(1...65535).contains($0) }) ?? true { return "SSH port must be 1–65535." }
        if useJump && (info.jump.isEmpty || !isIPv4(info.privateIP)) { return "Choose a server to go through and its private IPv4." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit \(name)").font(.system(size: 22, weight: .bold, design: .rounded))
            FormRow(label: "Address", hint: info.lastIP.isEmpty || info.lastIP == info.host ? "Public IP or hostname. Change it here when the server's IP changes." : "Last seen at \(info.lastIP). Change it here when the server's IP changes.") {
                TextField("IP or hostname", text: $info.host).textFieldStyle(.roundedBorder)
            }
            FormRow(label: "SSH user") {
                HStack {
                    TextField("ubuntu", text: $info.user).textFieldStyle(.roundedBorder).frame(width: 160)
                    Text("Port").foregroundStyle(.secondary)
                    TextField("22", text: $info.port).textFieldStyle(.roundedBorder).frame(width: 60)
                }
            }
            FormRow(label: "Private key") {
                HStack {
                    Text(((newKey.isEmpty ? info.key : newKey) as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1).truncationMode(.middle)
                    if !newKey.isEmpty { Text("(new)").font(.caption).foregroundStyle(.orange) }
                    Spacer()
                    Button("Choose…") { if let p = chooseKeyFile() { newKey = p } }
                }
            }
            FormRow(label: "Lightsail region") {
                TextField("optional", text: $info.region).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            FormRow(label: "") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Connect through another server", isOn: $useJump)
                    if useJump {
                        HStack {
                            Picker("Via", selection: $info.jump) {
                                Text("Choose…").tag("")
                                ForEach(m.servers.filter { $0 != name }, id: \.self) { Text($0).tag($0) }
                            }
                            .frame(width: 220)
                            TextField("private IP", text: $info.privateIP).textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }
            Divider()
            FormRow(label: "Host key", hint: newFingerprint.isEmpty ? "If the server was rebuilt it has a new SSH key and VPN Sync will refuse to connect. Fetch and trust the new one here." : "New fingerprint: \(newFingerprint). It's saved when you press Save.") {
                Button("Fetch New Host Key…") { Task { await fetchHostKey() } }.disabled(working)
            }
            if let problem { Text(problem).font(.callout).foregroundStyle(.red) }
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            if let note { Text(note).font(.callout).foregroundStyle(.green) }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Button("Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction).glassButton(prominent: true)
                    .disabled(working || problem != nil)
            }
        }
        .padding(24)
        .frame(width: 600)
        .glassSheet()
        .onAppear {
            info = ServerInfo(name: name)
            if info.host.isEmpty { info.host = info.lastIP }
            useJump = !info.jump.isEmpty
        }
    }

    private func fetchHostKey() async {
        working = true; error = nil
        defer { working = false }
        var args = ["server", "hostkey", "--port", info.port]
        if useJump { args += ["--jump", info.jump, "--private-ip", info.privateIP] } else { args += ["--host", info.host] }
        let (code, out) = await m.cli(args, label: "Fetching host key…")
        let kv = parseKV(out)
        guard code == 0, let hk = kv["HOSTKEY"], let fp = kv["FINGERPRINT"] else {
            error = "Couldn't get the host key: \(lastLines(out, 2))"; return
        }
        newHostKey = hk; newFingerprint = fp
    }

    private func save() async {
        working = true; error = nil; note = nil
        defer { working = false }
        var args = ["server", "edit", name, "--host", info.host, "--user", info.user, "--port", info.port,
                    "--jump", useJump ? info.jump : "none"]
        if useJump { args += ["--private-ip", info.privateIP] }
        if !info.region.isEmpty { args += ["--region", info.region] }
        if !newKey.isEmpty { args += ["--key", newKey] }
        if !newHostKey.isEmpty { args += ["--hostkey-line", newHostKey] }
        let (code, out) = await m.cli(args, label: "Saving \(name)…")
        guard code == 0 else { error = lastLines(out, 2); return }
        m.reloadServers(select: m.server == name ? name : nil)
        if m.server == name { m.manualIP = "" ; Task { await m.check() } }
        dismiss()
    }
}

// MARK: - Install / set up

struct InstallSheet: View {
    let name: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set Up \(name)").font(.system(size: 22, weight: .bold, design: .rounded))
            InstallPanel(name: name, onDone: { dismiss() })
        }
        .padding(24)
        .frame(width: 600)
        .glassSheet()
    }
}

struct InstallPanel: View {
    let name: String
    let onDone: () -> Void
    @EnvironmentObject var m: Model

    enum Phase { case probing, ready, installing, finished, failed }
    @State private var phase: Phase = .probing
    @State private var probe: [String: String] = [:]
    @State private var error: String?
    @State private var installOVPN = true
    @State private var ovpnProto = "tcp"
    @State private var ovpnPort = "443"
    @State private var installWG = true
    @State private var wgPort = "443"
    @State private var dns = 3
    @State private var installIPsec = false
    @State private var client = "client"

    private let dnsChoices = [(1, "System resolvers"), (2, "Google"), (3, "Cloudflare 1.1.1.1"), (4, "OpenDNS"),
                              (5, "Quad9"), (6, "Gcore"), (7, "AdGuard")]
    private var hasOVPN: Bool { (probe["OPENVPN"] ?? "none") != "none" }
    private var hasWG: Bool { (probe["WIREGUARD"] ?? "none") != "none" }
    /// nil when the server's tools are too old to report it
    private var hasIPsec: Bool? { probe["IPSEC"].map { $0 != "none" } }
    private var willInstallIPsec: Bool { hasIPsec == false && installIPsec }
    private var hasTools: Bool { probe["TOOLS"] == "installed" }
    private var willInstallVPN: Bool { (!hasOVPN && installOVPN) || (!hasWG && installWG) }

    private var problem: String? {
        if !hasOVPN && installOVPN && !(Int(ovpnPort).map { (1...65535).contains($0) } ?? false) { return "OpenVPN port must be 1–65535." }
        if !hasWG && installWG && !(Int(wgPort).map { (1...65535).contains($0) } ?? false) { return "WireGuard port must be 1–65535." }
        if !hasOVPN && installOVPN && !hasWG && installWG && ovpnProto == "udp" && ovpnPort == wgPort {
            return "OpenVPN (UDP) and WireGuard can't share a UDP port."
        }
        if willInstallVPN && nameProblem(client, existing: []) != nil { return "First device name: 1–15 letters, numbers, - or _." }
        if !hasOVPN && !hasWG && !installOVPN && !installWG { return "Choose at least one VPN to install." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch phase {
            case .probing:
                HStack { ProgressView().controlSize(.small); Text("Checking what's installed on \(name)…") }
                OutputView(text: m.opLog, height: 80)
            case .ready:
                options
            case .installing:
                Text(willInstallVPN || willInstallIPsec ? "Installing… a fresh OpenVPN or IPsec install takes a few minutes. Keep this window open." : "Setting up…")
                    .font(.callout)
                OutputView(text: m.opLog, height: 260)
            case .finished:
                Label("\(name) is ready.", lucide: "circle-check").foregroundStyle(.green).font(.headline)
                Text("Its profiles were copied to your Desktop. Make sure the VPN ports are open in the server's firewall (\(portSummary)).")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                OutputView(text: m.opLog, height: 160)
                HStack { Spacer(); Button("Done") { m.selectServer(name); onDone() }.keyboardShortcut(.defaultAction).glassButton(prominent: true) }
            case .failed:
                Label("Setup didn't finish.", lucide: "octagon-x").foregroundStyle(.red).font(.headline)
                if let error { Text(error).font(.callout).fixedSize(horizontal: false, vertical: true) }
                OutputView(text: m.opLog, height: 200)
                HStack {
                    Spacer()
                    Button("Close") { onDone() }
                    Button("Check Again") { Task { await runProbe() } }.glassButton(prominent: true)
                }
            }
        }
        .task { await runProbe() }
    }

    private var portSummary: String {
        var parts: [String] = []
        if let o = probe["OPENVPN"], o != "none" { parts.append(o.uppercased()) }
        else if installOVPN { parts.append("\(ovpnProto.uppercased()) \(ovpnPort)") }
        if let w = probe["WIREGUARD"], w != "none" { parts.append(w.uppercased()) }
        else if installWG { parts.append("UDP \(wgPort)") }
        if hasIPsec == true || willInstallIPsec { parts.append("UDP 500 and 4500 for IKEv2") }
        return parts.joined(separator: ", ")
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow { Text("System").foregroundStyle(.secondary); Text(probe["OS"] ?? "unknown") }
                GridRow { Text("OpenVPN").foregroundStyle(.secondary); Text(hasOVPN ? "installed (\(probe["OPENVPN"]!.uppercased())), will be kept" : "not installed") }
                GridRow { Text("WireGuard").foregroundStyle(.secondary); Text(hasWG ? "installed (\(probe["WIREGUARD"]!.uppercased())), will be kept" : "not installed") }
                GridRow {
                    Text("IPsec/IKEv2").foregroundStyle(.secondary)
                    Text(hasIPsec == true ? "installed (\(probe["IPSEC"]!.replacingOccurrences(of: "ikev2", with: "IKEv2, Libreswan"))), will be kept" : "not installed")
                }
                GridRow { Text("Server tools").foregroundStyle(.secondary); Text(hasTools ? "installed (will be updated)" : "will be installed") }
            }
            .font(.callout)
            if probe["PKG"] == "unsupported" {
                Text("This system isn't supported (needs apt or dnf).").foregroundStyle(.red)
            }
            if !hasOVPN || !hasWG {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        if !hasOVPN {
                            HStack {
                                Toggle("Install OpenVPN", isOn: $installOVPN).frame(width: 170, alignment: .leading)
                                Picker("", selection: $ovpnProto) { Text("TCP").tag("tcp"); Text("UDP").tag("udp") }
                                    .pickerStyle(.segmented).frame(width: 110).labelsHidden().disabled(!installOVPN)
                                Text("port").foregroundStyle(.secondary)
                                TextField("443", text: $ovpnPort).textFieldStyle(.roundedBorder).frame(width: 70).disabled(!installOVPN)
                            }
                        }
                        if !hasWG {
                            HStack {
                                Toggle("Install WireGuard", isOn: $installWG).frame(width: 170, alignment: .leading)
                                Text("UDP port").foregroundStyle(.secondary)
                                TextField("443", text: $wgPort).textFieldStyle(.roundedBorder).frame(width: 70).disabled(!installWG)
                            }
                        }
                        HStack {
                            Text("DNS for devices").frame(width: 170, alignment: .leading)
                            Picker("", selection: $dns) { ForEach(dnsChoices, id: \.0) { Text($0.1).tag($0.0) } }
                                .labelsHidden().frame(width: 200)
                        }
                        HStack {
                            Text("First device name").frame(width: 170, alignment: .leading)
                            TextField("client", text: $client).textFieldStyle(.roundedBorder).frame(width: 140)
                        }
                        Text("TCP 443 looks like normal HTTPS traffic and gets through most networks; WireGuard on UDP 443 is faster. Open the same ports in the server's firewall (Lightsail: instance → Networking → Add rule).")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                }
                .glassPanel(18)
            } else {
                Text(hasTools ? "Everything is installed. Running setup again updates the server tools and keeps all VPN settings and devices."
                              : "Both VPNs are installed. Setup adds the server tools and keeps all VPN settings and devices.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if hasIPsec != true {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Also install IPsec/IKEv2", isOn: $installIPsec)
                    Text("Built into macOS, iOS, Windows and Android, no app needed. Uses hwdsl2's setup-ipsec-vpn in IKEv2-only mode; every device gets an IKEv2 profile. Open UDP 500 and 4500 in the server's firewall.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .glassPanel(18)
            }
            if let problem { Text(problem).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { onDone() }.keyboardShortcut(.cancelAction)
                Button(willInstallVPN || willInstallIPsec ? "Install" : (hasTools ? "Update Tools" : "Set Up")) { Task { await install() } }
                    .keyboardShortcut(.defaultAction).glassButton(prominent: true)
                    .disabled(problem != nil || probe["PKG"] == "unsupported")
            }
        }
    }

    private func runProbe() async {
        phase = .probing; error = nil
        let (code, out) = await m.cli(["server", "probe", name], label: "Checking \(name)…")
        probe = parseKV(out)
        guard code == 0, probe["OS"] != nil else {
            error = probe["SUDO"] == "no" ? "The SSH user can't run sudo without a password. Use root or a user with passwordless sudo."
                                          : "Couldn't reach \(name): \(lastLines(out, 2))"
            phase = .failed; return
        }
        if let o = probe["OPENVPN"], o != "none" { installOVPN = false }
        if let w = probe["WIREGUARD"], w != "none" { installWG = false }
        phase = .ready
    }

    private func install() async {
        phase = .installing
        var args = ["server", "install", name, "--dns", String(dns), "--client", client]
        if !hasOVPN {
            if installOVPN { args += ["--openvpn-proto", ovpnProto, "--openvpn-port", ovpnPort] } else { args.append("--no-openvpn") }
        }
        if !hasWG {
            if installWG { args += ["--wireguard-port", wgPort] } else { args.append("--no-wireguard") }
        }
        if willInstallIPsec { args.append("--ipsec") }
        let (code, out) = await m.cli(args, label: "Setting up \(name)…")
        if code == 0 && out.contains("install finished") {
            phase = .finished
            if m.server == name { m.reload() }
        } else {
            error = lastLines(out, 3)
            phase = .failed
        }
    }
}

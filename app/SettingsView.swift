// Settings (⌘,): appearance, monitoring and notifications, usage limits on every server, and
// Lightsail access for finding new IPs.
import SwiftUI
import AppKit

let lightsailPolicy = """
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "lightsail:GetInstance", "Resource": "*" }
  ]
}
"""

struct SettingsView: View {
    @EnvironmentObject var m: Model
    @State private var tab = "appearance"

    var body: some View {
        TabView(selection: $tab) {
            AppearanceSettings()
                .tabItem { Label { Text("Appearance") } icon: { Lucide.image("palette", size: 18) } }
                .tag("appearance")
            GeneralSettings()
                .tabItem { Label { Text("General") } icon: { Lucide.image("settings", size: 18) } }
                .tag("general")
            LimitsSettings()
                .tabItem { Label { Text("Limits") } icon: { Lucide.image("gauge", size: 18) } }
                .tag("limits")
            PhoneSettings()
                .tabItem { Label { Text("iPhone") } icon: { Lucide.image("smartphone", size: 18) } }
                .tag("iphone")
            LightsailSettings()
                .tabItem { Label { Text("Lightsail") } icon: { Lucide.image("cloud", size: 18) } }
                .tag("lightsail")
        }
        .task {   // test hook: VPNSYNC_SETTINGS_TAB=general|limits|iphone|lightsail, for screenshots
            if let t = ProcessInfo.processInfo.environment["VPNSYNC_SETTINGS_TAB"] { tab = t }
        }
        .frame(width: 560)
        .buttonStyle(ClearGlassButtonStyle())
        .environmentObject(m)
    }
}

struct AppearanceSettings: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Appearance").font(.system(size: 16, weight: .semibold, design: .rounded))
            Text("Automatic follows your Mac's light or dark setting. Buttons use your macOS accent colour.")
                .font(.callout).foregroundStyle(.secondary)
            ThemePicker()
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 240, alignment: .top)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var m: Model
    @State private var geoStatus = ""
    @State private var updating = false
    var body: some View {
        Form {
            Section("Device locations") {
                Text("Flags show which country each device connects from. The lookup uses a local table (ip-location-db, public domain, updated daily upstream), so no address is sent anywhere. VPN Sync fetches a fresh copy automatically every month.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(geoStatus.isEmpty ? (GeoDB.shared.available ? "Table installed" : "Table not downloaded yet") : geoStatus)
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if updating { ProgressView().controlSize(.small) }
                    Button(GeoDB.shared.available ? "Update Table" : "Download Table") {
                        updating = true
                        Task {
                            let (code, out) = await m.runCLI(["geo", "update"], quiet: true)
                            updating = false
                            geoStatus = code == 0 ? "Updated" : lastLines(out, 1).replacingOccurrences(of: "vpn-sync: ", with: "")
                            if code == 0 { GeoDB.shared.load { m.objectWillChange.send() } }
                        }
                    }
                    .disabled(updating)
                }
            }
            Section {
                Toggle("Live monitoring", isOn: Binding(get: { m.monitoring }, set: { m.setMonitoring($0) }))
                Text("Keeps one SSH connection open to each server to show who is connected.")
                    .font(.caption).foregroundStyle(.secondary)
                if m.monitoring {
                    ForEach(m.servers, id: \.self) { name in MonitoredServerRow(name: name) }
                }
                Toggle("Notifications", isOn: Binding(get: { m.notify }, set: { m.setNotify($0) }))
                    .disabled(!m.monitoring)
                Text("A banner when a device connects or disconnects, when a server gets a new IP, or when it can't be reached.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(height: 360)
    }
}

/// Usage-limit alerts, the warning level, and every limit and pause on every server.
struct LimitsSettings: View {
    @EnvironmentObject var m: Model
    @State private var loading: Set<String> = []
    @State private var failed: Set<String> = []
    @State private var editing: LimitTarget?

    var body: some View {
        Form {
            Section("Alerts") {
                Toggle("Usage-limit notifications", isOn: $m.limitAlerts)
                Text("A banner when a device reaches the warning level or its limit, on any server. Separate from the connect and disconnect banners in General.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Show in the menu bar", isOn: $m.menuBarLimits)
                Text("Next to the device count: a pause mark with how many devices are paused, or a gauge when one is at the warning level.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker("Warn at", selection: $m.warnAt) {
                    Text("Off").tag(0)
                    ForEach([50, 70, 80, 90], id: \.self) { Text("\($0)%").tag($0) }
                }
                Text(m.warnAt == 0
                     ? "No early warning: only 100% notifies you. Meters turn red at 100%."
                     : "At \(m.warnAt)% of a limit you get a banner, an Activity entry, and the device's meter turns orange.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(m.servers, id: \.self) { s in serverSection(s) }
            Section("How limits work") {
                Text("Each server counts every device's data every minute, even while this Mac is off. A pausing limit blocks the device's traffic on the server until midnight (daily) or the 1st (monthly); the device stays connected and nothing is revoked. Days follow this Mac's time zone (\(TimeZone.current.identifier)), which is sent to the server when you save a limit.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(height: 520)
        .task { await loadAll() }
        .sheet(item: $editing) { LimitSheet(target: $0).environmentObject(m) }
    }

    private func loadAll() async {
        await withTaskGroup(of: Void.self) { g in
            for s in m.servers {
                loading.insert(s)
                g.addTask { @MainActor in
                    let ok = await m.refreshUsage(s)
                    loading.remove(s)
                    if ok { failed.remove(s) } else { failed.insert(s) }
                }
            }
        }
    }

    /// Devices worth listing: with a limit or a pause, closest to its limit first.
    private func limited(_ u: UsageState) -> [String] {
        func frac(_ n: String) -> Double { u.limits[n]?.tightest(u.usage[n] ?? DeviceUsage())?.fraction ?? 0 }
        return Set(u.limits.keys).union(u.paused.keys).sorted {
            let p0 = u.paused[$0] != nil, p1 = u.paused[$1] != nil
            if p0 != p1 { return p0 }
            if frac($0) != frac($1) { return frac($0) > frac($1) }
            return $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    /// Devices that could get a limit: every device the server reported, plus the selected
    /// server's own device list.
    private func candidates(_ s: String, _ u: UsageState) -> [String] {
        var names = Set(u.usage.keys)
        if s == m.server { names.formUnion(m.allDeviceNames) }
        return names.subtracting(u.limits.keys).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    @ViewBuilder private func serverSection(_ s: String) -> some View {
        Section {
            if let u = m.usageByServer[s] {
                let list = limited(u)
                if list.isEmpty {
                    Text("No limits on \(s).").foregroundStyle(.secondary)
                }
                ForEach(list, id: \.self) { n in row(s, n, u) }
            } else if loading.contains(s) {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking \(s)…").foregroundStyle(.secondary) }
            } else if failed.contains(s) {
                Text("Couldn't read usage from \(s). If it's reachable, run Set Up for it (Servers…) to install usage tracking.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            HStack {
                Text(s)
                Spacer()
                if let u = m.usageByServer[s] {
                    let c = candidates(s, u)
                    Menu("Add a Limit") {
                        ForEach(c, id: \.self) { n in
                            Button(n) { editing = LimitTarget(server: s, device: n) }
                        }
                    }
                    .fixedSize()
                    .disabled(c.isEmpty || m.busy)
                    .help(c.isEmpty ? "Every device on \(s) already has a limit" : "Set a usage limit for a device on \(s)")
                }
            }
        }
    }

    @ViewBuilder private func row(_ s: String, _ n: String, _ u: UsageState) -> some View {
        let used = u.usage[n] ?? DeviceUsage()
        let limit = u.limits[n]
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(n).font(.system(.body, design: .rounded).weight(.semibold))
                    if let p = u.paused[n] { PausedBadge(info: p) }
                }
                Text(limit?.summary ?? "No limit, paused by you")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let (f, text) = limit?.tightest(used) {
                Text(text).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                UsageMeter(fraction: f, width: 54)
            } else {
                Text("\(formatBytes(used.today)) today").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Menu {
                LimitMenuItems(m: m, server: s, name: n, onEdit: { editing = $0 })
            } label: { LucideIcon("ellipsis", size: 13).foregroundStyle(.secondary).frame(width: 18, height: 18) }
                .fullLabelMenu()
                .disabled(m.busy)
                .accessibilityLabel("Limit options for \(n) on \(s)")
        }
        .help("\(formatBytes(used.today)) today, \(formatBytes(used.month)) this month")
    }
}

/// Exports the servers (address, login, pinned host key, private key) for the iPhone app, in a
/// file encrypted with a passphrase shown here once.
struct PhoneSettings: View {
    @EnvironmentObject var m: Model
    @State private var chosen: Set<String> = []
    @State private var problems: [String: String] = [:]
    @State private var passphrase: String?
    @State private var file: URL?
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Text("The VPN Sync iPhone app connects to your servers over SSH itself, so it needs their addresses and keys. Export them to an encrypted file, AirDrop it to the iPhone, open it with VPN Sync and type the passphrase.")
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(m.servers, id: \.self) { s in
                    HStack {
                        Toggle(s, isOn: Binding(get: { chosen.contains(s) }, set: { if $0 { chosen.insert(s) } else { chosen.remove(s) } }))
                            .disabled(problems[s] != nil)
                        Spacer()
                        if let p = problems[s] { Text(p).font(.caption).foregroundStyle(.red) }
                        else if let j = configValue("JUMP", server: s), !j.isEmpty { Text("through \(j)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                HStack {
                    Text("Includes each server's private key. Anyone with the file and the passphrase can log in to these servers.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Export for iPhone…") { export() }
                        .glassButton(prominent: true)
                        .disabled(chosen.isEmpty)
                }
            }
            if let passphrase, let file {
                Section("Passphrase") {
                    HStack {
                        Text(passphrase).font(.system(size: 22, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(passphrase, forType: .string) }
                    }
                    Text("Type it on the iPhone when VPN Sync asks. It isn't saved anywhere; export again for a new one.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(file.lastPathComponent).font(.callout)
                        Spacer()
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                        Button("AirDrop…") { NSSharingService(named: .sendViaAirDrop)?.perform(withItems: [file]) }
                            .glassButton(prominent: true)
                    }
                    Text("Delete the file after importing it.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(height: 460)
        .onAppear { check() }
    }

    /// Which servers can be exported (an Ed25519 OpenSSH key and an Ed25519 pinned host key).
    private func check() {
        problems = [:]
        for s in m.servers {
            do { _ = try exported(s) } catch { problems[s] = error.localizedDescription }
        }
        chosen = Set(m.servers.filter { problems[$0] == nil })
    }

    private struct ExportError: LocalizedError { let errorDescription: String? }

    private func exported(_ s: String) throws -> ExportedServer {
        func v(_ k: String) -> String? { configValue(k, server: s).flatMap { $0.isEmpty ? nil : $0 } }
        guard let host = v("HOST"), let keyPath = v("SSH_KEY") else { throw ExportError(errorDescription: "incomplete settings") }
        let path = keyPath.replacingOccurrences(of: "$HOME", with: NSHomeDirectory())
            .replacingOccurrences(of: "~", with: NSHomeDirectory())
        guard let key = try? String(contentsOfFile: path, encoding: .utf8) else { throw ExportError(errorDescription: "key file not found") }
        do { _ = try OpenSSHKey.ed25519(fromPEM: key) } catch { throw ExportError(errorDescription: error.localizedDescription) }
        let alias = v("HOST_ALIAS") ?? s.lowercased()
        let known = (try? String(contentsOf: configDir.appendingPathComponent("known_hosts"), encoding: .utf8)) ?? ""
        let pin = known.split(separator: "\n").compactMap { line -> String? in
            let f = line.split(separator: " ")
            guard f.count >= 3, f[1] == "ssh-ed25519" else { return nil }
            let names = f[0].split(separator: ",").map { $0.replacingOccurrences(of: "[", with: "").components(separatedBy: "]:")[0] }
            return names.contains(alias) ? "\(f[1]) \(f[2])" : nil
        }.first
        guard let pin else { throw ExportError(errorDescription: "no Ed25519 host key pinned") }
        let last = (try? String(contentsOf: configDir.appendingPathComponent("\(s).last-ip"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ExportedServer(name: s, host: host, user: v("SSH_USER") ?? "ubuntu", port: Int(v("SSH_PORT") ?? "22") ?? 22,
                              jump: v("JUMP"), privateIP: v("PRIVATE_IP"), lastIP: last, hostKey: pin, key: key)
    }

    private func export() {
        error = nil
        do {
            // a jump server travels with the servers that need it
            var names = chosen
            for s in chosen { if let j = configValue("JUMP", server: s), !j.isEmpty { names.insert(j) } }
            let list = try m.servers.filter { names.contains($0) }.map(exported)
            let phrase = ServerBundle.makePassphrase()
            let data = try ServerBundle.seal(list, passphrase: phrase)
            let url = desktopDir.appendingPathComponent("VPN Sync servers.vpnsync")
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            passphrase = phrase; file = url
        } catch {
            self.error = "Not exported: \(error.localizedDescription)"
        }
    }
}

struct LightsailSettings: View {
    @EnvironmentObject var m: Model
    @State private var savedKey: String?
    @State private var keyID = ""
    @State private var secret = ""
    @State private var message: (text: String, ok: Bool)?
    @State private var working = false
    @State private var tests: [String: String] = [:]

    private var lightsailServers: [String] {
        m.servers.filter { !(configValue("LIGHTSAIL_REGION", server: $0) ?? "").isEmpty }
    }

    var body: some View {
        Form {
            Section {
                Text("When a server without a static IP is stopped and started, it comes back with a new IP. With a read-only AWS key, VPN Sync asks Lightsail for the new address, reconnects, and updates the profiles on your Desktop on its own.")
                    .fixedSize(horizontal: false, vertical: true)
                if let savedKey {
                    LabeledContent("Saved key", value: savedKey)
                    HStack {
                        Spacer()
                        Button("Remove Key", role: .destructive) { Task { await removeKey() } }.disabled(working)
                    }
                } else {
                    Text("No key saved yet.").foregroundStyle(.secondary)
                }
            }
            Section(savedKey == nil ? "Add a key" : "Replace the key") {
                TextField("Access key ID", text: $keyID, prompt: Text("AKIA…"))
                SecureField("Secret access key", text: $secret)
                HStack {
                    Text("Stored in your login Keychain, never in a file.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save Key") { Task { await saveKey() } }
                        .glassButton(prominent: true)
                        .disabled(working || keyID.isEmpty || secret.isEmpty)
                }
            }
            if !lightsailServers.isEmpty {
                Section("Check the lookup") {
                    ForEach(lightsailServers, id: \.self) { s in
                        HStack {
                            Text(s)
                            Spacer()
                            if let r = tests[s] { Text(r).font(.callout).foregroundStyle(r.hasPrefix("Current IP") ? .green : .red) }
                            Button("Test") { Task { await test(s) } }.disabled(working || savedKey == nil)
                        }
                    }
                }
            }
            if let message {
                Text(message.text).foregroundStyle(message.ok ? .green : .red)
            }
            Section("How to create a read-only key") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. In the AWS console open IAM → Users → Create user (e.g. vpn-sync), without console access.")
                    Text("2. Permissions: Attach policies directly → Create policy → JSON, paste the policy below, and attach it.")
                    Text("3. Open the user → Security credentials → Create access key → \"Other\", then paste the two values above.")
                    Text("The key can only read instance details, so it can't change or delete anything in your account.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top) {
                    Text(lightsailPolicy).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Button("Copy Policy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(lightsailPolicy, forType: .string)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(height: 560)
        .task { await refresh() }
    }

    private func refresh() async {
        let (_, out) = await m.runCLI(["aws", "status"], quiet: true)
        let k = parseKV(out)["KEY"]
        savedKey = (k == nil || k == "none") ? nil : k
    }

    private func saveKey() async {
        working = true; defer { working = false }
        let id = keyID.trimmingCharacters(in: .whitespaces)
        let sec = secret.trimmingCharacters(in: .whitespaces)
        // The secret goes over stdin only: never in arguments, logs or history.
        let (code, out) = await m.runCLI(["aws", "set"], input: "\(id)\n\(sec)\n", quiet: true)
        secret = ""
        if code == 0 {
            keyID = ""
            message = ("Saved. Use Test to check it can see your servers.", true)
        } else {
            message = (lastLines(out, 1).replacingOccurrences(of: "vpn-sync: ", with: ""), false)
        }
        await refresh()
    }

    private func removeKey() async {
        working = true; defer { working = false }
        _ = await m.runCLI(["aws", "remove"], quiet: true)
        tests = [:]
        message = ("Key removed from the Keychain.", true)
        await refresh()
    }

    private func test(_ s: String) async {
        working = true; defer { working = false }
        let (code, out) = await m.runCLI(["aws", "ip", s], quiet: true)
        if code == 0, let ip = parseKV(out)["IP"] {
            tests[s] = "Current IP \(ip)"
        } else {
            let reason = out.split(separator: "\n").first { $0.hasPrefix("lightsail:") }
                .map { String($0.dropFirst("lightsail: ".count)) } ?? lastLines(out, 1)
            tests[s] = reason.isEmpty ? "Lookup failed" : reason
        }
    }
}

/// One monitored server: connection state, its total speed over the last 15 minutes, online count.
struct MonitoredServerRow: View {
    @EnvironmentObject var m: Model
    @Environment(\.theme) private var t
    let name: String
    var body: some View {
        let w = m.watchers[name]
        let link = w?.link ?? .off
        HStack(spacing: 8) {
            Circle().fill(link == .live ? t.online : (link == .off ? Color.secondary : Color.orange)).frame(width: 7, height: 7)
            Text(name).font(.system(.callout, design: .rounded))
            Spacer()
            if let w, link == .live {
                let cutoff = (w.history.last?.time ?? Date()).addingTimeInterval(-900)
                Sparkline(history: w.history.filter { $0.time >= cutoff }, name: name, width: 80, height: 22)
                Text("\(w.onlineDevices.count) online").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .frame(width: 56, alignment: .trailing)
            } else {
                Text(link == .off ? "not monitored" : link == .connecting ? "connecting…" : "can't reach, retrying")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

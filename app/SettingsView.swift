// Settings (⌘,): monitoring, notifications and Lightsail access for finding new IPs.
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

    var body: some View {
        TabView {
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            LightsailSettings()
                .tabItem { Label("Lightsail", systemImage: "cloud") }
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
    var body: some View {
        Form {
            Section {
                Toggle("Live monitoring", isOn: Binding(get: { m.monitoring }, set: { m.setMonitoring($0) }))
                Text("Keeps one SSH connection open to each server to show who is connected.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Notifications", isOn: Binding(get: { m.notify }, set: { m.setNotify($0) }))
                    .disabled(!m.monitoring)
                Text("A banner when a device connects or disconnects, when a server gets a new IP, or when it can't be reached.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(height: 220)
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

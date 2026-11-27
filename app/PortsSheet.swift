// Change Ports: move OpenVPN (port, TCP or UDP) and WireGuard to other ports with
// `vpn-sync ports set`. On Lightsail it also opens the new port and closes the old one.
import SwiftUI

struct PortsTarget: Identifiable { let server: String; var id: String { server } }

struct ChangePortsSheet: View {
    @EnvironmentObject var m: Model
    @Environment(\.dismiss) private var dismiss
    let server: String

    @State private var ovpnPort = ""
    @State private var ovpnProto = "tcp"
    @State private var wgPort = ""
    @State private var loaded = false
    @State private var working = false
    @State private var error: String?
    @State private var done: [String] = []

    private var ports: [ServerPort] { m.watchers[server]?.ports ?? [] }
    private func current(_ vpn: String) -> ServerPort? { ports.first { $0.vpn == vpn } }
    private var hasOVPN: Bool { current("openvpn") != nil }
    private var hasWG: Bool { current("wireguard") != nil }
    private var lightsail: Bool { m.isLightsail(server) }

    private var ovpnChanged: Bool {
        guard let c = current("openvpn") else { return false }
        return String(c.port) != ovpnPort || c.proto != ovpnProto
    }
    private var wgChanged: Bool {
        guard let c = current("wireguard") else { return false }
        return String(c.port) != wgPort
    }

    private func valid(_ s: String) -> Int? { Int(s).flatMap { (1...65535).contains($0) ? $0 : nil } }

    /// Why the ports as typed can't be used, or nil.
    private var problem: String? {
        if hasOVPN && valid(ovpnPort) == nil { return String(localized: "OpenVPN port must be 1–65535.") }
        if hasWG && valid(wgPort) == nil { return String(localized: "WireGuard port must be 1–65535.") }
        let ssh = Set(ports.filter { $0.vpn == "ssh" }.map(\.port))
        let ike = ports.contains { $0.vpn == "ipsec" }
        if hasOVPN, let p = valid(ovpnPort) {
            if ovpnProto == "tcp" && ssh.contains(p) { return String(localized: "TCP \(String(p)) is SSH's port.") }
            if ovpnProto == "udp" && ike && (p == 500 || p == 4500) { return String(localized: "UDP \(String(p)) is used by IKEv2.") }
        }
        if hasWG, let p = valid(wgPort) {
            if ike && (p == 500 || p == 4500) { return String(localized: "UDP \(String(p)) is used by IKEv2.") }
            if hasOVPN && ovpnProto == "udp" && valid(ovpnPort) == p { return String(localized: "OpenVPN and WireGuard can't both use UDP \(String(p)).") }
        }
        return nil
    }

    /// Devices with a profile for a VPN whose port changes: they lose the connection until updated.
    private var affected: [String] {
        m.devices.filter { (ovpnChanged && $0.ovpn != nil) || (wgChanged && $0.wg != nil) }.map(\.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Change Ports").font(.system(size: 22, weight: .bold, design: .rounded))
            Text("Moves a VPN on \(server) to another port: its settings, its firewall rule on the server and every device's profile.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if ports.isEmpty {
                Text(m.monitoring ? String(localized: "Waiting for \(server) to report its ports…") : String(localized: "Turn on Live to read \(server)'s ports first."))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if let c = current("openvpn") {
                        FormRow(label: "OpenVPN", hint: "Now \(c.proto.uppercased()) \(String(c.port)).") {
                            HStack {
                                TextField("Port", text: $ovpnPort).textFieldStyle(.roundedBorder).frame(width: 90)
                                Picker("", selection: $ovpnProto) {
                                    Text("TCP").tag("tcp"); Text("UDP").tag("udp")
                                }
                                .pickerStyle(.segmented).labelsHidden().frame(width: 120)
                            }
                        }
                    }
                    if let c = current("wireguard") {
                        FormRow(label: "WireGuard", hint: "Now UDP \(String(c.port)). WireGuard always uses UDP.") {
                            TextField("Port", text: $wgPort).textFieldStyle(.roundedBorder).frame(width: 90)
                        }
                    }
                    if let ike = ports.text("ipsec") {
                        FormRow(label: "IKEv2") { Text(String(localized: "\(ike), fixed by the protocol")).foregroundStyle(.secondary) }
                    }
                }
                .disabled(working)

                if let problem { Text(problem).font(.callout).foregroundStyle(.red) }

                VStack(alignment: .leading, spacing: 6) {
                    if ovpnChanged || wgChanged {
                        let n = affected.count
                        let names = affected.prefix(5).joined(separator: listSep) + (n > 5 ? "…" : "")
                        Label(n == 0 ? String(localized: "Devices on this VPN disconnect until they get their new profile.")
                              : n == 1 ? String(localized: "1 device (\(names)) disconnects until it gets its new profile: VPN Sync updates the Desktop folder and OpenVPN Connect; phones and TVs need the new QR code or file.")
                              : String(localized: "\(n) devices (\(names)) disconnect until they get their new profile: VPN Sync updates the Desktop folder and OpenVPN Connect; phones and TVs need the new QR code or file."),
                              lucide: "circle-alert", size: 13)
                    }
                    if (ovpnChanged && current("openvpn")?.port == 443) || (wgChanged && current("wireguard")?.port == 443) {
                        Label(String(localized: "Port 443 looks like ordinary web traffic, so it's the hardest for a national firewall to block. Moving away from it can make the VPN easier to block."),
                              lucide: "shield-off", size: 13)
                    }
                    Label(lightsail ? String(localized: "VPN Sync opens the new port in the Lightsail firewall first and closes the old one afterwards. The Lightsail key needs the port permissions (Settings → Lightsail shows the policy).")
                                    : String(localized: "Allow the new port in your provider's firewall before you change it."),
                          lucide: "shield", size: 13)
                }
                .font(.callout).foregroundStyle(.secondary)
                .labelStyle(TightLabel())
                .fixedSize(horizontal: false, vertical: true)
            }

            if working || !m.opLog.isEmpty && (error != nil || !done.isEmpty) { OutputView(text: m.opLog, height: 170) }
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            if !done.isEmpty && error == nil {
                Text(done.joined(separator: " ")).font(.callout).foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if working { ProgressView().controlSize(.small); Text("Changing… about a minute").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(done.isEmpty ? "Cancel" : "Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                if done.isEmpty {
                    Button("Change Ports", action: apply)
                        .keyboardShortcut(.defaultAction)
                        .glassButton(prominent: true)
                        .disabled(working || ports.isEmpty || problem != nil || !(ovpnChanged || wgChanged))
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .glassSheet()
        .onAppear(perform: load)
        .onChange(of: ports) { if !loaded { load() } }
    }

    private func load() {
        guard !ports.isEmpty, !loaded else { return }
        if let c = current("openvpn") { ovpnPort = String(c.port); ovpnProto = c.proto }
        if let c = current("wireguard") { wgPort = String(c.port) }
        loaded = true
    }

    private func apply() {
        guard problem == nil, !working else { return }
        working = true; error = nil
        var steps: [[String]] = []
        if ovpnChanged { steps.append(["ports", "set", server, "openvpn", ovpnPort, ovpnProto]) }
        if wgChanged { steps.append(["ports", "set", server, "wireguard", wgPort]) }
        Task {
            var log = ""
            for args in steps {
                let (code, out) = await m.cli(args, label: String(localized: "Changing \(args[3] == "openvpn" ? "OpenVPN" : "WireGuard")'s port on \(server)…"))
                log += out
                if code != 0 {
                    let why = out.split(separator: "\n").last { $0.hasPrefix("vpn-sync: ") }
                        .map { String($0.dropFirst("vpn-sync: ".count)) } ?? lastLines(out, 1)
                    error = why.contains("lightsail:") || why.contains("Lightsail")
                        ? String(localized: "\(why) Settings → Lightsail shows the policy the key needs.")
                        : why
                    break
                }
                let kv = parseKV(out)
                if let c = kv["CHANGED"]?.split(separator: " "), c.count == 3 {
                    done.append(String(localized: "\(c[0] == "openvpn" ? "OpenVPN" : "WireGuard") now uses \(c[1].uppercased()) \(c[2])."))
                }
            }
            m.opLog = log
            working = false
            m.restartWatcher(server)
            if m.server == server { await m.check() }
            if !done.isEmpty { m.notices = done + [String(localized: "Give each device its new profile from the Desktop folder or QR code.")] }
        }
    }
}

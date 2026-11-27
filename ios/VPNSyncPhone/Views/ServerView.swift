// One server: services (start/stop/restart, reboot), then Devices, Traffic or Activity.
import SwiftUI

struct ServerView: View {
    @EnvironmentObject var store: Store
    let name: String
    @ObservedObject var live: ServerLive

    enum Tab: String, CaseIterable { case devices = "Devices", traffic = "Traffic", activity = "Activity" }
    @State private var tab: Tab = .devices
    @State private var selected: DeviceInfo?
    @State private var adding = false
    @State private var confirm: ServiceAction?
    @State private var busy: String?
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var removing: [String]?
    @State private var powerHelp = false
    @State private var confirmUpdate = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                stoppedBanner
                servicesRow
                checkCard
                portsCard
                Picker("Section", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { t in
                        Text(t == .activity && activityCount > 0 ? "Activity (\(activityCount))" : t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                switch tab {
                case .devices:
                    DevicesList(live: live, selected: $selected, selecting: selecting, selection: $selection,
                                onPause: { n, p in pause(n, p) }, onRemove: { removing = $0 })
                case .traffic: TrafficSection(live: live)
                case .activity: ActivitySection(live: live)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .background(Backdrop())
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if selecting {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { selecting = false; selection = [] }
                }
            } else {
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add Devices")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Add Devices…", systemImage: "plus") { adding = true }
                    Button("Select Devices to Remove…", systemImage: "checkmark.circle") { tab = .devices; selecting = true }
                    Divider()
                    Button("Refresh", systemImage: "arrow.clockwise") { live.restart() }
                    Button("Check Profiles", systemImage: "checklist") { runCheck() }
                        .disabled(live.checking)
                    Divider()
                    Button("Restart All VPNs…", systemImage: "arrow.triangle.2.circlepath") { confirm = ServiceAction(server: name, vpn: "all", action: "restart") }
                    Button("Reboot Server…", systemImage: "power", role: .destructive) { confirm = ServiceAction(server: name, vpn: "reboot", action: "reboot") }
                    Divider()
                    if store.canPower(name) {
                        let st = store.instances[name]
                        Button("Stop Server…", systemImage: "stop.circle", role: .destructive) { confirm = ServiceAction(server: name, vpn: "instance", action: "stop") }
                            .disabled(st?.isDown == true || st?.state == "pending")
                        Button("Start Server", systemImage: "play.circle") { run(ServiceAction(server: name, vpn: "instance", action: "start")) }
                            .disabled(st?.isRunning == true || st?.state == "pending" || st?.state == "stopping")
                    } else {
                        // not set up yet: say what's missing instead of hiding the actions
                        Button("Stop Server…", systemImage: "stop.circle") { powerHelp = true }
                        Button("Start Server", systemImage: "play.circle") { powerHelp = true }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Server actions")
            }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selecting {
                HStack {
                    Button(selection.count == live.allDevices.count ? "Select None" : "Select All") {
                        selection = selection.count == live.allDevices.count ? [] : Set(live.allDevices.map(\.name))
                    }
                    Spacer()
                    Button(role: .destructive) { removing = live.allDevices.map(\.name).filter { selection.contains($0) } } label: {
                        Label("Remove \(selection.count)…", systemImage: "trash")
                    }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .disabled(selection.isEmpty)
                }
                .card(22, padding: 12).padding(.horizontal, 16).padding(.bottom, 4)
            }
        }
        .confirmationDialog(removeTitle, isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            if let r = removing {
                Button(r.count == 1 ? "Remove \(r[0])" : "Remove \(r.count) Devices", role: .destructive) { remove(r) }
            }
        } message: {
            Text("Their OpenVPN certificates are revoked, WireGuard peers removed\(live.hasIPsec ? " and IKEv2 certificates revoked" : ""). Their profiles stop working. This can't be undone.")
        }
        .refreshable { live.restart() }
        .sheet(item: $selected) { d in DeviceSheet(server: name, device: d, live: live) }
        .sheet(isPresented: $adding) { AddDeviceSheet(server: name, live: live) }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            if let a = confirm {
                Button(a.vpn == "instance" ? "Stop Server" : a.action == "reboot" ? "Reboot" : a.action.capitalized, role: a.action == "start" ? nil : .destructive) { run(a) }
            }
        } message: {
            Text(confirm?.vpn == "instance"
                 ? "The Lightsail instance shuts down: every device is disconnected until you start it again." + (store.instances[name]?.staticIP == true ? "" : " Without a static IP it gets a new address when it starts; phones and TVs then need their WireGuard and IKEv2 profiles again.")
                 : confirm?.action == "reboot" ? "Every device is disconnected for about a minute." : "Devices on it reconnect on their own.")
        }
        .overlay(alignment: .bottom) { if let busy { ProgressView(busy).padding().card(16, padding: 4).padding() } }
        .alert("Stopping and starting needs the Lightsail key", isPresented: $powerHelp) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(powerHelpText)
        }
        .onAppear { openRequestedTab() }
        // like the Mac at launch: check once when the server is first opened
        .task { if live.lastCheck == nil && !live.checking && live.checkError == nil { runCheck(quiet: true) } }
        .confirmationDialog("Update \(name)'s profiles?", isPresented: $confirmUpdate, titleVisibility: .visible) {
            Button("Update Profiles") { updateProfiles() }
        } message: {
            Text("The server rewrites its profiles for \(live.lastCheck?.ip ?? "its current IP")\(live.hasIPsec ? " and restarts IPsec with a new certificate" : ""). Every device then needs its new profile: open it here and share it, or scan its QR code.")
        }
        .task { await store.refreshInstance(name) }
    }

    private var activityCount: Int { live.events.count + live.usageEvents.count }

    private var header: some View {
        let s = store.server(name)
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(s?.address ?? "").font(.system(.body, design: .monospaced))
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(live.onlineNames.count)").font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("online").font(.caption).foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private var statusText: String {
        switch live.link {
        case .off: return "Not connected"
        case .connecting: return "Connecting…"
        case .live: return live.lastSnapshot.map { "Updated \($0.formatted(date: .omitted, time: .standard))" } ?? "Live"
        case .retrying(let why): return "\(why) Retrying…"
        }
    }

    private var servicesRow: some View {
        HStack(spacing: 8) {
            Group {
                ForEach([("openvpn", "OpenVPN"), ("wireguard", "WireGuard"), ("ipsec", "IPsec")], id: \.0) { key, label in
                    if let s = live.services[key], s.state != "missing" {
                        Menu {
                            if s.state == "active" {
                                Button("Restart \(label)…") { confirm = ServiceAction(server: name, vpn: key, action: "restart") }
                                Button("Stop \(label)…", role: .destructive) { confirm = ServiceAction(server: name, vpn: key, action: "stop") }
                            } else {
                                Button("Start \(label)") { run(ServiceAction(server: name, vpn: key, action: "start")) }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                StatusDot(color: s.state == "active" ? Palette.online : s.state == "failed" ? .red : .secondary, on: s.state == "active")
                                Text(label).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                if s.state != "active" {
                                    Text(s.state == "inactive" ? "stopped" : s.state).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            .pill(s.state == "failed" ? .red : nil)
                        }
                        .tint(.primary)
                        .accessibilityLabel("\(label), \(s.state == "active" ? "running" : s.state)")
                    }
                }
            }
        }
    }

    /// The result of Check Profiles: up to date, or what changed since the last check.
    @ViewBuilder private var checkCard: some View {
        if live.checking && live.lastCheck == nil {
            HStack(spacing: 10) { ProgressView(); Text("Checking profiles…").foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity, alignment: .leading).card(18, padding: 14)
        } else if let e = live.checkError {
            VStack(alignment: .leading, spacing: 4) {
                Label("Couldn't check the profiles", systemImage: "exclamationmark.triangle").font(.subheadline.weight(.semibold))
                Text(e).font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).card(18, padding: 14)
        } else if let c = live.lastCheck {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(c.changed ? (c.staleFiles > 0 ? "Profiles need updating" : "Changed since your last check") : "Profiles up to date",
                          systemImage: c.changed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(c.changed ? .orange : Palette.online)
                    Spacer()
                    if live.checking { ProgressView().controlSize(.small) }
                    else {
                        Button { runCheck() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).accessibilityLabel("Check again")
                    }
                }
                if c.staleFiles > 0 {
                    Text("\(c.staleFiles) profile file\(c.staleFiles == 1 ? "" : "s") on the server still use an old address; the server is now \(c.ip ?? "on a new IP").")
                        .font(.footnote)
                    Button("Update Profiles…", systemImage: "arrow.triangle.2.circlepath") { confirmUpdate = true }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
                if !c.added.isEmpty { line("Added", c.added.joined(separator: ", ")) }
                if !c.removed.isEmpty { line("Removed", c.removed.joined(separator: ", ")) }
                if !c.updated.isEmpty {
                    line("New profiles", c.updated.map { "\($0.name) (\($0.vpns.joined(separator: ", ")))" }.joined(separator: ", "))
                    Text("Those devices need their new profile: open the device and share it, or scan its QR code.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !c.changed {
                    Text(c.firstCheck ? "Every profile uses \(c.ip ?? "the server's address"). From the next check on, devices added, removed or given new profiles are listed here."
                                      : "Every profile uses \(c.ip ?? "the server's address"); no device was added, removed or given a new profile since your last check.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text("Checked \(c.time.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(18, padding: 14)
        }
    }

    private func line(_ title: String, _ value: String) -> some View {
        (Text("\(title): ").fontWeight(.semibold) + Text(value)).font(.footnote)
    }

    private func runCheck(quiet: Bool = false) {
        Task {
            do { try await live.check() }
            catch {
                let msg = error.localizedDescription
                live.checkError = msg.contains("--hashes") || msg.contains("usage: vpn-export-profiles")
                    ? "\(name)'s server tools are older than this app. On the Mac, open Set Up… for \(name) to update them."
                    : msg
            }
        }
    }

    private func updateProfiles() {
        busy = "Updating profiles…"
        Task {
            defer { busy = nil }
            do {
                let out = try await live.updateProfiles()
                store.show(out.isEmpty ? "Profiles updated." : out)
            } catch { store.show(error.localizedDescription) }
        }
    }

    /// What the server listens on: the ports its cloud firewall has to allow.
    @ViewBuilder private var portsCard: some View {
        let vpns = ["openvpn", "wireguard", "ipsec", "ssh"].filter { live.ports.text($0) != nil }
        if !vpns.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Ports", systemImage: "network").font(.subheadline.weight(.semibold))
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                          alignment: .leading, spacing: 6) {
                    ForEach(vpns, id: \.self) { v in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(portLabel(v)).font(.caption).foregroundStyle(.secondary)
                            Text(live.ports.text(v) ?? "").font(.subheadline.weight(.medium)).monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(18, padding: 14)
            .contextMenu {
                Button("Copy Ports", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = vpns.map { "\(portLabel($0)): \(live.ports.text($0) ?? "")" }.joined(separator: "\n")
                }
            }
        }
    }

    private var powerHelpText: String {
        let s = store.server(name)
        if store.demo { return "Not available with the made-up demo servers." }
        let steps = "On the Mac, open VPN Sync → Settings → iPhone, tick Include the Lightsail key, click Export for iPhone…, AirDrop the file to this iPhone and open it with VPN Sync."
        if s?.region == nil && store.awsKey == nil {
            return "This iPhone doesn't know \(name)'s Lightsail details or have the Lightsail key yet. \(steps)"
        }
        if s?.region == nil {
            return "This iPhone doesn't know \(name)'s Lightsail details yet (it was imported before they were included). \(steps)"
        }
        return "This iPhone doesn't have the Lightsail key yet. \(steps)"
    }

    private var removeTitle: String {
        guard let r = removing else { return "" }
        return r.count == 1 ? "Remove \(r[0])?" : "Remove \(r.count) devices: \(r.prefix(6).joined(separator: ", "))\(r.count > 6 ? "…" : "")?"
    }

    private func remove(_ names: [String]) {
        removing = nil
        busy = names.count == 1 ? "Removing \(names[0])…" : "Removing \(names.count) devices…"
        Task {
            defer { busy = nil }
            do {
                _ = try await store.tool(name, "/usr/local/sbin/vpn-remove-client \(names.joined(separator: " "))", timeout: 120 + 40 * names.count)
                store.show(names.count == 1 ? "Removed \(names[0])." : "Removed \(names.count) devices.")
                selecting = false; selection = []
            } catch { store.show(error.localizedDescription) }
            await live.refreshDevices()
            await live.refreshUsage()
        }
    }

    private func pause(_ device: String, _ on: Bool) {
        Task {
            do {
                _ = try await store.tool(name, "/usr/local/sbin/vpn-usage \(on ? "pause" : "resume") \(device)")
                await live.refreshUsage()
                store.show(on ? "\(device) is paused: connected, but no internet." : "\(device) is back online.")
            } catch { store.show(error.localizedDescription) }
        }
    }

    private var confirmTitle: String {
        guard let a = confirm else { return "" }
        if a.action == "reboot" { return "Reboot \(name)?" }
        if a.vpn == "instance" { return "Stop the server \(name)?" }
        return "\(a.action.capitalized) \(a.vpnLabel) on \(name)?"
    }

    /// "Tokyo is stopped" with a Start button, when Lightsail says so.
    @ViewBuilder private var stoppedBanner: some View {
        if let st = store.instances[name], !st.isRunning {
            HStack(spacing: 12) {
                Image(systemName: st.state == "pending" ? "arrow.clockwise.circle" : "power.circle").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(name) is \(st.label)").font(.subheadline.weight(.semibold))
                    Text(st.state == "pending" ? "It's booting; this reconnects when it's ready." : "No device can connect while it's stopped.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if st.state == "stopped", store.canPower(name) {
                    Button("Start") { run(ServiceAction(server: name, vpn: "instance", action: "start")) }
                        .buttonStyle(.borderedProminent).disabled(busy != nil)
                } else if st.state != "stopped" {
                    ProgressView()
                }
            }
            .card()
        }
    }

    private func run(_ a: ServiceAction) {
        if a.vpn == "instance" {
            confirm = nil
            busy = a.action == "start" ? "Starting \(name)… this takes a minute or two." : "Stopping \(name)…"
            Task {
                defer { busy = nil }
                do {
                    try await store.power(name, start: a.action == "start")
                    store.show(a.action == "start" ? "\(name) is running again." : "\(name) is stopping.")
                } catch { store.show(error.localizedDescription) }
            }
            return
        }
        confirm = nil
        busy = a.action == "reboot" ? "Rebooting…" : "\(a.action.capitalized)ing \(a.vpnLabel)…"
        Task {
            defer { busy = nil }
            do {
                if a.action == "reboot" {
                    _ = try await store.tool(name, "/usr/local/sbin/vpn-service reboot", timeout: 30)
                    store.show("\(name) is rebooting. It's usually back within a minute.")
                } else {
                    _ = try await store.tool(name, "/usr/local/sbin/vpn-service \(a.vpn) \(a.action)", timeout: 90)
                    store.show("\(a.vpnLabel): \(a.action == "stop" ? "stopped" : a.action == "start" ? "started" : "restarted").")
                }
            } catch { store.show(error.localizedDescription) }
        }
    }

    /// Test hook (DEBUG): -tab traffic|activity, -device NAME.
    private func openRequestedTab() {
        #if DEBUG
        if let t = UserDefaults.standard.string(forKey: "tab"), let v = Tab(rawValue: t.capitalized) { tab = v }
        if let d = UserDefaults.standard.string(forKey: "device"), selected == nil {
            Task { try? await Task.sleep(nanoseconds: 2_500_000_000); selected = live.allDevices.first { $0.name == d } }
        }
        #endif
    }
}

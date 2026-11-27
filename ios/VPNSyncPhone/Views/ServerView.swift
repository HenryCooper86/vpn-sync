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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                stoppedBanner
                servicesRow
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
                    Divider()
                    Button("Restart All VPNs…", systemImage: "arrow.triangle.2.circlepath") { confirm = ServiceAction(server: name, vpn: "all", action: "restart") }
                    Button("Reboot Server…", systemImage: "power", role: .destructive) { confirm = ServiceAction(server: name, vpn: "reboot", action: "reboot") }
                    if store.canPower(name) {
                        let st = store.instances[name]
                        Divider()
                        Button("Stop Server…", systemImage: "stop.circle", role: .destructive) { confirm = ServiceAction(server: name, vpn: "instance", action: "stop") }
                            .disabled(st?.isDown == true || st?.state == "pending")
                        Button("Start Server", systemImage: "play.circle") { run(ServiceAction(server: name, vpn: "instance", action: "start")) }
                            .disabled(st?.isRunning == true || st?.state == "pending" || st?.state == "stopping")
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
        .onAppear { openRequestedTab() }
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

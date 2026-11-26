// Menu bar item: a shield with the number of devices online across all servers, and a
// panel listing who is connected on each server.
import SwiftUI
import AppKit

struct MenuBarLabel: View {
    @ObservedObject var m: Model
    var body: some View {
        let n = m.onlineEverywhere
        HStack(spacing: 3) {
            Image(systemName: icon)
            if m.monitoring { Text("\(n)").monospacedDigit() }
        }
        .help("VPN Sync: \(n) device\(n == 1 ? "" : "s") online")
        .onAppear { debugNote("menubar label appeared icon=\(icon) count=\(n)") }
        .onChange(of: n) { debugNote("menubar count=\(n) icon=\(icon)") }
    }

    /// Test hook (VPNSYNC_DEBUG_DIR): records what the menu bar item shows.
    private func debugNote(_ s: String) {
        guard let dir = ProcessInfo.processInfo.environment["VPNSYNC_DEBUG_DIR"] else { return }
        let url = URL(fileURLWithPath: dir + "/menubar.txt")
        let line = Data("\(Int(Date().timeIntervalSince1970)) \(s)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { try? line.write(to: url) }
    }
    private var icon: String {
        if !m.monitoring { return "shield.slash" }
        let anyLive = m.watchers.values.contains { $0.link == .live }
        if !anyLive { return "shield" }
        return m.onlineEverywhere > 0 ? "shield.lefthalf.filled" : "shield"
    }
}

/// Brings the main window forward, opening it if it was closed.
@MainActor
func showMainWindow(_ openWindow: OpenWindowAction) {
    NSApp.activate(ignoringOtherApps: true)
    if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.canBecomeMain }) {
        w.makeKeyAndOrderFront(nil)
    } else {
        openWindow(id: "main")
    }
}

struct MenuBarPanel: View {
    @ObservedObject var m: Model
    @Environment(\.openWindow) private var openWindow
    /// Server waiting for removal confirmation (inline: alerts tend to close menu bar panels).
    @State private var confirmRemove: String?
    @State private var removeError: (server: String, message: String)?
    @State private var removing = false
    @State private var renaming: String?
    @State private var newName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("VPN Sync").font(.system(size: 16, weight: .bold, design: .rounded))
                Spacer()
                if m.monitoring {
                    Text("\(m.onlineEverywhere) online").font(.system(.callout, design: .rounded)).foregroundStyle(.secondary)
                }
            }
            if m.servers.isEmpty {
                Text("No servers yet.").foregroundStyle(.secondary)
            } else {
                if !m.monitoring {
                    HStack {
                        Text("Live monitoring is off.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Turn On") { m.setMonitoring(true) }
                    }
                }
                ForEach(m.servers, id: \.self) { s in serverSection(s) }
            }
            Divider()
            Toggle("Notifications", isOn: Binding(get: { m.notify }, set: { m.setNotify($0) }))
                .disabled(!m.monitoring)
            HStack {
                Button("Open VPN Sync") { showMainWindow(openWindow) }.glassButton(prominent: true)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.glassButton()
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    @ViewBuilder private func serverSection(_ s: String) -> some View {
        let w = m.watchers[s]
        let online = w?.onlineDevices ?? []
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(linkColor(w?.link ?? .off)).frame(width: 7, height: 7)
                Button {
                    m.selectServer(s)
                    showMainWindow(openWindow)
                } label: { Text(s).font(.system(.callout, design: .rounded).weight(.semibold)) }
                    .buttonStyle(.plain)
                    .help("Open \(s) in VPN Sync")
                Spacer()
                if m.monitoring {
                    Text(linkText(w, count: online.count)).font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    removeError = nil; confirmRemove = nil
                    if renaming == s { renaming = nil } else { renaming = s; newName = s; nameFocused = true }
                } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .disabled(removing)
                    .help("Rename \(s)")
                Button {
                    removeError = nil; renaming = nil
                    confirmRemove = (confirmRemove == s ? nil : s)
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .disabled(removing)
                    .help("Remove \(s) from VPN Sync")
            }
            if renaming == s {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        TextField("New name", text: $newName)
                            .textFieldStyle(.roundedBorder)
                            .focused($nameFocused)
                            .onSubmit { rename(s) }
                            .disabled(removing)
                        Button("Cancel") { renaming = nil }.disabled(removing)
                        Button("Rename") { rename(s) }
                            .buttonStyle(.borderedProminent)
                            .disabled(removing || renameProblem(s) != nil || newName == s)
                    }
                    if let p = renameProblem(s), !newName.isEmpty {
                        Text(p).font(.caption).foregroundStyle(.red)
                    } else {
                        Text("Its Desktop folder is renamed too. Devices and the server itself aren't affected.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            }
            if confirmRemove == s {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Remove \(s) from VPN Sync?").font(.callout.weight(.semibold))
                    Text("Deletes its settings, the copy of its key and its pinned host key on this Mac. The server keeps running, its devices keep working, and its Desktop folder is kept.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if removing { ProgressView().controlSize(.small) }
                        Spacer()
                        Button("Cancel") { confirmRemove = nil }.disabled(removing)
                        Button("Remove", role: .destructive) { remove(s) }
                            .buttonStyle(.borderedProminent).tint(.red).disabled(removing)
                    }
                }
                .padding(8)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            if let e = removeError, e.server == s {
                Text(e.message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if m.monitoring && w?.link == .live {
                if online.isEmpty {
                    Text("No devices online").font(.caption).foregroundStyle(.secondary).padding(.leading, 13)
                } else {
                    ForEach(online, id: \.name) { d in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            LiveDot(online: true).scaleEffect(0.7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(d.name).font(.callout)
                                Text(d.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(.leading, 6)
                    }
                }
            }
        }
        .padding(10)
        .glassPanel(16)
    }

    private func renameProblem(_ s: String) -> String? {
        if newName.isEmpty { return "Enter a name." }
        if !isValidServerName(newName) { return "Use letters, numbers, - and _ (no spaces), up to 40." }
        if newName != s && m.servers.contains(newName) { return "“\(newName)” already exists." }
        return nil
    }

    private func rename(_ s: String) {
        guard renameProblem(s) == nil, newName != s, !removing else { return }
        removing = true
        let to = newName
        Task {
            let (code, out) = await m.cli(["server", "rename", s, to], label: "Renaming \(s)…")
            removing = false
            renaming = nil
            if code == 0 {
                m.reloadServers(select: m.server == s ? to : nil)
            } else {
                let msg = out.split(separator: "\n").last.map { String($0).replacingOccurrences(of: "vpn-sync: ", with: "") }
                removeError = (s, "Not renamed: \(msg ?? "unknown error").")
            }
        }
    }

    private func remove(_ s: String) {
        removing = true
        Task {
            let (code, out) = await m.cli(["server", "remove", s], label: "Removing \(s)…")
            removing = false
            if code == 0 {
                confirmRemove = nil
                let wasSelected = m.server == s
                m.reloadServers()
                if wasSelected && !m.server.isEmpty { await m.check() }
            } else {
                confirmRemove = nil
                // e.g. "edge-2 connects through edge-1; change that first"
                let msg = out.split(separator: "\n").last.map { String($0).replacingOccurrences(of: "vpn-sync: ", with: "") }
                removeError = (s, "Not removed: \(msg ?? "unknown error").")
            }
        }
    }

    private func linkColor(_ l: LiveLink) -> Color {
        switch l {
        case .live: return .green
        case .connecting, .retrying: return .orange
        case .off: return .secondary
        }
    }
    private func linkText(_ w: ServerWatcher?, count: Int) -> String {
        switch w?.link ?? .off {
        case .live: return "\(count) online"
        case .connecting: return "connecting…"
        case .retrying: return "can't reach, retrying…"
        case .off: return "not monitored"
        }
    }
}

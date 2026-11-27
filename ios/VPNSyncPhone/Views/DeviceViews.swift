// Devices: the list, a device's sheet (usage, limit, pause, profiles, remove), the limit
// editor, adding a device, and the WireGuard QR code.
import SwiftUI
import CoreImage.CIFilterBuiltins

struct DevicesList: View {
    @ObservedObject var live: ServerLive
    @Binding var selected: DeviceInfo?
    /// Select mode (for removing several): tapping a row ticks it instead of opening it.
    var selecting = false
    @Binding var selection: Set<String>
    var onPause: (String, Bool) -> Void = { _, _ in }
    var onRemove: ([String]) -> Void = { _ in }

    var body: some View {
        let list = live.allDevices
        if list.isEmpty {
            Text(live.link == .live ? String(localized: "No devices on this server yet.") : String(localized: "Loading devices…"))
                .foregroundStyle(.secondary).card()
        } else {
            VStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, d in
                    Button {
                        if selecting {
                            if selection.contains(d.name) { selection.remove(d.name) } else { selection.insert(d.name) }
                        } else { selected = d }
                    } label: {
                        HStack(spacing: 0) {
                            if selecting {
                                Image(systemName: selection.contains(d.name) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3).foregroundStyle(selection.contains(d.name) ? Color.accentColor : .secondary)
                                    .padding(.leading, 8)
                                    .accessibilityLabel(selection.contains(d.name) ? String(localized: "Selected") : String(localized: "Not selected"))
                            }
                            DeviceRow(device: d, live: live, showChevron: !selecting)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if !selecting {
                            Button("Open", systemImage: "info.circle") { selected = d }
                            if live.usage?.paused[d.name] != nil {
                                Button("Resume Internet", systemImage: "play") { onPause(d.name, false) }
                            } else {
                                Button("Pause Internet", systemImage: "pause") { onPause(d.name, true) }
                            }
                            Divider()
                            Button("Remove \(d.name)…", systemImage: "trash", role: .destructive) { onRemove([d.name]) }
                        }
                    }
                    if i < list.count - 1 { Divider().padding(.leading, 56) }
                }
            }
            .card(22, padding: 8)
        }
    }
}

struct DeviceRow: View {
    let device: DeviceInfo
    @ObservedObject var live: ServerLive
    var showChevron = true

    var body: some View {
        let n = device.name, online = live.isOnline(n)
        HStack(spacing: 12) {
            DeviceAvatar(kind: live.kind(n), online: online)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(n).font(.body.weight(.semibold))
                    if let p = live.usage?.paused[n] { PausedBadge(info: p) }
                }
                Text(live.via(n) ?? live.lastSeen(n).map { String(localized: "Last seen \(relative($0))") } ?? String(localized: "Not connected"))
                    .font(.caption).foregroundStyle(online ? .primary : .secondary).lineLimit(1).minimumScaleFactor(0.8)
                usageLine(n)
            }
            Spacer(minLength: 6)
            if online, let r = live.rates[n] {
                VStack(alignment: .trailing, spacing: 1) {
                    Label(formatRate(r.down), systemImage: "arrow.down").foregroundStyle(.primary)
                    Label(formatRate(r.up), systemImage: "arrow.up").foregroundStyle(.secondary)
                }
                .font(.caption2.weight(.medium)).monospacedDigit().labelStyle(.titleAndIcon)
            }
            if showChevron { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
        }
        .padding(.vertical, 8).padding(.horizontal, 8)
        .contentShape(Rectangle())
    }

    @ViewBuilder private func usageLine(_ n: String) -> some View {
        let u = live.usage?.usage[n], l = live.usage?.limits[n]
        if u != nil || l != nil {
            HStack(spacing: 6) {
                Text("\(formatBytes(u?.today ?? 0)) today, \(formatBytes(u?.month ?? 0)) this month")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                if let l, let t = l.tightest(u ?? DeviceUsage()) { UsageMeter(fraction: t.fraction, width: 40) }
            }
        }
    }
}

// MARK: - Device sheet

struct DeviceSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let server: String
    let device: DeviceInfo
    @ObservedObject var live: ServerLive

    @State private var files: [ProfileFile] = []
    @State private var loadingFiles = false
    @State private var filesError: String?
    @State private var editingLimit = false
    @State private var confirmRemove = false
    @State private var qr: String?
    @State private var busy = false

    var body: some View {
        let n = device.name
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        DeviceAvatar(kind: live.kind(n), online: live.isOnline(n), size: 52)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(live.via(n) ?? String(localized: "Not connected")).font(.subheadline)
                            if let info = live.devInfo[n] { Text("\(clientPlatformName(info.platform)), \(info.app)").font(.caption).foregroundStyle(.secondary) }
                            if live.isOnline(n), let r = live.rates[n] {
                                Text("↓ \(formatRate(r.down))   ↑ \(formatRate(r.up))").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                connectionSection(n)
                usageSection(n)
                profilesSection
                Section {
                    Button("Remove Device…", role: .destructive) { confirmRemove = true }
                } footer: {
                    Text("Revokes its OpenVPN certificate, removes its WireGuard peer and revokes its IKEv2 certificate on \(server). This can't be undone.")
                }
            }
            .navigationTitle(n)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .disabled(busy)
            .overlay { if busy { ProgressView() } }
            .sheet(isPresented: $editingLimit) { LimitSheet(server: server, device: n, live: live) }
            .fullScreenCover(item: Binding(get: { qr.map(QRText.init) }, set: { qr = $0?.text })) { QRView(name: n, text: $0.text) }
            .confirmationDialog("Remove \(n)?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove \(n)", role: .destructive) { remove() }
            } message: { Text("Its profiles stop working on every VPN.") }
            .task { await loadFiles() }
            .onDisappear { Profiles.clear() }
        }
        .presentationDetents([.large])
    }

    /// Each VPN it's connected on: the server port it reaches and its own address and port.
    @ViewBuilder private func connectionSection(_ n: String) -> some View {
        let conns = live.connections(n)
        if !conns.isEmpty {
            Section {
                ForEach(conns, id: \.vpn) { c in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(c.vpn).font(.subheadline.weight(.semibold))
                            Spacer()
                            if let s = c.server { Text("server \(s)").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                        }
                        Text("From \(c.from)").font(.subheadline).monospacedDigit().textSelection(.enabled)
                        if let ip = c.vpnIP { Text("VPN address \(ip)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            } header: { Text("Connection") } footer: {
                Text("“From” is the device's own address and port as the server sees it; behind a router or mobile network that's the router's.")
            }
        }
    }

    @ViewBuilder private func usageSection(_ n: String) -> some View {
        let u = live.usage?.usage[n] ?? DeviceUsage(), limit = live.usage?.limits[n], pause = live.usage?.paused[n]
        Section("Data") {
            LabeledContent("Today", value: formatBytes(u.today))
            LabeledContent("This month", value: formatBytes(u.month))
            if let limit {
                VStack(alignment: .leading, spacing: 6) {
                    Text(limit.summary).font(.subheadline)
                    if let t = limit.tightest(u) {
                        HStack { UsageMeter(fraction: t.fraction, width: 120); Text(t.text).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            if let pause { Label(pause.label, systemImage: "pause.circle.fill").foregroundStyle(.orange) }
            Button(pause == nil ? String(localized: "Pause Internet") : String(localized: "Resume Internet"), systemImage: pause == nil ? "pause" : "play") { setPaused(pause == nil) }
            Button(limit == nil ? String(localized: "Set Usage Limit…") : String(localized: "Edit Usage Limit…"), systemImage: "gauge.with.dots.needle.50percent") { editingLimit = true }
            if limit != nil {
                Button("Remove Limit", systemImage: "xmark.circle", role: .destructive) { clearLimit() }
            }
        }
    }

    @ViewBuilder private var profilesSection: some View {
        Section {
            if loadingFiles { HStack { ProgressView(); Text("Getting profiles…").foregroundStyle(.secondary) } }
            if let filesError { Text(filesError).foregroundStyle(.red).font(.footnote) }
            ForEach(files) { f in
                HStack {
                    Label(f.label, systemImage: f.symbol)
                    Spacer()
                    if f.url.pathExtension == "conf", let text = try? String(contentsOf: f.url, encoding: .utf8) {
                        Button { qr = text } label: { Image(systemName: "qrcode") }.buttonStyle(.borderless)
                            .accessibilityLabel("Show WireGuard QR code")
                    }
                    ShareLink(item: f.url) { Image(systemName: "square.and.arrow.up") }.buttonStyle(.borderless)
                        .accessibilityLabel("Share \(f.name)")
                }
            }
        } header: { Text("Profiles") } footer: {
            Text("Share a profile to the device that uses it. For IKEv2 on this iPhone: share the iPhone profile, choose Save to Files, open it in Files, then install it in Settings → General → VPN & Device Management. The QR code is for the WireGuard app.")
        }
    }

    private func loadFiles() async {
        loadingFiles = true; filesError = nil
        defer { loadingFiles = false }
        do { files = try await Profiles.fetch(device.name, server: server, store: store) }
        catch { filesError = error.localizedDescription }
    }

    private func setPaused(_ pause: Bool) {
        busy = true
        Task {
            defer { busy = false }
            do {
                _ = try await store.tool(server, "/usr/local/sbin/vpn-usage \(pause ? "pause" : "resume") \(device.name)")
                await live.refreshUsage()
                store.show(pause ? String(localized: "\(device.name) is paused: connected, but no internet.") : String(localized: "\(device.name) is back online."))
            } catch { store.show(error.localizedDescription) }
        }
    }

    private func clearLimit() {
        busy = true
        Task {
            defer { busy = false }
            do {
                _ = try await store.tool(server, "/usr/local/sbin/vpn-usage limit \(device.name) --clear")
                await live.refreshUsage()
                store.show(String(localized: "\(device.name) has no usage limit now."))
            } catch { store.show(error.localizedDescription) }
        }
    }

    private func remove() {
        busy = true
        Task {
            defer { busy = false }
            do {
                _ = try await store.tool(server, "/usr/local/sbin/vpn-remove-client \(device.name)", timeout: 180)
                await live.refreshDevices()
                await live.refreshUsage()          // its usage and limit are gone too
                store.show(String(localized: "Removed \(device.name). Sync on the Mac to update its Desktop folder."))
                dismiss()
            } catch { store.show(error.localizedDescription) }
        }
    }
}

private struct QRText: Identifiable { let text: String; var id: String { text } }

/// A full-screen WireGuard QR code, bright for scanning.
struct QRView: View {
    @Environment(\.dismiss) private var dismiss
    let name: String
    let text: String
    var body: some View {
        VStack(spacing: 20) {
            Text("Scan with the WireGuard app").font(.headline)
            Text(name).font(.largeTitle.weight(.bold))
            if let img = qrImage(text) {
                Image(uiImage: img).interpolation(.none).resizable().scaledToFit()
                    .padding(16).background(.white, in: RoundedRectangle(cornerRadius: 20)).padding(.horizontal, 24)
            }
            Text("This code holds the device's private key. Don't share it.").font(.footnote).foregroundStyle(.secondary)
            Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
        }
        .padding()
        .onAppear { UIScreen.main.brightness = max(UIScreen.main.brightness, 0.9) }
    }

    private func qrImage(_ s: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8); f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Limit editor

struct LimitSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let server: String
    let device: String
    @ObservedObject var live: ServerLive

    enum Unit: String, CaseIterable { case mb = "MB", gb = "GB" }
    @State private var dailyOn = false
    @State private var dailyValue = "2"
    @State private var dailyUnit = Unit.gb
    @State private var monthlyOn = false
    @State private var monthlyValue = "50"
    @State private var monthlyUnit = Unit.gb
    @State private var pauses = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    limitRow("Daily", on: $dailyOn, value: $dailyValue, unit: $dailyUnit)
                    limitRow("Monthly", on: $monthlyOn, value: $monthlyValue, unit: $monthlyUnit)
                } footer: { Text("Days follow this iPhone's time zone (\(TimeZone.current.identifier)).") }
                Section {
                    Picker("Action", selection: $pauses) {
                        Text("Alert only").tag(false)
                        Text("Pause its internet").tag(true)
                    }
                    .pickerStyle(.inline).labelsHidden()
                } header: { Text("When it reaches the limit") } footer: {
                    Text("Alerts appear on your Mac. A paused device stays connected but gets no internet until midnight (daily) or the 1st (monthly); you can resume it early.")
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Limit for \(device)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(working || (!dailyOn && !monthlyOn) || bytes(dailyOn, dailyValue, dailyUnit) == nil || bytes(monthlyOn, monthlyValue, monthlyUnit) == nil)
                }
            }
            .disabled(working)
            .onAppear(perform: load)
        }
        .presentationDetents([.medium, .large])
    }

    private func limitRow(_ title: LocalizedStringKey, on: Binding<Bool>, value: Binding<String>, unit: Binding<Unit>) -> some View {
        HStack {
            Text(title).frame(width: 78, alignment: .leading)
            Toggle(title, isOn: on).labelsHidden()
            Spacer()
            TextField("0", text: value).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 70).disabled(!on.wrappedValue)
            Picker("", selection: unit) { ForEach(Unit.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).frame(width: 96).disabled(!on.wrappedValue)
        }
    }

    /// 0 when off, nil when the number isn't valid.
    private func bytes(_ on: Bool, _ v: String, _ u: Unit) -> Int64? {
        guard on else { return 0 }
        guard let d = Double(v.replacingOccurrences(of: ",", with: ".")), d > 0 else { return nil }
        return Int64(d * (u == .gb ? 1_073_741_824 : 1_048_576))
    }

    private func load() {
        guard let l = live.usage?.limits[device] else { return }
        func split(_ b: Int64) -> (String, Unit) {
            b >= 1_073_741_824 ? (trim(Double(b) / 1_073_741_824), .gb) : (trim(Double(b) / 1_048_576), .mb)
        }
        func trim(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(format: "%.2f", d) }
        if l.daily > 0 { dailyOn = true; (dailyValue, dailyUnit) = split(l.daily) }
        if l.monthly > 0 { monthlyOn = true; (monthlyValue, monthlyUnit) = split(l.monthly) }
        pauses = l.pauses
    }

    private func save() {
        guard let d = bytes(dailyOn, dailyValue, dailyUnit), let m = bytes(monthlyOn, monthlyValue, monthlyUnit) else { return }
        working = true; error = nil
        let tz = TimeZone.current.identifier
        let tzArg = tz.range(of: #"^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$"#, options: .regularExpression) != nil ? " --tz \(tz)" : ""
        Task {
            defer { working = false }
            do {
                _ = try await store.tool(server, "/usr/local/sbin/vpn-usage limit \(device) --daily \(d) --monthly \(m) --action \(pauses ? "pause" : "alert")\(tzArg)")
                await live.refreshUsage()
                store.show(String(localized: "Saved the limit for \(device)."))
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Add devices

/// One name, several (commas, spaces or new lines), or a generated series (phone1…phone5).
struct AddDeviceSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let server: String
    @ObservedObject var live: ServerLive
    @State private var text = ""
    @State private var prefix = "device"
    @State private var start = 1
    @State private var count = 5
    @State private var working = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var names: [String] { text.components(separatedBy: CharacterSet(charactersIn: ", \n\t")).filter { !$0.isEmpty } }

    private var problems: [String] {
        let existing = Set(live.allDevices.map(\.name))
        var seen = Set<String>(), out: [String] = []
        for n in names {
            if seen.contains(n) { out.append(String(localized: "\(n) is listed twice.")) }
            seen.insert(n)
            if n.range(of: #"^[A-Za-z0-9_-]{1,15}$"#, options: .regularExpression) == nil { out.append(String(localized: "\(n): use 1–15 letters, numbers, - or _.")) }
            else if existing.contains(n) { out.append(String(localized: "\(n) already exists.")) }
        }
        if names.count > 50 { out.append(String(localized: "At most 50 devices at a time.")) }
        return out
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Names, e.g. phone2, tv, laptop", text: $text, axis: .vertical)
                        .lineLimit(1...6)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focused)
                } footer: {
                    if let p = problems.first { Text(p).foregroundStyle(.red) }
                    else if live.hasIPsec { Text("One or more names, separated by commas, spaces or new lines. Each device gets a profile for every VPN on \(server): OpenVPN, WireGuard and IKEv2.") }
                    else { Text("One or more names, separated by commas, spaces or new lines. Each device gets a profile for every VPN on \(server): OpenVPN, WireGuard.") }
                }
                Section {
                    TextField("Prefix", text: $prefix).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Stepper("From \(start)", value: $start, in: 0...999)
                    Stepper(count == 1 ? String(localized: "1 device") : String(localized: "\(count) devices"), value: $count, in: 1...50)
                    Button("Fill In \(prefix)\(start)…\(prefix)\(start + count - 1)") {
                        text = (start..<(start + count)).map { "\(prefix)\($0)" }.joined(separator: ", ")
                    }
                    .disabled(prefix.isEmpty)
                } header: { Text("Or generate names") }
                if working {
                    HStack { ProgressView(); Text(names.count == 1 ? String(localized: "Creating 1 device… about 10 seconds each.") : String(localized: "Creating \(names.count) devices… about 10 seconds each.")) }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(names.count > 1 ? String(localized: "Add \(names.count) Devices") : String(localized: "Add Device"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(working) }
                ToolbarItem(placement: .confirmationAction) { Button("Add") { add() }.disabled(working || names.isEmpty || !problems.isEmpty) }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(working)
        .onAppear { focused = true }
    }

    private func add() {
        let list = names
        working = true; error = nil
        Task {
            defer { working = false }
            do {
                _ = try await store.tool(server, "/usr/local/sbin/vpn-add-client \(list.joined(separator: " "))", timeout: 120 + 60 * list.count)
                await live.refreshDevices()
                store.show(list.count == 1 ? String(localized: "Created \(list[0]). Sync on the Mac to copy its profiles to the Desktop.")
                                           : String(localized: "Created \(list.count) devices. Sync on the Mac to copy their profiles to the Desktop."))
                dismiss()
            } catch {
                await live.refreshDevices()        // some may have been created before the failure
                self.error = error.localizedDescription
            }
        }
    }
}

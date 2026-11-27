// Settings (servers, import, Face ID, warning level), the import sheet and the first-run screen.
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let vpnSyncServers = UTType(exportedAs: "local.vpnsync.servers")
}

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var removing: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(store.servers) { s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name).font(.body.weight(.medium))
                            Text("\(s.user)@\(s.address)" + (s.jump.map { String(localized: ", through \($0)") } ?? "")).font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions { Button("Remove", role: .destructive) { removing = s.name } }
                    }
                    Button("Import Servers…", systemImage: "square.and.arrow.down") { picking = true }
                } header: { Text("Servers") } footer: {
                    Text("On the Mac: VPN Sync Settings → iPhone → Export for iPhone…, then AirDrop the file here and open it with VPN Sync. Importing again updates the servers.")
                }
                Section {
                    Toggle("Lock with Face ID", isOn: $store.lockEnabled)
                } footer: { Text("Asks for Face ID (or your passcode) when VPN Sync opens. Your servers' keys stay in this iPhone's Keychain either way.") }
                Section("Usage limits") {
                    Picker("Warn at", selection: $store.warnAt) {
                        Text("Off").tag(0)
                        ForEach([50, 70, 80, 90], id: \.self) { Text("\($0)%").tag($0) }
                    }
                }
                Section {
                    // iOS keeps each app's language in the Settings app (VPN Sync → Language)
                    Button {
                        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                    } label: {
                        LabeledContent("Language") {
                            Text(Locale.current.localizedString(forIdentifier: Bundle.main.preferredLocalizations.first ?? "en") ?? "")
                        }
                    }
                } footer: {
                    Text("Opens VPN Sync in the Settings app, where you can choose English or Simplified Chinese.")
                }
                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                } footer: {
                    Text("Installed with a free Apple ID, VPN Sync has to be reinstalled from Xcode every 7 days.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.vpnSyncServers, .data]) { result in
                if case .success(let url) = result { store.pendingImport = readImport(url) }
            }
            .confirmationDialog("Remove \(removing ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button("Remove from This iPhone", role: .destructive) { if let r = removing { store.remove(r) }; removing = nil }
            } message: { Text("Only this iPhone forgets it, with its key. The server and its devices aren't touched.") }
        }
        .toasts()
    }
}

/// Reads a picked or opened file (they may need security-scoped access).
func readImport(_ url: URL) -> Data? {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    return try? Data(contentsOf: url)
}

struct ImportSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let data: Data
    @State private var passphrase = ""
    @State private var error: String?
    @State private var working = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("XXXX-XXXX-XXXX-XXXX", text: $passphrase)
                        .font(.system(.title3, design: .monospaced))
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .focused($focused).submitLabel(.done).onSubmit(open)
                } header: { Text("Passphrase") } footer: {
                    Text(error ?? String(localized: "The Mac showed it when it exported the file.")).foregroundStyle(error == nil ? Color.secondary : .red)
                }
                if working { HStack { ProgressView(); Text("Unlocking…") } }
            }
            .navigationTitle("Import Servers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Import", action: open).disabled(passphrase.isEmpty || working) }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }

    private func open() {
        guard !passphrase.isEmpty else { return }
        working = true; error = nil
        let data = data, phrase = passphrase
        Task {
            // the key derivation takes a moment; keep it off the main thread
            let result = await Task.detached { Result { try ServerBundle.open(data, passphrase: phrase) } }.value
            working = false
            switch result {
            case .failure(let e): error = e.localizedDescription
            case .success:
                do {
                    let n = try store.importBundle(data, passphrase: phrase)
                    store.show(n == 1 ? String(localized: "Imported 1 server.") : String(localized: "Imported \(n) servers."))
                    dismiss()
                } catch { self.error = error.localizedDescription }
            }
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject var store: Store
    @State private var picking = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "lock.shield").font(.system(size: 56, weight: .light)).foregroundStyle(.tint)
                Text("VPN Sync").font(.largeTitle.weight(.bold))
                Text("See who's on your VPN servers, how much data they use, pause them, set limits, and add or remove devices, from your iPhone.")
                    .font(.body).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Get your servers from the Mac").font(.headline)
                    step(1, "Open VPN Sync on the Mac, then Settings → iPhone.")
                    step(2, "Click Export for iPhone… and AirDrop the file to this iPhone.")
                    step(3, "Open it with VPN Sync and type the passphrase the Mac shows.")
                }
                .card()
                Button { picking = true } label: { Label("Import Servers…", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
            .padding(24)
        }
        .background(Backdrop())
        .fileImporter(isPresented: $picking, allowedContentTypes: [.vpnSyncServers, .data]) { result in
            if case .success(let url) = result { store.pendingImport = readImport(url) }
        }
    }
    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.subheadline.weight(.bold)).frame(width: 22, height: 22).background(Circle().fill(.tint.opacity(0.2)))
            Text(text).font(.subheadline)
        }
    }
}

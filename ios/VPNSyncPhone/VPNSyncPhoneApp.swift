// VPN Sync for iPhone: manage the same servers as the Mac app, over SSH from the phone.
import SwiftUI

@main
struct VPNSyncPhoneApp: App {
    @StateObject private var store = Store()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .onOpenURL { url in store.pendingImport = readImport(url) }
                .onChange(of: phase) { _, p in
                    switch p {
                    case .active: store.becameActive()
                    case .background: store.wentToBackground(); Profiles.clear()
                    default: break
                    }
                }
                .task { debugImport() }
        }
    }

    /// Test hook (DEBUG): -importFile <path in the app's container> -importPassphrase <p>.
    private func debugImport() {
        #if DEBUG
        let d = UserDefaults.standard
        guard let f = d.string(forKey: "importFile"), let p = d.string(forKey: "importPassphrase") else { return }
        let url = URL(fileURLWithPath: f.hasPrefix("/") ? f : NSHomeDirectory() + "/" + f)
        if let data = try? Data(contentsOf: url) {
            do { try store.importBundle(data, passphrase: p); try? FileManager.default.removeItem(at: url) }
            catch { store.show(error.localizedDescription) }
        }
        #endif
    }
}

struct RootView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        ZStack {
            if store.servers.isEmpty { WelcomeView() } else { ServersView() }
            if store.locked { LockView() }
        }
        .sheet(isPresented: Binding(get: { store.pendingImport != nil && !store.locked }, set: { if !$0 { store.pendingImport = nil } })) {
            if let d = store.pendingImport { ImportSheet(data: d) }
        }
        .overlay(alignment: .bottom) {
            if let t = store.toast {
                Text(t).font(.subheadline).multilineTextAlignment(.center)
                    .card(18, padding: 14).padding(.horizontal, 20).padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { store.toast = nil }
            }
        }
        .animation(.snappy, value: store.toast)
    }
}

struct LockView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill").font(.system(size: 44))
            Text("VPN Sync is locked").font(.title3.weight(.semibold))
            Button("Unlock") { store.unlock() }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThickMaterial)
    }
}

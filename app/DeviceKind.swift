// What kind of device a VPN profile is used on. Sources, strongest first: the user's choice,
// what the OpenVPN client reported (IV_PLAT / IV_GUI_VER, via vpn-status DEVINFO), and the name.
// WireGuard clients report nothing, so a WireGuard-only device is guessed from its name.
import SwiftUI

enum DeviceKind: String, CaseIterable, Identifiable {
    case mac, iphone, ipad, androidPhone, androidTV, appleTV, windows, linux, phone, tv, laptop, unknown
    var id: String { rawValue }

    var label: String {
        switch self {
        case .mac: return "Mac"
        case .iphone: return "iPhone"
        case .ipad: return "iPad"
        case .androidPhone: return "Android phone"
        case .androidTV: return "Android TV"
        case .appleTV: return "Apple TV"
        case .windows: return "Windows PC"
        case .linux: return "Linux"
        case .phone: return "Phone"
        case .tv: return "TV"
        case .laptop: return "Laptop"
        case .unknown: return "Unknown device"
        }
    }

    var icon: String {
        switch self {
        case .mac, .laptop: return "laptop"
        case .iphone, .androidPhone, .phone: return "smartphone"
        case .ipad: return "tablet"
        case .androidTV, .appleTV, .tv: return "tv"
        case .windows, .linux: return "monitor"
        case .unknown: return "circle-help"
        }
    }

    /// Choices offered in the Device Type menu.
    static let choices: [DeviceKind] = [.mac, .iphone, .ipad, .androidPhone, .androidTV, .appleTV, .windows, .linux, .laptop]

    /// From the OpenVPN client's report, refined by the name (Android doesn't say phone vs TV).
    static func from(platform: String, name: String) -> DeviceKind? {
        let n = name.lowercased()
        switch platform.lowercased() {
        case "ios": return n.contains("ipad") ? .ipad : (n.contains("tv") ? .appleTV : .iphone)
        case "android": return n.contains("tv") ? .androidTV : .androidPhone
        case "mac": return .mac
        case "win": return .windows
        case "linux": return n.contains("tv") ? .tv : .linux
        default: return nil
        }
    }

    /// A guess from the device name alone.
    static func guess(name: String) -> DeviceKind {
        let n = name.lowercased()
        func has(_ words: String...) -> Bool { words.contains { n.contains($0) } }
        if has("ipad") { return .ipad }
        if has("iphone") { return .iphone }
        if has("appletv", "apple-tv", "apple_tv") { return .appleTV }
        if has("androidtv", "android-tv", "android_tv", "firetv", "fire-tv", "shield") { return .androidTV }
        if has("tv") { return .tv }
        if has("mac", "imac") { return .mac }
        if has("android", "pixel", "galaxy", "samsung", "xiaomi", "huawei", "oneplus") { return .androidPhone }
        if has("windows", "win10", "win11", "-pc", "desktop") { return .windows }
        if has("linux", "ubuntu") { return .linux }
        if has("laptop", "notebook") { return .laptop }
        if has("phone", "mobile") { return .phone }
        return .unknown
    }
}

/// "net.openvpn.connect.ios_3.7.4-7008" / "OCmacOS_3.8.1-5790" → "OpenVPN Connect 3.7.4"
func prettyClientApp(_ raw: String) -> String? {
    guard raw != "-", !raw.isEmpty else { return nil }
    let version = raw.split(separator: "_").last.map { String($0.split(separator: "-").first ?? "") } ?? ""
    let lower = raw.lowercased()
    if lower.contains("openvpn.connect") || lower.hasPrefix("ocmacos") || lower.hasPrefix("ocwindows") {
        return version.isEmpty ? "OpenVPN Connect" : "OpenVPN Connect \(version)"
    }
    return raw
}

extension Model {
    private var kindOverrides: [String: String] {
        (UserDefaults.standard.dictionary(forKey: "deviceKinds") as? [String: String]) ?? [:]
    }

    /// The user's choice, else the OpenVPN report, else a guess from the name.
    func deviceKind(_ name: String) -> DeviceKind {
        if let raw = kindOverrides["\(server)/\(name)"], let k = DeviceKind(rawValue: raw) { return k }
        if let info = live?.devInfo[name], let k = DeviceKind.from(platform: info.platform, name: name) { return k }
        return DeviceKind.guess(name: name)
    }

    func deviceKindIsManual(_ name: String) -> Bool { kindOverrides["\(server)/\(name)"] != nil }

    /// The VPN app the device reported, if any ("OpenVPN Connect 3.7.4").
    func deviceApp(_ name: String) -> String? { live?.devInfo[name].flatMap { prettyClientApp($0.app) } }

    func setDeviceKind(_ name: String, _ kind: DeviceKind?) {
        var o = kindOverrides
        o["\(server)/\(name)"] = kind?.rawValue
        UserDefaults.standard.set(o, forKey: "deviceKinds")
        objectWillChange.send()
    }
}

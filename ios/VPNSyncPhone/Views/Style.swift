// Shared look: glass cards (Liquid Glass on iOS 26, material before), colours per VPN and for
// download/upload (the same as the Mac app), small reusable pieces.
import SwiftUI

enum Palette {
    static let online = Color(red: 0.11, green: 0.69, blue: 0.48)
    static let openvpn = Color(red: 0.96, green: 0.69, blue: 0.30)
    static let wireguard = Color.cyan
    static let ikev2 = Color(red: 0.65, green: 0.55, blue: 0.98)
    static let download = Color.blue
    static let upload = Color.orange
    static func vpn(_ name: String) -> Color {
        switch name { case "OpenVPN", "openvpn": return openvpn; case "WireGuard", "wireguard": return wireguard; default: return ikev2 }
    }
}

extension View {
    /// A rounded glass card.
    @ViewBuilder func card(_ radius: CGFloat = 22, padding: CGFloat = 16) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(iOS 26.0, *) {
            self.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: shape)
        } else {
            self.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: shape)
        }
    }

    /// A small capsule (status pills, badges).
    @ViewBuilder func pill(_ tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            self.padding(.horizontal, 11).padding(.vertical, 6)
                .glassEffect(tint.map { .regular.tint($0.opacity(0.25)) } ?? .regular, in: Capsule())
        } else {
            self.padding(.horizontal, 11).padding(.vertical, 6)
                .background((tint ?? .secondary).opacity(0.15), in: Capsule())
        }
    }
}

/// A coloured dot, glowing when on.
struct StatusDot: View {
    let color: Color
    var on = true
    var size: CGFloat = 8
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .shadow(color: on ? color.opacity(0.8) : .clear, radius: 3)
    }
}

/// The device's icon with an online dot.
struct DeviceAvatar: View {
    let kind: DeviceKind
    let online: Bool
    var size: CGFloat = 40
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: kind.symbol)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: size, height: size)
                .background(Circle().fill(.thinMaterial))
            Circle()
                .fill(online ? Palette.online : Color(.systemGray3))
                .frame(width: size * 0.3, height: size * 0.3)
                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
        }
        .accessibilityLabel(online ? String(localized: "Online") : String(localized: "Offline"))
    }
}

/// "Paused" capsule.
struct PausedBadge: View {
    let info: PauseInfo
    var body: some View {
        Label("Paused", systemImage: "pause.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Color.orange.opacity(0.16), in: Capsule())
            .accessibilityHint(info.label)
    }
}

/// A small capsule meter: accent below the warning level, orange from it, red at 100%.
struct UsageMeter: View {
    let fraction: Double
    var width: CGFloat = 60
    var body: some View {
        let f = max(0, min(1, fraction))
        let color: Color = fraction >= 1 ? .red : fraction >= (usageWarnFraction ?? 1) ? .orange : .accentColor
        ZStack(alignment: .leading) {
            Capsule().fill(.primary.opacity(0.12))
            Capsule().fill(color).frame(width: max(f > 0 ? 4 : 0, width * f))
        }
        .frame(width: width, height: 5)
        .accessibilityElement()
        .accessibilityLabel("Usage")
        .accessibilityValue(String(localized: "\(Int(fraction * 100)) percent of the limit"))
    }
}

/// Down above the line, up below it, last 15 minutes.
import Charts
struct Sparkline: View {
    let points: [TrafficPoint]
    var height: CGFloat = 26
    var body: some View {
        let top = max(points.map { max($0.down, $0.up) }.max() ?? 1, 1)
        Chart {
            ForEach(points) { p in
                AreaMark(x: .value("t", p.time), y: .value("v", p.down), series: .value("d", "Download"), stacking: .unstacked)
                    .foregroundStyle(Palette.download.opacity(0.25)).interpolationMethod(.monotone)
                LineMark(x: .value("t", p.time), y: .value("v", p.down), series: .value("d", "Download"))
                    .foregroundStyle(Palette.download).lineStyle(StrokeStyle(lineWidth: 1.5)).interpolationMethod(.monotone)
                AreaMark(x: .value("t", p.time), y: .value("v", -p.up), series: .value("d", "Upload"), stacking: .unstacked)
                    .foregroundStyle(Palette.upload.opacity(0.25)).interpolationMethod(.monotone)
                LineMark(x: .value("t", p.time), y: .value("v", -p.up), series: .value("d", "Upload"))
                    .foregroundStyle(Palette.upload).lineStyle(StrokeStyle(lineWidth: 1.5)).interpolationMethod(.monotone)
            }
            RuleMark(y: .value("z", 0)).foregroundStyle(.secondary.opacity(0.25)).lineStyle(StrokeStyle(lineWidth: 0.5))
        }
        .chartYScale(domain: -top...top)
        .chartXAxis(.hidden).chartYAxis(.hidden)
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

func relative(_ d: Date) -> String { d.formatted(.relative(presentation: .named)) }

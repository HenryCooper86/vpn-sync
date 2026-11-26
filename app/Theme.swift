// Visual system: themes (full palettes, each with its own light/dark mode), the colour-field
// backdrop behind the glass, glass helpers with macOS 14 fallbacks, the signal orb, avatars.
import SwiftUI
import AppKit

// MARK: - Themes

struct Theme: Identifiable, Equatable {
    let id: String
    let name: String
    let dark: Bool
    let deep: Color       // backdrop base
    let glowA: Color      // primary glow, also the accent
    let glowB: Color      // secondary glow
    let mist: Color       // highlights
    let online: Color     // "connected"
    let hue: Double       // accent hue, for harmonious avatar colours
    var accent: Color { glowA }
    var scheme: ColorScheme { dark ? .dark : .light }

    static let aurora = Theme(id: "aurora", name: "Aurora", dark: true,
        deep: Color(hex: 0x0E2A3B), glowA: Color(hex: 0x2EC4B6), glowB: Color(hex: 0x7B61FF),
        mist: Color(hex: 0xE8F1F2), online: Color(hex: 0x34D399), hue: 0.49)
    static let sakura = Theme(id: "sakura", name: "Sakura", dark: true,
        deep: Color(hex: 0x2A1730), glowA: Color(hex: 0xFF7AA8), glowB: Color(hex: 0xA58CFF),
        mist: Color(hex: 0xFCE7F0), online: Color(hex: 0x7EE0B5), hue: 0.94)
    static let glacier = Theme(id: "glacier", name: "Glacier", dark: false,
        deep: Color(hex: 0xD3E6F3), glowA: Color(hex: 0x2F7FD0), glowB: Color(hex: 0x7FD4F2),
        mist: Color(hex: 0xFFFFFF), online: Color(hex: 0x16A34A), hue: 0.58)
    static let moss = Theme(id: "moss", name: "Moss", dark: true,
        deep: Color(hex: 0x15241B), glowA: Color(hex: 0xD9B26A), glowB: Color(hex: 0x5E9F6B),
        mist: Color(hex: 0xEEF3E6), online: Color(hex: 0x8BE38B), hue: 0.11)
    static let graphite = Theme(id: "graphite", name: "Graphite", dark: true,
        deep: Color(hex: 0x1C1D22), glowA: Color(hex: 0xA9B7CC), glowB: Color(hex: 0x4E5668),
        mist: Color(hex: 0xF2F3F5), online: Color(hex: 0x34D399), hue: 0.60)

    static let all: [Theme] = [aurora, sakura, glacier, moss, graphite]
    static func named(_ id: String) -> Theme { all.first { $0.id == id } ?? aurora }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

private struct ThemeKey: EnvironmentKey { static let defaultValue = Theme.aurora }
extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// Applies the chosen theme: environment, accent tint, and the app's light/dark appearance
/// (app-wide, so sheets, Settings and the menu bar panel match).
struct Themed<Content: View>: View {
    @AppStorage("theme") private var themeID = Theme.aurora.id
    var backdrop = true
    @ViewBuilder let content: Content

    var body: some View {
        let t = Theme.named(themeID)
        content
            .tint(t.accent)
            .background { if backdrop { Backdrop().ignoresSafeArea() } }
            .environment(\.theme, t)      // outermost, so the backdrop sees the theme too
            .onAppear { applyAppearance(t) }
            .onChange(of: themeID) { applyAppearance(Theme.named(themeID)) }
    }

    private func applyAppearance(_ t: Theme) {
        NSApp.appearance = NSAppearance(named: t.dark ? .darkAqua : .aqua)
    }
}

// MARK: - Backdrop

/// The colour field behind the glass: deep base, two soft glows from opposite corners.
struct Backdrop: View {
    @Environment(\.theme) private var t
    var body: some View {
        if #available(macOS 15.0, *) {
            MeshGradient(
                width: 3, height: 3,
                points: [[0, 0], [0.5, 0], [1, 0],
                         [0, 0.5], [0.58, 0.42], [1, 0.5],
                         [0, 1], [0.5, 1], [1, 1]],
                colors: [t.deep, t.deep.mix(with: t.glowB, by: 0.25), t.deep.mix(with: t.glowB, by: 0.55),
                         t.deep.mix(with: t.glowA, by: 0.12), t.deep, t.deep.mix(with: t.glowB, by: 0.2),
                         t.deep.mix(with: t.glowA, by: 0.5), t.deep.mix(with: t.glowA, by: 0.2), t.deep],
                smoothsColors: true)
        } else {
            ZStack {
                t.deep
                RadialGradient(colors: [t.glowB.opacity(0.5), .clear], center: .topTrailing, startRadius: 0, endRadius: 520)
                RadialGradient(colors: [t.glowA.opacity(0.45), .clear], center: .bottomLeading, startRadius: 0, endRadius: 520)
            }
        }
    }
}

// MARK: - Glass

extension View {
    /// A Liquid Glass panel (macOS 26+), or a material panel with a hairline rim before that.
    @ViewBuilder func glassPanel(_ radius: CGFloat = 22, tint: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(tint.map { Glass.regular.tint($0.opacity(0.22)) } ?? .regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .background(tint.map { shape.fill($0.opacity(0.10)) })
                .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 1))
        }
    }

    @ViewBuilder func glassCapsule(tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(tint.map { Glass.regular.tint($0.opacity(0.25)) } ?? .regular, in: Capsule())
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
                .background(tint.map { Capsule().fill($0.opacity(0.12)) })
                .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
        }
    }

    /// Glass buttons. Only prominent ones take the theme colour; the rest stay clear glass so the
    /// accent marks the one or two main actions on screen.
    @ViewBuilder func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass).tint(nil) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered).tint(nil) }
        }
    }

    /// A menu that shows its whole custom label (macOS otherwise reduces it to plain text).
    func fullLabelMenu() -> some View {
        self.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

/// Groups glass shapes so they blend like one material (macOS 26+).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder let content: Content
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - Signal orb

/// The header's centrepiece: a lit glass disc with the server's online count. It ripples once
/// when a device connects (not with Reduce Motion).
struct SignalOrb: View {
    @Environment(\.theme) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let count: Int?
    let live: Bool
    @State private var ripple = 0

    var body: some View {
        ZStack {
            Circle()
                .fill(AngularGradient(colors: [t.glowA, t.glowB, t.glowA.opacity(0.6), t.glowA], center: .center))
                .blur(radius: 14)
                .opacity(live ? 0.85 : 0.25)
                .scaleEffect(1.05)
            if ripple > 0 { RippleRing(color: t.online).id(ripple) }
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().fill(LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center)))
                .overlay(Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.65), .white.opacity(0.08)],
                                                              startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.2))
            VStack(spacing: -3) {
                Text(count.map(String.init) ?? "–")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("online").font(.system(size: 11, weight: .medium, design: .rounded)).opacity(0.75)
            }
            .foregroundStyle(.primary)
        }
        .frame(width: 78, height: 78)
        .animation(.snappy, value: count)
        .onChange(of: count) { old, new in
            if let o = old, let n = new, n > o, !reduceMotion { ripple += 1 }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count.map { "\($0) devices online" } ?? "Live monitoring off")
    }
}

private struct RippleRing: View {
    let color: Color
    @State private var go = false
    var body: some View {
        Circle()
            .stroke(color, lineWidth: 2)
            .scaleEffect(go ? 1.7 : 1)
            .opacity(go ? 0 : 0.9)
            .onAppear { withAnimation(.easeOut(duration: 1.2)) { go = true } }
    }
}

// MARK: - Device avatar

/// Initials on a colour picked from the device name, within the theme's hue range.
struct DeviceAvatar: View {
    @Environment(\.theme) private var t
    let name: String
    let online: Bool?

    var body: some View {
        let h = Double(stableHash(name) % 1000) / 1000
        let hue = (t.hue + (h - 0.5) * 0.18 + 1).truncatingRemainder(dividingBy: 1)
        let top = Color(hue: hue, saturation: 0.50, brightness: t.dark ? 0.82 : 0.78)
        let bottom = Color(hue: hue, saturation: 0.65, brightness: t.dark ? 0.58 : 0.62)
        ZStack {
            Circle().fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
            Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1)
            Text(initials(name))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: 34, height: 34)
        .overlay(alignment: .bottomTrailing) {
            if let online {
                Circle()
                    .fill(online ? t.online : Color.gray.opacity(0.7))
                    .frame(width: 11, height: 11)
                    .overlay(Circle().stroke(t.dark ? Color.black.opacity(0.55) : .white, lineWidth: 2))
                    .shadow(color: online ? t.online.opacity(0.8) : .clear, radius: 4)
                    .offset(x: 2, y: 2)
            }
        }
        .accessibilityHidden(true)
    }

    /// "m1-20261123" → M1, "anna3" → A3, "home-iphone" → HI, "laptop" → La
    private func initials(_ s: String) -> String {
        let first = s.prefix(1).uppercased()
        let token = s.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? s
        if let d = token.firstIndex(where: \.isNumber) {
            return first + token[d...].prefix(while: \.isNumber).prefix(2)
        }
        let parts = s.split(whereSeparator: { $0 == "-" || $0 == "_" })
        if parts.count > 1, let c = parts[1].first { return first + String(c).uppercased() }
        return first + s.dropFirst().prefix(1).lowercased()
    }

    private func stableHash(_ s: String) -> UInt64 {
        s.utf8.reduce(5381) { ($0 << 5) &+ $0 &+ UInt64($1) }
    }
}

/// Icon and title close together (for small numeric labels like transfer speeds).
struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) { configuration.icon.imageScale(.small); configuration.title }
    }
}

// MARK: - Theme picker

struct ThemePicker: View {
    @AppStorage("theme") private var themeID = Theme.aurora.id
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 14)], spacing: 14) {
            ForEach(Theme.all) { t in
                Button { themeID = t.id } label: { ThemeSwatch(theme: t, selected: t.id == themeID) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(t.name) theme")
                    .accessibilityAddTraits(t.id == themeID ? .isSelected : [])
            }
        }
    }
}

private struct ThemeSwatch: View {
    let theme: Theme
    let selected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                Backdrop().environment(\.theme, theme)
                HStack(spacing: 5) {
                    Circle().fill(theme.online).frame(width: 7, height: 7)
                    Capsule().fill(.white.opacity(theme.dark ? 0.22 : 0.6)).frame(width: 46, height: 7)
                }
                .padding(8)
                .background(.ultraThinMaterial, in: Capsule())
                .environment(\.colorScheme, theme.scheme)
                .padding(10)
            }
            .frame(height: 74)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? theme.accent : Color.primary.opacity(0.12), lineWidth: selected ? 2.5 : 1))
            Text(theme.name).font(.callout.weight(selected ? .semibold : .regular))
        }
    }
}

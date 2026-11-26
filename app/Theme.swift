// Visual system: Light and Dark palettes that sit with macOS (Automatic follows the system),
// the soft backdrop behind the glass, glass helpers with macOS 14 fallbacks, the signal orb,
// avatars. Accent colour = the user's macOS accent colour, like Apple's own apps.
import SwiftUI
import AppKit

// MARK: - Themes

struct Theme: Identifiable, Equatable {
    let id: String
    let name: String
    let dark: Bool
    let deep: Color       // backdrop base
    let glowA: Color      // soft glow, one corner
    let glowB: Color      // soft glow, the other corner
    let online: Color     // "connected" (Apple system green)
    var scheme: ColorScheme { dark ? .dark : .light }

    static let light = Theme(id: "light", name: "Light", dark: false,
        deep: Color(hex: 0xEEF0F4), glowA: Color(hex: 0xD8E3F1), glowB: Color(hex: 0xE5E1EE),
        online: Color(hex: 0x28A745))
    static let dark = Theme(id: "dark", name: "Dark", dark: true,
        deep: Color(hex: 0x16181D), glowA: Color(hex: 0x27303D), glowB: Color(hex: 0x2E2A3C),
        online: Color(hex: 0x30D158))
}

/// Appearance choice: follow macOS, or force light or dark.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case auto, light, dark
    var id: String { rawValue }
    var label: String { self == .auto ? "Automatic" : self == .light ? "Light" : "Dark" }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

private struct ThemeKey: EnvironmentKey { static let defaultValue = Theme.dark }
extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// Applies the appearance app-wide (so sheets, Settings and the menu bar panel match) and puts
/// the matching palette and backdrop behind the content.
struct Themed<Content: View>: View {
    @AppStorage("appearance") private var mode = AppearanceMode.auto.rawValue
    @Environment(\.colorScheme) private var scheme
    var backdrop = true
    @ViewBuilder let content: Content

    var body: some View {
        let t = resolved
        content
            .background { if backdrop { Backdrop().ignoresSafeArea() } }
            .environment(\.theme, t)      // outermost, so the backdrop sees it too
            .onAppear { apply() }
            .onChange(of: mode) { apply() }
    }

    private var resolved: Theme {
        switch AppearanceMode(rawValue: mode) ?? .auto {
        case .light: return .light
        case .dark: return .dark
        case .auto: return scheme == .dark ? .dark : .light
        }
    }

    private func apply() {
        switch AppearanceMode(rawValue: mode) ?? .auto {
        case .auto: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Backdrop

/// What sits behind the glass: a live blur of whatever is behind the window (desktop, other
/// windows), like macOS sidebars, with only a faint tint on top.
struct Backdrop: View {
    @Environment(\.theme) private var t
    var body: some View {
        ZStack {
            WindowBlur()
            tint.opacity(t.dark ? 0.10 : 0.08)
        }
    }

    @ViewBuilder private var tint: some View {
        if #available(macOS 15.0, *) {
            MeshGradient(
                width: 3, height: 3,
                points: [[0, 0], [0.5, 0], [1, 0],
                         [0, 0.5], [0.58, 0.42], [1, 0.5],
                         [0, 1], [0.5, 1], [1, 1]],
                colors: [t.deep, t.deep.mix(with: t.glowB, by: 0.4), t.deep.mix(with: t.glowB, by: 0.8),
                         t.deep.mix(with: t.glowA, by: 0.2), t.deep, t.deep.mix(with: t.glowB, by: 0.3),
                         t.deep.mix(with: t.glowA, by: 0.8), t.deep.mix(with: t.glowA, by: 0.3), t.deep],
                smoothsColors: true)
        } else {
            LinearGradient(colors: [t.glowB, t.deep, t.glowA], startPoint: .topTrailing, endPoint: .bottomLeading)
        }
    }
}

/// NSVisualEffectView blending with what's behind the window; follows light/dark by itself.
/// It also makes its window non-opaque, so nothing solid sits behind the blur.
struct WindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = SeeThroughBlur()
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

final class SeeThroughBlur: NSVisualEffectView {
    /// The lightest blurs macOS offers: HUD in dark mode, popover in light mode.
    private func pickMaterial() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        material = dark ? .hudWindow : .popover
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        pickMaterial()
    }
    override func viewDidMoveToWindow() {
        pickMaterial()
        super.viewDidMoveToWindow()
        guard let w = window, !(w is NSPanel) else { return }
        w.isOpaque = false
        w.backgroundColor = .clear
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
            // .clear, not nil: a nil tint falls back to the system accent colour in active windows
            if prominent { self.buttonStyle(.glassProminent).tint(.accentColor) } else { self.buttonStyle(.glass).tint(.clear) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent).tint(.accentColor) } else { self.buttonStyle(.bordered) }
        }
    }

    /// A menu that shows its whole custom label (macOS otherwise reduces it to plain text).
    func fullLabelMenu() -> some View {
        self.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

/// Ordinary buttons in sheets and Settings: clear glass (macOS 26+), bordered before that.
struct ClearGlassButtonStyle: PrimitiveButtonStyle {
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26.0, *) {
            Button(configuration).buttonStyle(.glass).tint(.clear)
        } else {
            Button(configuration).buttonStyle(.bordered)
        }
    }
}

extension View {
    /// Sheet chrome: the backdrop behind it and clear-glass buttons (main actions opt in to
    /// the accent with glassButton(prominent: true)).
    func glassSheet() -> some View {
        self.buttonStyle(ClearGlassButtonStyle())
            .background { Backdrop().ignoresSafeArea() }
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
    var size: CGFloat = 78
    @State private var ripple = 0

    var body: some View {
        ZStack {
            Circle()
                .fill(AngularGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.35), t.glowB, Color.accentColor], center: .center))
                .blur(radius: size * 0.18)
                .opacity(live ? 0.6 : 0.15)
                .scaleEffect(1.05)
            if ripple > 0 { RippleRing(color: t.online).id(ripple) }
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().fill(LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center)))
                .overlay(Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.65), .white.opacity(0.08)],
                                                              startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.2))
            VStack(spacing: -3) {
                Text(count.map(String.init) ?? "–")
                    .font(.system(size: size * 0.385, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if size >= 60 {
                    Text("online").font(.system(size: 11, weight: .medium, design: .rounded)).opacity(0.75)
                }
            }
            .foregroundStyle(.primary)
        }
        .frame(width: size, height: size)
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
    var size: CGFloat = 34

    var body: some View {
        let h = Double(stableHash(name) % 1000) / 1000
        let top = Color(hue: h, saturation: 0.30, brightness: t.dark ? 0.66 : 0.74)
        let bottom = Color(hue: h, saturation: 0.40, brightness: t.dark ? 0.46 : 0.56)
        ZStack {
            Circle().fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
            Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1)
            Text(initials(name))
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if let online {
                Circle()
                    .fill(online ? t.online : Color.gray.opacity(0.7))
                    .frame(width: size * 0.32, height: size * 0.32)
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

// MARK: - Appearance picker

struct ThemePicker: View {
    @AppStorage("appearance") private var mode = AppearanceMode.auto.rawValue
    var body: some View {
        HStack(spacing: 16) {
            ForEach(AppearanceMode.allCases) { a in
                Button { mode = a.rawValue } label: { AppearanceSwatch(mode: a, selected: a.rawValue == mode) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(a.label) appearance")
                    .accessibilityAddTraits(a.rawValue == mode ? .isSelected : [])
            }
        }
    }
}

private struct AppearanceSwatch: View {
    let mode: AppearanceMode
    let selected: Bool
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                switch mode {
                case .light: mini(.light)
                case .dark: mini(.dark)
                case .auto:
                    HStack(spacing: 0) {
                        mini(.light)
                        mini(.dark)
                    }
                }
            }
            .frame(width: 120, height: 78)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: selected ? 3 : 1))
            Text(mode.label).font(.callout.weight(selected ? .semibold : .regular))
        }
    }

    private func mini(_ t: Theme) -> some View {
        ZStack(alignment: .topLeading) {
            Backdrop().environment(\.theme, t)
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(t.dark ? Color.white.opacity(0.22) : Color.white.opacity(0.9)).frame(width: 40, height: 8)
                HStack(spacing: 4) {
                    Circle().fill(t.online).frame(width: 7, height: 7)
                    Capsule().fill(t.dark ? Color.white.opacity(0.14) : Color.black.opacity(0.10)).frame(width: 30, height: 6)
                }
                Capsule().fill(Color.accentColor).frame(width: 26, height: 8)
            }
            .padding(10)
        }
    }
}
